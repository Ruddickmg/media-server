{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.delete-media-watch;

  # Hard-link topology roots — single source of truth in common.nix
  # (media-server.deleteMedia.rootPaths). The watcher's inode snapshot and its
  # empty-dir guard list both derive from here, so delete-media and
  # delete-media-watch can never drift.
  roots = config.media-server.deleteMedia.rootPaths;

  # Deletion sources: a file unlinked in /media/{movies,tv,music} triggers this
  # process. A deletion in completed/ or xseeds/ is a cleanup TARGET, never a
  # trigger — those roots are only scanned for sibling hard links to remove.
  watchRoots = builtins.filter (
    p:
    builtins.elem p [
      "/media/movies"
      "/media/tv"
      "/media/music"
    ]
  ) roots;

  guardRoots = [
    "/media"
    "/media/downloads"
    "/media/downloads/incomplete"
  ]
  ++ roots;

  # Long-running daemon (never a one-shot): watches the Plex library dirs for
  # unlinks and removes every hard link to the deleted file (download-folder
  # copies, cross-seed/xseed links, duplicate-library copies), then prunes empty
  # shells and removes the matching torrents from Deluge. Inherent event watcher
  # logic, hence a script despite the modules' declarative-first rule.
  #
  # Why an inode snapshot? inotify reports only the deleted PATH, not the inode,
  # and the file is already gone — `find -samefile` (what delete-media uses)
  # needs a live file to anchor on. The snapshot (refreshed every ≤15 min and
  # after every cleanup) maps path -> dev:ino; the deleted path's inode then
  # yields its surviving siblings, one of which anchors a final -samefile pass
  # that also catches links created since the last snapshot.
  #
  # Only delete/delete_self are watched, never moved_from: a rename (Sonarr/
  # Radarr release replacement) must not read as a deletion.
  watcher = pkgs.writeShellScriptBin "delete-media-watch" ''
    #!/usr/bin/env bash
    set -uo pipefail

    INDEX=/run/delete-media-watch/index
    ROOTS=(${builtins.concatStringsSep " " roots})
    WATCH_ROOTS=(${builtins.concatStringsSep " " watchRoots})
    GUARD_ROOTS=(${builtins.concatStringsSep " " guardRoots})
    # Deluge web JSON RPC — the same endpoint/auth cross-seed already uses
    # (proxy-deluge-web socket, root namespace), so this path is battle-tested
    # in this deployment.
    DELUGE_URL="http://127.0.0.1:8112/json"
    DELUGE_AUTH="localclient:deluge"

    log() { echo "delete-media-watch: $*"; }

    # Snapshot (dev:ino, path) of every file under the roots. A root that is
    # temporarily missing (e.g. during media mount/import choreography) must not
    # poison the whole snapshot — index whatever exists, unconditionally.
    build_index() {
      find "''${ROOTS[@]}" -xdev -type f -printf '%D:%i\t%p\n' 2>/dev/null > "$INDEX.tmp"
      mv -f "$INDEX.tmp" "$INDEX"
    }

    ino_for() { awk -F'\t' -v p="$1" '$2==p {print $1; exit}' "$INDEX"; }
    paths_with_ino() { awk -F'\t' -v i="$1" '$1==i {print $2}' "$INDEX"; }

    # Remove Deluge torrents whose save_path equals one of the given dirs (the
    # folders that held the hard links we just unlinked). Best-effort: failures
    # are logged, never fatal. Data is already gone, so remove_data=false.
    deluge_remove_for_dirs() {
      local -a dirs=("$@")
      local d
      local hashes=()
      [ "''${#dirs[@]}" -eq 0 ] && return 0
      local hosts host_id torrents ids
      hosts=$(curl -sfS -m 10 -u "$DELUGE_AUTH" \
        -H 'Content-Type: application/json' \
        --data '{"method":"web.get_hosts","params":[],"id":1}' "$DELUGE_URL") \
        || { log "deluge: web.get_hosts failed"; return 1; }
      host_id=$(jq -r '.result[0][0]' <<<"$hosts")
      [ -n "$host_id" ] && [ "$host_id" != "null" ] || { log "deluge: no daemon host"; return 1; }
      curl -sfS -m 10 -u "$DELUGE_AUTH" \
        -H 'Content-Type: application/json' \
        --data "{\"method\":\"web.connect\",\"params\":[\"$host_id\"],\"id\":2}" "$DELUGE_URL" \
        >/dev/null 2>&1 || { log "deluge: web.connect failed"; return 1; }
      torrents=$(curl -sfS -m 30 -u "$DELUGE_AUTH" \
        -H 'Content-Type: application/json' \
        --data '{"method":"core.get_torrents_status","params":[{},["name","save_path"]],"id":3}' "$DELUGE_URL") \
        || { log "deluge: get_torrents_status failed"; return 1; }
      while IFS=$'\t' read -r sp hash; do
        for d in "''${dirs[@]}"; do
          [ "$sp" = "$d" ] && { hashes+=("$hash"); break; }
        done
      done < <(jq -r '.result | to_entries[] | [.value.save_path, .key] | @tsv' <<<"$torrents")
      [ "''${#hashes[@]}" -eq 0 ] && return 0
      # A multi-file deletion can match the same torrent more than once.
      ids=$(printf '%s\n' "''${hashes[@]}" | sort -u | jq -R . | jq -s -c .)
      if curl -sfS -m 30 -u "$DELUGE_AUTH" \
        -H 'Content-Type: application/json' \
        --data "{\"method\":\"core.remove_torrent\",\"params\":[$ids,false],\"id\":4}" "$DELUGE_URL" >/dev/null; then
        log "deluge: removed ''${#hashes[@]} torrent(s): ''${hashes[*]}"
      else
        log "deluge: remove_torrent failed"
      fi
    }

    # rmdir empty dirs left behind by the deletion, never the well-known /media
    # roots — the same guard logic as delete-media (common.nix).
    prune_empty_dirs() {
      find /media -depth -type d -empty 2>/dev/null | while IFS= read -r d; do
        for g in "''${GUARD_ROOTS[@]}"; do
          [ "$d" = "$g" ] && continue 2
        done
        rmdir "$d" 2>/dev/null || true
      done
    }

    # Clean up every hard link to a deleted path: look up its inode in the
    # snapshot, anchor -samefile on a surviving sibling, unlink all current
    # links, then Deluge torrents + empty shells + a fresh snapshot.
    cleanup_path() {
      local P="$1" ino survivor s l
      ino=$(ino_for "$P")
      [ -n "$ino" ] || return 1
      local -a sibs=()
      local -a removed_dirs=()
      while IFS= read -r s; do sibs+=("$s"); done < <(paths_with_ino "$ino")
      for s in "''${sibs[@]}"; do
        [ "$s" = "$P" ] && continue
        [ -e "$s" ] && { survivor="$s"; break; }
      done
      [ -n "$survivor" ] || {
        # No surviving link: the deleted file was either never hardlinked
        # (posters, artwork) or its inode only ever had this one path.
        [ "''${#sibs[@]}" -gt 1 ] && log "no surviving hard link for '$P' (inode $ino); nothing to clean"
        return 0
      }
      while IFS= read -r l; do
        [ "$l" = "$P" ] && continue
        rm -f -- "$l" && removed_dirs+=("$(dirname -- "$l")")
      done < <(find /media -xdev -samefile "$survivor" -print 2>/dev/null)
      if [ "''${#removed_dirs[@]}" -gt 0 ]; then
        log "unlinked ''${#removed_dirs[@]} hard link(s) for '$P'"
        deluge_remove_for_dirs "''${removed_dirs[@]}" || true
        prune_empty_dirs
        build_index
      fi
      return 0
    }

    # Handle an IN_DELETE event for path $1 (file or directory). A deleted
    # directory (e.g. `rm -rf /media/movies/Foo`, or Plex clearing a folder)
    # removes every file under it — covered by the subtree branch, which also
    # backstops missed per-file events.
    handle_delete() {
      local P="$1" ino count q
      ino=$(ino_for "$P")
      if [ -n "$ino" ]; then
        cleanup_path "$P"
        return 0
      fi
      count=0
      while IFS= read -r q; do
        cleanup_path "$q" && count=$((count + 1))
      done < <(awk -F'\t' -v p="$P/" 'index($2,p)==1 {print $2}' "$INDEX")
      [ "$count" -gt 0 ] && return 0
      # Exact path missing from the snapshot — refresh once per minute and
      # retry. A full re-scan on every empty-dir event would be pointless.
      now=$(date +%s)
      if [ $((now - last_retry)) -ge 60 ]; then
        build_index
        last_retry=$now
        ino=$(ino_for "$P")
        [ -n "$ino" ] && cleanup_path "$P"
      fi
      return 0
    }

    build_index
    last_retry=0
    while :; do
      # inotifywait cannot add watches for directories created after it starts
      # (-r only follows dirs present at launch); restarting every 15 min
      # re-scans the tree AND refreshes the snapshot, so freshly imported
      # movie/show/music folders are covered within that window.
      timeout 900 inotifywait -m -r -q -e delete -e delete_self --format '%w%f' "''${WATCH_ROOTS[@]}" 2>/dev/null \
        | while IFS= read -r P; do
            [ -n "$P" ] || continue
            # Never treat the watched roots themselves as deletions (delete_self).
            case "$P" in
              /media/movies|/media/tv|/media/music) : ;;
              *) handle_delete "$P" ;;
            esac
          done
      build_index
    done
  '';
