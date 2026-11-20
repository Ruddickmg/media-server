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

  # SMB shares are bind-mounted, so smbstatus reports either the /media union
  # path or these top-level mounts. Both are mapped back to raw SSD paths before
  # comparing them with the mover's hardlink set.
  publicMount = config.media-server.nas.publicMount or "/nas";
  privateMount = config.media-server.nas.privateMount or "/nas-private";

  commonMoverService = {
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
      jq
      psmisc
      rsync
      samba
      systemd
      util-linux
      deluge
    ];
    serviceConfig = {
      Type = "oneshot";
      Nice = 19;
      IOSchedulingClass = "idle";
      UMask = "0002";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      # Do not add RestrictSUIDSGID (runuser needs setuid) or
      # ProtectProc/ProcSubset (fuser needs the process table).
      # The mover writes through the raw SSD/HDD paths, never the union, so
      # its unlinks do not generate union inotify events for
      # delete-media-watch. smbstatus needs Samba's state/lock dirs.
      ReadWritePaths = [ cfg.ssdPath ] ++ hddMounts ++ [ delugeDataDir ];
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  mover = pkgs.writeShellScriptBin "media-tier" ''
    #!/usr/bin/env bash
    set -uo pipefail

    SSD=${lib.escapeShellArg cfg.ssdPath}
    HDD_POOL=${lib.escapeShellArg cfg.hddPoolPath}
    UNIFIED=${lib.escapeShellArg cfg.unifiedPath}
    PUBLIC_MOUNT=${lib.escapeShellArg publicMount}
    PRIVATE_MOUNT=${lib.escapeShellArg privateMount}
    NEVER_GRACE_DAYS=${toString tier.neverAccessedGraceDays}
    HIGH=${toString tier.highPercent}
    CRITICAL=${toString tier.criticalPercent}
    LOW=${toString tier.lowPercent}
    WINDOWS=${lib.escapeShellArg (lib.concatStringsSep "," tier.windowTimes)}
    MIN_FREE_KIB=${toString minFreeKiB}
    # Two short checks separated by this delay close most SMB/Deluge open-file
    # races before rsync --remove-source-files deletes the source.
    SETTLE_SECONDS=5
    HDD_MOUNTS=(${lib.escapeShellArgs hddMounts})
    CONSOLE_CMD="connect 127.0.0.1:58846 localclient deluge;"
    PAUSED=0

    DRY_RUN=0
    CRITICAL_ONLY=0
    for arg in "$@"; do
      case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --critical-only) CRITICAL_ONLY=1 ;;
        *) echo "media-tier: unknown argument: $arg" >&2; exit 2 ;;
      esac
    done
    if [ "$DRY_RUN" = "1" ] && [ "$CRITICAL_ONLY" = "1" ]; then
      echo "media-tier: --dry-run and --critical-only are mutually exclusive" >&2
      exit 2
    fi

    log() { echo "media-tier: $*" >&2; }

    usage_pct() {
      # GNU df rejects -P together with --output ("mutually exclusive").
      df --output=pcent "$1" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $1}'
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

    stop_snapraid() {
      local active=0
      systemctl is-active --quiet snapraid-sync.service && active=1
      systemctl is-active --quiet snapraid-scrub.service && active=1
      [ "$active" = "1" ] || return 0
      log "stopping SnapRAID before moving data"
      systemctl stop snapraid-sync.service snapraid-scrub.service >/dev/null 2>&1 \
        || log "warning: could not stop SnapRAID"
    }

    mountpoint -q "$SSD" || { log "$SSD is not a mount point"; exit 0; }
    mountpoint -q "$HDD_POOL" || { log "$HDD_POOL is not a mount point"; exit 0; }

    # The scheduled and critical units share one non-blocking lock. A timer
    # firing while the other pass is running must not kill it mid-rsync; the
    # later run simply exits and the next tick will check again.
    LOCK_FILE="$SSD/.media-tier.lock"
    ACTIVE_FILE="$SSD/.media-tier.active"
    exec 9>"$LOCK_FILE" || { log "cannot open $LOCK_FILE"; exit 1; }
    if ! flock -n 9; then
      log "another media-tier pass is already running; exiting"
      exit 0
    fi

    # SnapRAID uses this marker as a start condition, so a sync/scrub timer
    # cannot begin while a real mover pass is relocating files.
    cleanup() {
      resume_deluge
      rm -f "$ACTIVE_FILE"
    }
    trap cleanup EXIT
    trap 'cleanup; exit 143' TERM
    trap 'cleanup; exit 130' INT
    printf '%s\n' "$$" > "$ACTIVE_FILE" || { log "cannot write $ACTIVE_FILE"; exit 1; }

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

    # smbstatus reports open files by the path in smb.conf. Map the two SMB
    # listeners (public and private) plus the two bind mounts back to the raw
    # SSD paths the mover scans. Both the reported path and its SSD equivalent
    # are kept so either side of a hardlink set can be matched.
    declare -A SMB_ACTIVE=()
    refresh_smb_active() {
      local config p raw
      SMB_ACTIVE=()
      for config in /etc/samba/smb.conf /etc/samba/smb-private.conf; do
        [ -r "$config" ] || continue
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          case "$p" in
            "$UNIFIED"/data/*)
              raw="$SSD/''${p#"$UNIFIED"/}"
              SMB_ACTIVE["$raw"]=1
              SMB_ACTIVE["$p"]=1
              ;;
            "$PUBLIC_MOUNT"/*)
              raw="$SSD/data/nas/public/''${p#"$PUBLIC_MOUNT"/}"
              SMB_ACTIVE["$raw"]=1
              SMB_ACTIVE["$p"]=1
              ;;
            "$PRIVATE_MOUNT"/*)
              raw="$SSD/data/nas/private/''${p#"$PRIVATE_MOUNT"/}"
              SMB_ACTIVE["$raw"]=1
              SMB_ACTIVE["$p"]=1
              ;;
          esac
        done < <(smbstatus -j -L -s "$config" 2>/dev/null \
                  | jq -r '.open_files // {} | keys[]' 2>/dev/null)
      done
    }

    # True when a raw SSD path (or its union view) is held open by Deluge,
    # Samba, or another process. fuser sees both namespaces because the mover
    # is not restricted with ProcSubset/ProtectProc. SMB checks come first so
    # an open Samba handle is caught even when smbd itself shows up in fuser.
    path_active() {
      local p=$1
      local union_p="$UNIFIED/''${p#"$SSD"/}"
      [ -n "''${SMB_ACTIVE[$p]:-}" ] && return 0
      [ -n "''${SMB_ACTIVE[$union_p]:-}" ] && return 0
      fuser -s "$p" 2>/dev/null && return 0
      fuser -s "$union_p" 2>/dev/null && return 0
      return 1
    }

    # Move one inode group. Return 0 to keep scanning, 1 when the pass reached
    # lowPercent, and 2 when no safe target remains. Both queues share this so
    # the fallback cannot bypass open-file, hardlink, or placement checks.
    move_candidate() {
      local key=$1 path=$2 class=$3 phase=$4 seen_name=$5
      local -n seen=$seen_name
      local -a links rel stat_before=()
      local i l skip size_kib target used stat_after

      [ -n "''${seen[$key]:-}" ] && return 0
      seen[$key]=1

      # Every hardlink to this inode, including library, torrent, and
      # cross-seed copies, moves in one rsync so -H preserves the link set.
      mapfile -d "" -t links < <(find "$SSD/data" -xdev -samefile "$path" -print0 2>/dev/null | sort -z)
      [ "''${#links[@]}" -gt 0 ] || return 0

      # Samba and other processes may hold either the raw branch path or the
      # union path; path_active checks both and the pass skips open files.
      skip=0
      for l in "''${links[@]}"; do
        if path_active "$l"; then
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

      # Quiesce: refresh Samba state, require a short quiet interval, then make
      # sure every link is still closed and unchanged immediately before rsync.
      refresh_smb_active
      for l in "''${links[@]}"; do
        stat_before+=("$(stat -c '%s %Y' "$l" 2>/dev/null)")
      done
      sleep "$SETTLE_SECONDS"
      refresh_smb_active
      for i in "''${!links[@]}"; do
        l="''${links[$i]}"
        if path_active "$l"; then
          log "skip recently active: ''${l#"$SSD"/}"
          return 0
        fi
        stat_after=$(stat -c '%s %Y' "$l" 2>/dev/null)
        if [ "$stat_after" != "''${stat_before[$i]}" ]; then
          log "skip changed during quiesce: ''${l#"$SSD"/}"
          return 0
        fi
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
    if [ "$CRITICAL_ONLY" = "1" ] && [ "$used" -lt "$CRITICAL" ]; then
      log "SSD at ''${used}% (critical threshold ''${CRITICAL}%); deferring to scheduled window $WINDOWS"
      exit 0
    fi

    # Dry runs do not free space, so project usage instead of re-reading df.
    projected_used_kib=$ssd_used_kib
    projected_pct=$((projected_used_kib * 100 / ssd_size_kib))

    # Dry runs are pure inspection: never touch Deluge or SnapRAID. A real pass
    # may hit media at any point in either queue, so pause once for the whole
    # pass and make sure parity work is not scanning half-moved inode groups.
    [ "$DRY_RUN" = "1" ] || stop_snapraid
    [ "$DRY_RUN" = "1" ] || pause_deluge
    refresh_smb_active
    if [ "$CRITICAL_ONLY" = "1" ]; then
      log "SSD at ''${used}% (critical ''${CRITICAL}%); moving coldest NAS and media data now"
    else
      log "SSD at ''${used}% (window $WINDOWS); moving coldest NAS and media data"
    fi

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
    systemd.services = {
      media-tier = commonMoverService // {
        description = "SSD-to-HDD tier mover (scheduled window)";
        serviceConfig = commonMoverService.serviceConfig // {
          ExecStart = "${mover}/bin/media-tier";
        };
      };
      media-tier-critical = commonMoverService // {
        description = "SSD-to-HDD tier mover (critical fill guard)";
        serviceConfig = commonMoverService.serviceConfig // {
          ExecStart = "${mover}/bin/media-tier --critical-only";
        };
      };
    };

    systemd.timers = {
      media-tier = {
        description = "SSD-to-HDD tier mover (scheduled window)";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = map (t: "*-*-* ${t}:00") tier.windowTimes;
          # A missed nightly window is skipped, never replayed during the day.
          Persistent = false;
        };
      };
      media-tier-critical = {
        description = "SSD-to-HDD tier mover (critical fill guard)";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # Offset from the hour so :00 windows and SnapRAID never collide.
          OnCalendar = "*:1/${toString tier.checkIntervalMinutes}";
          Persistent = false;
        };
      };
    };

    # Expose the mover so the README's dry-run step works without digging the
    # store path out of systemd.
    environment.systemPackages = [ mover ];
  };
}
