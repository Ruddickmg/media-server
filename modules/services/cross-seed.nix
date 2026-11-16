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

  # Per-storage-branch cross-seed instances. Hardlinks cannot cross filesystems,
  # and the /media mergerfs union routes new creates to the SSD first
  # (category.create=ff), so a link created through /media for HDD-resident data
  # would land on the wrong filesystem and fail. Each instance therefore targets
  # one underlying branch's data/torrents/{complete,xseeds} so source and linkDir
  # are always on the same filesystem. The SSD instance keeps the legacy
  # /var/lib/cross-seed state dir and port 2468 for continuity (existing DB,
  # webhook/timer).
  ssdBranch = {
    name = "ssd";
    root = storage.ssdPath;
    stateDir = cfg.dataDir;
    port = 2468;
  };
  hddBranches = lib.imap0 (i: name: {
    inherit name;
    root = storage.hddDisks.${name}.mountPoint;
    stateDir = "/var/lib/cross-seed-${name}";
    port = 2469 + i;
  }) (lib.sort (a: b: a < b) (builtins.attrNames storage.hddDisks));
  branches = [ ssdBranch ] ++ hddBranches;

  mkBranch = b:
    let
      dataDir = "${b.root}/data/torrents/complete";
      linkDir = "${b.root}/data/torrents/xseeds";

      settings = {
        dataDirs = [ dataDir ];
        linkDirs = [ linkDir ];
        outputDir = null;
        port = b.port;
        host = "127.0.0.1";
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
      configJs = pkgs.writeText "cross-seed-config-${b.name}.js" ''
        module.exports = ${builtins.toJSON (settings // { apiKey = apiKeys.cross-seed; })};
      '';

      # Env-setting launcher for this instance. Sets CONFIG_DIR/HOME and umask 002
      # so files are group-writable in the 2770 cross-seed:media state dir.
      cli = pkgs.writeShellScriptBin "cross-seed" ''
        if [ "$(${pkgs.coreutils}/bin/id -u)" -ne "$(${pkgs.coreutils}/bin/id -u cross-seed)" ]; then
          echo "cross-seed: refusing to run as $(${pkgs.coreutils}/bin/id -un); use the shell wrapper (drops to user cross-seed)" >&2
          exit 1
        fi
        umask 002
        exec env HOME='${b.stateDir}' CONFIG_DIR='${b.stateDir}' \
          ${crossSeedPkg}/bin/cross-seed "$@"
      '';

      serviceName = "cross-seed-${b.name}";
    in
    b
    // {
      inherit
        dataDir
        linkDir
        settings
        configJs
        cli
        serviceName
        ;
    };

  instances = map mkBranch branches;
  primary = builtins.head instances;

  # Dispatcher: `cross-seed search` (and `rss`) triggers the job via the daemon
  # HTTP API on every branch instance so all branches are searched/cross-seeded.
  # v6 forbids running `cross-seed search` as a separate CLI process while the
  # daemon runs ("creates errors with the sqlite database"), so we use /api/job
  # (same as the daily timer). For search we mirror the full-library sweep flags
  # (ignore exclude windows). Other subcommands run against the primary instance.
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
      rc=0
      ${lib.concatMapStringsSep "\n      " (i: ''
        echo "cross-seed: triggering $cmd on ${i.name} (port ${toString i.port})" >&2
        ${pkgs.curl}/bin/curl -fsS -XPOST \
          'http://127.0.0.1:${toString i.port}/api/job?apikey=${apiKeys.cross-seed}' \
          -H 'Content-Type: application/json' --data "$data" || rc=$?
      '') instances}
      exit $rc
    fi

    primary_home='${primary.stateDir}'
    if [ "$(${pkgs.coreutils}/bin/id -u)" -eq "$target_uid" ]; then
      umask 002
      exec env HOME="$primary_home" CONFIG_DIR="$primary_home" \
        ${crossSeedPkg}/bin/cross-seed "$@"
    fi
    if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
      echo "cross-seed: refusing to run as $(${pkgs.coreutils}/bin/id -un); use the setuid wrapper" >&2
      exit 1
    fi
    umask 002
    exec ${pkgs.util-linux}/bin/setpriv \
      --reuid=cross-seed --regid=cross-seed --init-groups \
      ${pkgs.coreutils}/bin/env HOME="$primary_home" CONFIG_DIR="$primary_home" \
      ${crossSeedPkg}/bin/cross-seed "$@"
  '';

  # Deluge Execute plugin script: triggers a webhook when a torrent finishes.
  # Deluge (VPN netns) reaches the root namespace via a filesystem UNIX socket
  # bridged by systemd-socket-proxyd to the primary instance.
  onCompleteScript = pkgs.writeShellScriptBin "cross-seed-on-complete" ''
    # Arguments from Deluge Execute plugin: $1 = infoHash, $2 = name, $3 = path
    if [ -n "$1" ]; then
      ${pkgs.curl}/bin/curl -sf -XPOST \
        --unix-socket /run/cross-seed/webhook.sock \
        -H "Content-Type: application/json" \
        --data "{\"infoHash\":\"$1\",\"includeSingleEpisodes\":true}" \
        "http://cross-seed/api/webhook?apikey=${apiKeys.cross-seed}" \
        >/dev/null 2>&1
    fi
  '';

  # Shared hardening for helper services that only need loopback HTTP to the
  # daemons (no filesystem access).
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
      description = "State directory for the primary (SSD) cross-seed instance";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = storage.enable && storage.hddDisks != { };
        message = "media-server.cross-seed requires media-server.storage.enable with at least one HDD (per-branch instances).";
      }
    ];

    # One cross-seed daemon per storage branch (SSD + each HDD) so hardlinks are
    # always created on the same underlying filesystem as the source data. We do
    # not use the singular upstream services.cross-seed module; instances are
    # defined explicitly below.
    users.users.cross-seed = {
      isSystemUser = true;
      group = "cross-seed";
      extraGroups = [ "media" ];
    };

    users.groups.cross-seed = {
      gid = 997;
    };

    # setuid root dispatcher: `search`/`rss` fan out to all instances via the
    # daemon API; other commands target the primary instance. Nix store cannot
    # carry setuid bits, so the declarative wrapper is required.
    security.wrappers.cross-seed = {
      owner = "root";
      group = "root";
      setuid = true;
      source = "${crossSeedDrop}/bin/cross-seed";
    };

    systemd.tmpfiles.settings."10-cross-seed" = lib.mkMerge (
      # Per-instance state dirs: setgid cross-seed:media 2770. Z recursively
      # re-owns legacy root-owned files (from pre-wrapper root CLI runs) so the
      # daemon can utime them — declarative repair, no runtime chown.
      (map (i: {
        "${i.stateDir}" = {
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
      }) instances)
      ++ [
        {
          # Webhook bridge socket dir: 0770 root:deluge so the Deluge Execute
          # subprocess can traverse it. Deluged needs this in ReadWritePaths
          # because ProtectSystem=strict remounts /run read-only.
          "/run/cross-seed" = {
            d = {
              mode = "0770";
              user = "root";
              group = "deluge";
            };
          };
        }
      ]
    );

    systemd.services = lib.mkMerge (
      (map (i: {
        "${i.serviceName}" = {
          description = "cross-seed daemon (${i.name})";
          wants = [ "deluged.service" "prowlarr.service" ];
          after = [ "network.target" "deluged.service" "prowlarr.service" ];
          wantedBy = [ "multi-user.target" ];
          # Branch data/link dirs must be on the mounted underlying filesystem so
          # hardlinks stay on the same device.
          unitConfig.RequiresMountsFor = [ i.dataDir i.linkDir ];
          path = [ crossSeedPkg pkgs.coreutils ];
          preStart = ''
            ${pkgs.coreutils}/bin/install -D -m 0640 -g media ${i.configJs} ${i.stateDir}/config.js
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
              "HOME=${i.stateDir}"
              "CONFIG_DIR=${i.stateDir}"
            ];
            UMask = "0002";
          };
        };
      }) instances)
      ++ [
        {
          # Webhook bridge: Deluge (VPN netns) -> UNIX socket -> primary instance.
          cross-seed-webhook = {
            description = "Proxy Deluge webhook from root namespace to cross-seed";
            requires = [ "${primary.serviceName}.service" "cross-seed-webhook.socket" ];
            after = [ "${primary.serviceName}.service" "cross-seed-webhook.socket" ];
            serviceConfig = {
              User = "cross-seed";
              Group = "cross-seed";
              LimitNOFILE = 65536;
              ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --connections-max=4096 --exit-idle-time=5min 127.0.0.1:${toString primary.port}";
            } // loopbackServiceHardening;
          };

          # Daily full-library search sweep across all instances via /api/job (no
          # second process touches a daemon's SQLite DB). ignoreExclude* flags make
          # this a complete sweep.
          cross-seed-search = {
            description = "Trigger daily full-library cross-seed search (all instances)";
            wants = [ "rdfind-sweep.service" ];
            after = [ "network.target" ] ++ map (i: "${i.serviceName}.service") instances;
            requires = map (i: "${i.serviceName}.service") instances;
            serviceConfig = {
              Type = "oneshot";
              User = "cross-seed";
              Group = "cross-seed";
              ExecStart = pkgs.writeShellScript "cross-seed-search-all" ''
                rc=0
                ${lib.concatMapStringsSep "\n                " (i: ''
                  echo "cross-seed-search: ${i.name} (port ${toString i.port})"
                  ${pkgs.curl}/bin/curl -fsS -XPOST \
                    'http://127.0.0.1:${toString i.port}/api/job?apikey=${apiKeys.cross-seed}' \
                    -H 'Content-Type: application/json' \
                    --data '{"name":"search","ignoreExcludeRecentSearch":true,"ignoreExcludeOlder":true}' || rc=$?
                '') instances}
                exit $rc
              '';
            } // loopbackServiceHardening;
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
              ReadWritePaths = [
                "/media/data/torrents/complete"
                "/media/data/torrents/xseeds"
                "/media/data/library/movies"
                "/media/data/library/tv"
              ];
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
        }
      ]
    );

    systemd.sockets.cross-seed-webhook = {
      description = "Socket for cross-seed webhook from Deluge Execute plugin";
      listenStreams = [ "/run/cross-seed/webhook.sock" ];
      socketConfig = {
        SocketGroup = "deluge";
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