in
{
  options.media-server.delete-media-watch = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Delete all hard links when media is removed from /media/{movies,tv,music}";
    };
  };

  config = mkIf cfg.enable {
    # Recursive watches count DIRECTORY watch descriptors (not files); bump the
    # limit so the library trees always fit, declaratively.
    boot.kernel.sysctl."fs.inotify.max_user_watches" = "65536";

    systemd.services.delete-media-watch = {
      description = "Delete hard links when media is removed from the Plex library dirs";
      # Deluge torrent removal is best-effort via the proxy-deluge-web socket;
      # wants only (soft deps) so the watcher starts independently at boot.
      wants = [
        "deluged.service"
        "proxy-deluge-web.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        RuntimeDirectory = "delete-media-watch";
        ExecStart = "${watcher}/bin/delete-media-watch";
        Restart = "always";
        RestartSec = "10s";
        # ProtectSystem=strict makes everything read-only except these
        # (the library + download trees it must unlink in).
        ReadWritePaths = [ "/media" ];
        # NOTE: PrivateNetwork is deliberately NOT set — the Deluge JSON RPC
        # listener (proxy-deluge-web.socket) binds 127.0.0.1:8112 in the host
        # namespace, which an isolated loopback could not reach.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        CapabilityBoundingSet = [ "" ];
        ProtectHome = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectClock = true;
        PrivateMounts = true;
        PrivateDevices = true;
      };
      path = with pkgs; [
        inotify-tools
        findutils
        coreutils
        gawk
        curl
        jq
      ];
    };
  };
}
