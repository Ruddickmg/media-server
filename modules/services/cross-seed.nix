{
  lib,
  pkgs,
  pkgs-unstable,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.cross-seed;
  storage = config.media-server.storage;
  apiKeys = config.media-server.apiKeys;

  # Local package bump to 6.13.9; built with the unstable toolchain.
  crossSeedPkg = pkgs-unstable.callPackage ../../pkgs/cross-seed { };

  # Prowlarr assigns indexers sequential numeric IDs: /1/api, /2/api, etc.
  # List up to 10 — unused IDs 404 gracefully.
  torznabUrls = builtins.genList (
    i: "http://127.0.0.1:9696/prowlarr/${toString (i + 1)}/api?apikey=${apiKeys.prowlarr}"
  ) 10;

  port = 2468;
  torrentsDir = "${storage.unifiedPath}/data/torrents";
  dataDir = "${torrentsDir}/complete";
  linkDir = "${torrentsDir}/xseeds";

  # Everything goes through the /media mergerfs union, never the raw branch
  # mounts. mergerfs' link/rename strategy (our create policy is
  # category.create=ff, i.e. not path-preserving) clones the target path onto
  # the source file's branch before linking, so hardlinks always land on the
  # same filesystem as the data — no per-branch coordination needed. Per-branch
  # instances were also unworkable for another reason: Deluge reports union
  # save paths, and cross-seed requires linkDirs on the same filesystem view as
  # the client's save paths (it test-links between them); branch paths are a
  # different filesystem view (EXDEV) and every instance would see the same
  # union save paths anyway, so client searchees cannot be partitioned.
  settings = {
    dataDirs = [ dataDir ];
    linkDirs = [ linkDir ];
    outputDir = null;
    host = "127.0.0.1";
    inherit port;
    action = "inject";
    useClientTorrents = true;
    torznab = torznabUrls;
    sonarr = [ "http://127.0.0.1:8989/sonarr?apikey=${apiKeys.sonarr}" ];
    radarr = [ "http://127.0.0.1:7878/radarr?apikey=${apiKeys.radarr}" ];
    linkType = "hardlink";
    duplicateCategories = true;
    matchMode = "flexible";
    # RSS polling is cross-seed's new-release discovery path (autobrr no
    # longer feeds announces). Minimum cadence is 10 minutes.
    rssCadence = "10 minutes";
    # cross-seed validates: searchCadence >= 1 day, excludeRecentSearch >=
    # 3x searchCadence, excludeOlder between 2x and 5x excludeRecentSearch.
    # Docs: don't raise searchCadence above 1 day (bunches up searches,
    # hurts searchLimit) — control frequency via excludeOlder/excludeRecentSearch.
    searchCadence = "1 day";
    excludeOlder = "2 weeks";
    excludeRecentSearch = "3 days";
    skipRecheck = false;
    autoResumeMaxDownload = 0;
    includeSingleEpisodes = false;
    ignoreNonRelevantFilesToResume = true;
    torrentClients = [
      "deluge:http://localclient:deluge@127.0.0.1:8112/json"
    ];
  };

  # Declared API key embedded directly into config.js. Not via LoadCredential:
  # that bakes CREDENTIALS_DIRECTORY (systemd-only) into config.js and breaks
  # shell use. The key is derived deterministically (common.nix) and already
  # in the store via the webhook script, so no security regression.
  configJs = pkgs.writeText "cross-seed-config.js" ''
    module.exports = ${builtins.toJSON (settings // { apiKey = apiKeys.cross-seed; })};
  '';

  # Dispatcher: `cross-seed search` (and `rss`) triggers the job via the daemon
  # HTTP API. v6 forbids running `cross-seed search` as a separate CLI process
  # while the daemon runs ("creates errors with the sqlite database"), so we
  # use /api/job (same as the daily timer). For search we mirror the
  # full-library sweep flags (ignore exclude windows). Other subcommands run
  # against the daemon's state dir as the cross-seed user.
  crossSeedDrop = pkgs.writeShellScriptBin "cross-seed" ''
    set -euo pipefail
    target_uid=$(${pkgs.coreutils}/bin/id -u cross-seed)

    cmd="''${1:-}"
    if [ "$cmd" = "search" ] || [ "$cmd" = "rss" ]; then
      shift || true
      data="{}"
      if [ "$cmd" = "search" ]; then
        data='{"name":"search","ignoreExcludeRecentSearch":true,"ignoreExcludeOlder":true}'
      elif [ "$cmd" = "rss" ]; then
        data='{"name":"rss"}'
      fi
      echo "cross-seed: triggering $cmd on port ${toString port}" >&2
      exec ${pkgs.curl}/bin/curl -q --noproxy '*' -fsS -XPOST \
        'http://127.0.0.1:${toString port}/api/job?apikey=${apiKeys.cross-seed}' \
        -H 'Content-Type: application/json' --data "$data"
    fi

    state_home='${cfg.dataDir}'
    if [ "$(${pkgs.coreutils}/bin/id -u)" -eq "$target_uid" ]; then
      umask 002
      exec env HOME="$state_home" CONFIG_DIR="$state_home" \
        ${crossSeedPkg}/bin/cross-seed "$@"
    fi
    if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
      echo "cross-seed: refusing to run as $(${pkgs.coreutils}/bin/id -un); use the setuid wrapper" >&2
      exit 1
    fi
    umask 002
    exec ${pkgs.util-linux}/bin/setpriv \
      --reuid=cross-seed --regid=cross-seed --init-groups \
      ${pkgs.coreutils}/bin/env HOME="$state_home" CONFIG_DIR="$state_home" \
      ${crossSeedPkg}/bin/cross-seed "$@"
  '';

  # Deluge Execute plugin script: triggers a webhook when a torrent finishes.
  # Deluge (VPN netns) reaches the root namespace via a filesystem UNIX socket
  # bridged by systemd-socket-proxyd to the cross-seed daemon.
  #
  # Deluge runs this synchronously on every completion, so the timeout is
  # mandatory: a hung curl would stall the daemon's execute thread.
  onCompleteScript = pkgs.writeShellScriptBin "cross-seed-on-complete" ''
    # Arguments from Deluge Execute plugin: $1 = infoHash, $2 = name, $3 = path
    if [ -n "$1" ]; then
      ${pkgs.curl}/bin/curl -sf -m 10 -XPOST \
        --unix-socket /run/cross-seed/webhook.sock \
        -H "Content-Type: application/json" \
        --data "{\"infoHash\":\"$1\",\"includeSingleEpisodes\":true}" \
        "http://cross-seed/api/webhook?apikey=${apiKeys.cross-seed}" \
        >/dev/null 2>&1
    fi
  '';

  # Shared hardening for helper services that only need loopback HTTP to the
  # daemon (no filesystem access).
  loopbackServiceHardening = {
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

in
{
  options.media-server.cross-seed = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable cross-seed automatic cross-seeding";
    };
    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/cross-seed";
      description = "State directory for the cross-seed daemon";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        # cross-seed operates on the mergerfs union paths.
        assertion = storage.enable;
        message = "media-server.cross-seed requires media-server.storage.enable (union paths under /media).";
      }
    ];

    users.users.cross-seed = {
      isSystemUser = true;
      group = "cross-seed";
      extraGroups = [ "media" ];
    };

    users.groups.cross-seed = {
      gid = 997;
    };

    # setuid root dispatcher: `search`/`rss` trigger the daemon API; other
    # commands run against the daemon's state dir. Nix store cannot carry
    # setuid bits, so the declarative wrapper is required.
    security.wrappers.cross-seed = {
      owner = "root";
      group = "root";
      setuid = true;
      source = "${crossSeedDrop}/bin/cross-seed";
    };

    systemd.tmpfiles.settings."10-cross-seed" = {
      # State dir: setgid cross-seed:media 2770. Z recursively re-owns legacy
      # root-owned files (from pre-wrapper root CLI runs) so the daemon can
      # utime them — declarative repair, no runtime chown.
      "${cfg.dataDir}" = {
        d = {
          mode = "2770";
          user = "cross-seed";
          group = "media";
        };
        Z = {
          user = "cross-seed";
          group = "media";
        };
      };
      # Webhook bridge socket dir: 0770 root:media so the Deluge Execute
      # subprocess can traverse it. Deluged runs with primary group media;
      # giving the dir group deluge here would lock the hook out. Deluged
      # needs this in ReadWritePaths because ProtectSystem=strict remounts
      # /run read-only.
      "/run/cross-seed" = {
        d = {
          mode = "0770";
          user = "root";
          group = "media";
        };
      };
    };

    systemd.services = {
      cross-seed = {
        description = "cross-seed daemon";
        wants = [
          "deluged.service"
          "prowlarr.service"
        ];
        after = [
          "network.target"
          "deluged.service"
          "prowlarr.service"
        ];
        wantedBy = [ "multi-user.target" ];
        # The union must be mounted before searchees are indexed or linked.
        unitConfig.RequiresMountsFor = [
          dataDir
          linkDir
        ];
        path = [
          crossSeedPkg
          pkgs.coreutils
        ];
        preStart = ''
          ${pkgs.coreutils}/bin/install -D -m 0640 -g media ${configJs} ${cfg.dataDir}/config.js
        '';
        serviceConfig = {
          Type = "simple";
          User = "cross-seed";
          Group = "cross-seed";
          SupplementaryGroups = [ "media" ];
          ExecStart = "${crossSeedPkg}/bin/cross-seed daemon";
          Restart = "on-failure";
          RestartSec = 5;
          Environment = [
            "HOME=${cfg.dataDir}"
            "CONFIG_DIR=${cfg.dataDir}"
          ];
          UMask = "0002";

          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateDevices = true;
          # fs.protected_hardlinks (=1 via systemd defaults) lets a process
          # hardlink a file only if it owns it, has read+write on it, or
          # holds CAP_FOWNER. cross-seed hardlinks Deluge-owned files, and
          # not every source file is guaranteed group-writable, so grant
          # CAP_FOWNER to make linking independent of source file modes.
          CapabilityBoundingSet = [ "CAP_FOWNER" ];
          AmbientCapabilities = [ "CAP_FOWNER" ];
          # One entry spanning the whole media tree, not one per directory:
          # under ProtectSystem=strict each ReadWritePaths entry becomes a
          # separate bind mount in the unit's namespace, and link(2) fails
          # with EXDEV across different bind mounts even when they are the
          # same filesystem (the kernel compares vfsmounts, not st_dev).
          # dataDir and linkDir hardlink into each other, so they must sit
          # under a single bind.
          ReadWritePaths = [
            cfg.dataDir
            "${storage.unifiedPath}/data"
          ];
        };
      };

      # Webhook bridge: Deluge (VPN netns) -> UNIX socket -> cross-seed daemon.
      cross-seed-webhook = {
        description = "Proxy Deluge webhook from root namespace to cross-seed";
        requires = [
          "cross-seed.service"
          "cross-seed-webhook.socket"
        ];
        after = [
          "cross-seed.service"
          "cross-seed-webhook.socket"
        ];
        serviceConfig = {
          User = "cross-seed";
          Group = "cross-seed";
          LimitNOFILE = 65536;
          ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --connections-max=4096 --exit-idle-time=5min 127.0.0.1:${toString port}";
        }
        // loopbackServiceHardening;
      };

      # Daily full-library search sweep via /api/job (no second process touches
      # the daemon's SQLite DB). ignoreExclude* flags make this a complete
      # sweep.
      cross-seed-search = {
        description = "Trigger daily full-library cross-seed search";
        wants = [ "rdfind-sweep.service" ];
        after = [
          "network.target"
          "cross-seed.service"
        ];
        requires = [ "cross-seed.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "cross-seed";
          Group = "cross-seed";
          ExecStart = pkgs.writeShellScript "cross-seed-search-all" ''
            ${pkgs.curl}/bin/curl -fsS -XPOST \
              'http://127.0.0.1:${toString port}/api/job?apikey=${apiKeys.cross-seed}' \
              -H 'Content-Type: application/json' \
              --data '{"name":"search","ignoreExcludeRecentSearch":true,"ignoreExcludeOlder":true}'
          '';
        }
        // loopbackServiceHardening;
      };

      # Nightly dedup safety net across the full media/torrent trees (union
      # paths are fine: rdfind hardlinks identical files wherever it finds
      # them). Runs after the daily cross-seed search attempt.
      rdfind-sweep = {
        description = "Deduplicate hard links across media and torrent trees";
        unitConfig.RequiresMountsFor = [
          "/media/data/torrents/complete"
          "/media/data/torrents/xseeds"
          "/media/data/library/movies"
          "/media/data/library/tv"
        ];
        after = [ "cross-seed-search.service" ];
        serviceConfig = {
          Type = "oneshot";
          # Single entry spanning every tree rdfind hardlinks between: with
          # ProtectSystem=strict each ReadWritePaths entry is a separate bind
          # mount and link(2) fails EXDEV across binds even on the same
          # filesystem, so per-tree entries would silently break the dedup.
          ReadWritePaths = [ "/media/data" ];
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
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
          TimeoutStartSec = 0;
          Nice = 19;
          IOSchedulingClass = "idle";
          ExecStart = "${pkgs.rdfind}/bin/rdfind -makeresultsfile false -makehardlinks true /media/data/torrents/complete /media/data/torrents/xseeds /media/data/library/movies /media/data/library/tv";
        };
      };
    };

    systemd.sockets.cross-seed-webhook = {
      description = "Socket for cross-seed webhook from Deluge Execute plugin";
      listenStreams = [ "/run/cross-seed/webhook.sock" ];
      socketConfig = {
        # Deluged's primary group is media; group deluge here would leave the
        # Execute hook unable to open its own webhook socket.
        SocketGroup = "media";
        SocketMode = "0660";
      };
      wantedBy = [ "sockets.target" ];
    };

    systemd.timers.cross-seed-search = {
      description = "Daily full-library cross-seed search";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:30:00";
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };

    # Make the on-completion script and rdfind available system-wide.
    environment.systemPackages = [
      onCompleteScript
      pkgs.rdfind
    ];
  };
}
