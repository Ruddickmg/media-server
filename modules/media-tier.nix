{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.media-server.storage;
  tier = cfg.tiering;

  hddMounts = map (d: d.mountPoint) (lib.attrValues cfg.hddDisks);
  minFreeKiB = tier.minFreeGiB * 1024 * 1024;

  # The console connects to 127.0.0.1:58846 in the host namespace. When Deluge
  # is VPN-confined, proxy-deluge forwards that port (the same path the *arr
  # apps and the disk guard use).
  delugeConsole = "${config.services.deluge.package}/bin/deluge-console";
  delugeUser = config.services.deluge.user;
  delugeDataDir = config.services.deluge.dataDir;

  mover = pkgs.writeShellScriptBin "media-tier" ''
    #!/usr/bin/env bash
    set -uo pipefail

    SSD=${lib.escapeShellArg cfg.ssdPath}
    HDD_POOL=${lib.escapeShellArg cfg.hddPoolPath}
    UNIFIED=${lib.escapeShellArg cfg.unifiedPath}
    NEVER_GRACE_DAYS=${toString tier.neverAccessedGraceDays}
    HIGH=${toString tier.highPercent}
    LOW=${toString tier.lowPercent}
    MIN_FREE_KIB=${toString minFreeKiB}
    HDD_MOUNTS=(${lib.escapeShellArgs hddMounts})
    CONSOLE_CMD="connect 127.0.0.1:58846 localclient deluge;"
    PAUSED=0

    DRY_RUN=0
    [ "''${1:-}" = "--dry-run" ] && DRY_RUN=1

    log() { echo "media-tier: $*" >&2; }

    usage_pct() {
      df -P --output=pcent "$1" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $1}'
    }

    pause_deluge() {
      if [ ! -x ${lib.escapeShellArg delugeConsole} ]; then
        log "deluge-console not found; skipping pause"
        return 0
      fi
      if runuser -u ${lib.escapeShellArg delugeUser} -- env HOME=${lib.escapeShellArg delugeDataDir} \
          ${lib.escapeShellArg delugeConsole} "$CONSOLE_CMD pause *" >/dev/null 2>&1; then
        PAUSED=1
        log "paused Deluge torrents"
      else
        log "warning: could not pause Deluge; continuing (open files are skipped)"
      fi
    }

    resume_deluge() {
      if [ "$PAUSED" = "1" ]; then
        runuser -u ${lib.escapeShellArg delugeUser} -- env HOME=${lib.escapeShellArg delugeDataDir} \
          ${lib.escapeShellArg delugeConsole} "$CONSOLE_CMD resume *" >/dev/null 2>&1 \
          || log "warning: could not resume Deluge"
        PAUSED=0
      fi
    }
    trap resume_deluge EXIT
    trap 'resume_deluge; exit 143' TERM
    trap 'resume_deluge; exit 130' INT

    mountpoint -q "$SSD" || { log "$SSD is not a mount point"; exit 0; }
    mountpoint -q "$HDD_POOL" || { log "$HDD_POOL is not a mount point"; exit 0; }

    if ! read -r ssd_size_kib ssd_used_kib < <(df -Pk "$SSD" 2>/dev/null | awk 'NR==2 {print $2, $3}'); then
      log "cannot read capacity of $SSD"
      exit 1
    fi
    [ "$ssd_size_kib" -gt 0 ] 2>/dev/null || { log "invalid capacity for $SSD"; exit 1; }
    [ "$ssd_used_kib" -ge 0 ] 2>/dev/null || { log "invalid usage for $SSD"; exit 1; }

    # Pick the data disk with the most free space that can fit the group while
    # still keeping minFreeGiB free. Writing to the disk directly (not the
    # pool) guarantees every hardlink in a media group stays on one filesystem.
    pick_target() {
      local need_kib=$1 best="" best_free=0 free d
      for d in "''${HDD_MOUNTS[@]}"; do
        mountpoint -q "$d" || continue
        free=$(df -Pk "$d" 2>/dev/null | awk 'NR==2 {print $4}')
        [ -n "$free" ] || continue
        [ "$free" -ge $((need_kib + MIN_FREE_KIB)) ] || continue
        if [ "$free" -gt "$best_free" ]; then
          best=$d
          best_free=$free
        fi
      done
      printf '%s' "$best"
    }

    prune_media_empty() {
      # Keep the well-known top-level dirs: library/{movies,tv,music} and
      # torrents/{complete,xseeds}. Only remove empty release/torrent shells.
      # NAS directories are user-facing and are deliberately left alone.
      find "$SSD/data/library" -mindepth 2 -type d -empty -delete 2>/dev/null || true
      find "$SSD/data/torrents/complete" "$SSD/data/torrents/xseeds" \
        -mindepth 1 -type d -empty -delete 2>/dev/null || true
    }

    current_pct() {
      if [ "$DRY_RUN" = "1" ]; then
        printf '%s' "$projected_pct"
      else
        usage_pct "$SSD"
      fi
    }

    # Move one inode group. Return 0 to keep scanning, 1 when the pass reached
    # lowPercent, and 2 when no safe target remains. Both queues share this so
    # the fallback cannot bypass open-file, hardlink, or placement checks.
    move_candidate() {
      local key=$1 path=$2 class=$3 phase=$4 seen_name=$5
      local -n seen=$seen_name
      local -a links rel
      local l union_l skip size_kib target used

      [ -n "''${seen[$key]:-}" ] && return 0
      seen[$key]=1

      # Every hardlink to this inode, including library, torrent, and
      # cross-seed copies, moves in one rsync so -H preserves the link set.
      mapfile -d "" -t links < <(find "$SSD/data" -xdev -samefile "$path" -print0 2>/dev/null | sort -z)
      [ "''${#links[@]}" -gt 0 ] || return 0

      # Samba and other processes may hold either the raw branch path or the
      # union path; fuser treats them as different inode namespaces.
      skip=0
      for l in "''${links[@]}"; do
        union_l="$UNIFIED/''${l#"$SSD"/}"
        if fuser -s "$l" 2>/dev/null || fuser -s "$union_l" 2>/dev/null; then
          log "skip open: ''${l#"$SSD"/}"
          skip=1
          break
        fi
      done
      [ "$skip" = 1 ] && return 0

      size_kib=$(du -ck "''${links[@]}" 2>/dev/null | awk 'END {print $1}')
      [ -n "$size_kib" ] || return 0

      target=$(pick_target "$size_kib")
      if [ -z "$target" ]; then
        log "no data disk with room for ''${size_kib} KiB; stopping"
        return 2
      fi

      rel=()
      for l in "''${links[@]}"; do
        rel+=("''${l#"$SSD"/}")
      done

      log "moving ''${phase}/''${class}: ''${#links[@]} link(s), ''${size_kib} KiB -> $target: ''${rel[0]}"
      if [ "$DRY_RUN" = "1" ]; then
        printf '  %s\n' "''${rel[@]}" >&2
        projected_used_kib=$((projected_used_kib - size_kib))
        [ "$projected_used_kib" -ge 0 ] || projected_used_kib=0
        projected_pct=$((projected_used_kib * 100 / ssd_size_kib))
        if [ "$projected_pct" -lt "$LOW" ]; then
          log "dry run would leave SSD at ''${projected_pct}%; below stop threshold ''${LOW}%"
          return 1
        fi
        return 0
      fi

      if ! (cd "$SSD" && rsync -axHAXWES --preallocate --remove-source-files --relative \
            "''${rel[@]}" "$target/"); then
        log "rsync failed; stopping"
        return 2
      fi

      prune_media_empty
      used=$(usage_pct "$SSD")
      if [ -n "$used" ] && [ "$used" -lt "$LOW" ]; then
        log "SSD at ''${used}%; below stop threshold ''${LOW}%"
        return 1
      fi
      return 0
    }

    # One coldest-first queue covers NAS and media. Files with atime > mtime
    # were read after their last write and have no age gate. Files with
    # atime <= mtime look never accessed since their last write; relatime and
    # whole-second timestamps make that an approximation, so they get a grace
    # period based on mtime before they enter the normal queue.
    never_grace_cutoff=$(date -d "-$NEVER_GRACE_DAYS days" +%s 2>/dev/null) || {
      log "cannot compute never-accessed grace cutoff"
      exit 1
    }

    used=$(usage_pct "$SSD")
    [ -n "$used" ] || { log "cannot read usage of $SSD"; exit 1; }
    if [ "$used" -lt "$HIGH" ]; then
      log "SSD at ''${used}% (start threshold ''${HIGH}%); nothing to do"
      exit 0
    fi

    # Dry runs do not free space, so project usage instead of re-reading df.
    projected_used_kib=$ssd_used_kib
    projected_pct=$((projected_used_kib * 100 / ssd_size_kib))

    # Dry runs are pure inspection: never touch Deluge. A real pass may hit
    # media at any point in either queue, so pause once for the whole pass.
    [ "$DRY_RUN" = "1" ] || pause_deluge
    log "SSD at ''${used}%; moving coldest NAS and media data"

    declare -A SEEN_PRIMARY=() SEEN_FALLBACK=() FALLBACK_COLLECTED=()
    fallback_entries=()
    STOPPED=0

    while IFS= read -r -d "" entry; do
      atime=''${entry%%$'\t'*}
      rest=''${entry#*$'\t'}
      mtime=''${rest%%$'\t'*}
      rest=''${rest#*$'\t'}
      key=''${rest%%$'\t'*}
      path=''${rest#*$'\t'}
      atime=''${atime%.*}
      mtime=''${mtime%.*}

      [ -f "$path" ] || continue

      if [ "$atime" -le "$mtime" ]; then
        class=never
        if [ "$mtime" -gt "$never_grace_cutoff" ]; then
          # Keep grace-protected files aside. If the normal queue cannot get
          # the SSD below LOW, they move by age (oldest mtime first) instead of
          # leaving the drive under pressure.
          if [ -z "''${FALLBACK_COLLECTED[$key]:-}" ]; then
            FALLBACK_COLLECTED[$key]=1
            fallback_entries+=("$entry")
          fi
          continue
        fi
      else
        class=accessed
      fi

      move_candidate "$key" "$path" "$class" primary SEEN_PRIMARY
      case $? in
        0) ;;
        *) STOPPED=1; break ;;
      esac
    done < <(find "$SSD/data/nas" "$SSD/data/library" "$SSD/data/torrents/complete" \
               "$SSD/data/torrents/xseeds" -xdev -type f \
               -printf '%A@\t%T@\t%D:%i\t%p\0' 2>/dev/null \
             | sort -z -t $'\t' -k1,1n -k3,3)

    used_now=$(current_pct)
    if [ "$STOPPED" = "0" ] && [ "''${#fallback_entries[@]}" -gt 0 ] \
       && [ -n "$used_now" ] && [ "$used_now" -ge "$LOW" ]; then
      log "normal queue exhausted at ''${used_now}%; falling back to file age"
      while IFS= read -r -d "" entry; do
        atime=''${entry%%$'\t'*}
        rest=''${entry#*$'\t'}
        mtime=''${rest%%$'\t'*}
        rest=''${rest#*$'\t'}
        key=''${rest%%$'\t'*}
        path=''${rest#*$'\t'}
        [ -f "$path" ] || continue
        move_candidate "$key" "$path" never fallback SEEN_FALLBACK
        case $? in
          0) ;;
          *) STOPPED=1; break ;;
        esac
      done < <(printf '%s\0' "''${fallback_entries[@]}" \
               | sort -z -t $'\t' -k2,2n)
    elif [ "''${#fallback_entries[@]}" -gt 0 ] && [ "$STOPPED" = "0" ]; then
      log "left ''${#fallback_entries[@]} grace-protected file(s) untouched"
    fi

    if [ "$DRY_RUN" = "1" ]; then
      log "dry run complete; would leave SSD at ''${projected_pct}%"
    else
      log "finished; SSD at $(usage_pct "$SSD")%"
    fi
  '';
in
{
  config = lib.mkIf (cfg.enable && tier.enable) {
    systemd.services.media-tier = {
      description = "Move coldest SSD NAS and media data to the HDD backing pool";
      after = [
        "deluged.service"
        "proxy-deluge.service"
        "local-fs.target"
      ];
      wants = [ "deluged.service" ];
      unitConfig.ConditionPathIsMountPoint = [
        cfg.ssdPath
        cfg.hddPoolPath
      ];
      path = with pkgs; [
        coreutils
        findutils
        gawk
        psmisc
        rsync
        util-linux
        deluge
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${mover}/bin/media-tier";
        Nice = 19;
        IOSchedulingClass = "idle";
        UMask = "0002";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        # The mover writes through the raw SSD/HDD paths, never the union, so
        # its unlinks do not generate union inotify events for
        # delete-media-watch.
        ReadWritePaths = [ cfg.ssdPath ] ++ hddMounts ++ [ delugeDataDir ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    systemd.timers.media-tier = {
      description = "SSD-to-HDD tier mover and fill guard";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = [
          "*-*-* ${tier.time}:00"
          "*:0/${toString tier.checkIntervalMinutes}"
        ];
        Persistent = true;
      };
    };

    # Expose the mover so the README's dry-run step works without digging the
    # store path out of systemd.
    environment.systemPackages = [ mover ];
  };
}
