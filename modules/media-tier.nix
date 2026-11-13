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

    used=$(usage_pct "$SSD")
    [ -n "$used" ] || { log "cannot read usage of $SSD"; exit 1; }
    if [ "$used" -lt "$HIGH" ]; then
      log "SSD at ''${used}% (start threshold ''${HIGH}%); nothing to do"
      exit 0
    fi

    log "SSD at ''${used}%; moving oldest files until below ''${LOW}%"
    # Dry runs are pure inspection: never touch Deluge.
    [ "$DRY_RUN" = "1" ] || pause_deluge

    # Pick the data disk with the most free space that can fit the group while
    # still keeping minFreeGiB free. Writing to the disk directly (not the
    # pool) guarantees every hardlink in the group stays on one filesystem.
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

    prune_empty() {
      # Keep the well-known top-level dirs: library/{movies,tv,music} and
      # torrents/{complete,xseeds}. Only remove empty release/torrent shells.
      find "$SSD/data/library" -mindepth 2 -type d -empty -delete 2>/dev/null || true
      find "$SSD/data/torrents/complete" "$SSD/data/torrents/xseeds" \
        -mindepth 1 -type d -empty -delete 2>/dev/null || true
    }

    declare -A SEEN=()

    while IFS= read -r -d "" entry; do
      # entry = "<atime>\t<path>"
      path=''${entry#*$'\t'}
      [ -f "$path" ] || continue
      key=$(stat -c '%d:%i' "$path" 2>/dev/null) || continue
      [ -n "''${SEEN[$key]:-}" ] && continue
      SEEN[$key]=1

      # Every hardlink to this inode on the SSD, including the library copy and
      # the torrent copy. Move them in one rsync invocation so -H preserves the
      # link set on the destination.
      mapfile -d "" -t links < <(find "$SSD/data" -xdev -samefile "$path" -print0 2>/dev/null)
      [ "''${#links[@]}" -gt 0 ] || continue

      skip=0
      for l in "''${links[@]}"; do
        if fuser -s "$l" 2>/dev/null; then
          skip=1
          break
        fi
      done
      [ "$skip" = 1 ] && continue

      size_kib=$(du -ck "''${links[@]}" 2>/dev/null | awk 'END {print $1}')
      [ -n "$size_kib" ] || continue

      target=$(pick_target "$size_kib")
      if [ -z "$target" ]; then
        log "no data disk with room for ''${size_kib} KiB; stopping"
        break
      fi

      rel=()
      for l in "''${links[@]}"; do
        rel+=("''${l#"$SSD"/}")
      done

      log "moving ''${#links[@]} link(s), ''${size_kib} KiB -> $target"
      if [ "$DRY_RUN" = "1" ]; then
        printf '  %s\n' "''${rel[@]}" >&2
      else
        if ! (cd "$SSD" && rsync -axHAXWES --preallocate --remove-source-files --relative \
              "''${rel[@]}" "$target/"); then
          log "rsync failed; stopping"
          break
        fi
      fi

      [ "$DRY_RUN" = "1" ] || prune_empty
      used=$(usage_pct "$SSD")
      if [ -n "$used" ] && [ "$used" -lt "$LOW" ]; then
        log "SSD at ''${used}%; below stop threshold ''${LOW}%"
        break
      fi
    done < <(find "$SSD/data/library" "$SSD/data/torrents/complete" "$SSD/data/torrents/xseeds" \
               -xdev -type f -printf '%A@\t%p\0' 2>/dev/null | sort -z -n)

    log "finished; SSD at $(usage_pct "$SSD")%"
  '';
in
{
  config = lib.mkIf (cfg.enable && tier.enable) {
    systemd.services.media-tier = {
      description = "Move cold SSD media to the HDD backing pool";
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
      description = "Nightly SSD-to-HDD media tier mover";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* ${tier.time}:00";
        Persistent = true;
      };
    };

    # Expose the mover so the README's dry-run step works without digging the
    # store path out of systemd.
    environment.systemPackages = [ mover ];
  };
}
