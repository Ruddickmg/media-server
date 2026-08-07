{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.cross-seed;
  apiKeys = config.media-server.apiKeys;

  # Prowlarr assigns indexers sequential numeric IDs: /1/api, /2/api, etc.
  # List up to 10 — unused IDs 404 gracefully.
  torznabUrls = builtins.genList (
    i: "http://127.0.0.1:9696/prowlarr/${toString (i + 1)}/api?apikey=${apiKeys.prowlarr}"
  ) 10;

  # Deluge Execute plugin script: triggers a cross-seed search when a torrent
  # finishes downloading. Deluge runs inside the VPN netns while cross-seed
  # listens on 127.0.0.1:2468 in the root namespace. A filesystem UNIX socket
  # (visible across network namespaces) bridged by the cross-seed-webhook proxy
  # carries the request: curl -> /run/cross-seed/webhook.sock -> socket-proxyd
  # -> 127.0.0.1:2468. The API key (apiKeys.cross-seed) is embedded directly in
  # config.js (see configJs below) and used for webhook auth; cross-seed's
  # getApiKey() reads it before its SQLite settings table, so no DB sync.
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

  # Declared API key, embedded directly into config.js at build time. Deliberately
  # NOT via the nixpkgs module's settingsFile/LoadCredential: that makes config.js
  # read process.env.CREDENTIALS_DIRECTORY (systemd-only), which breaks `cross-seed`
  # from a shell. The key is derived deterministically from hostname+prefix (see
  # common.nix) and already appears in the store via onCompleteScript, so embedding
  # it here is not a security regression.
  configJs = pkgs.writeText "cross-seed-config.js" ''
    module.exports = ${
      builtins.toJSON (config.services.cross-seed.settings // { apiKey = apiKeys.cross-seed; })
    };
  '';

  # PATH `cross-seed`: sets CONFIG_DIR/HOME so plain `cross-seed search` finds the
  # data dir (cross-seed's appDir() is $CONFIG_DIR, else $HOME/.cross-seed), and
  # umask 002 so files created by either the daemon or the CLI are group-writable
  # in the 2770 cross-seed:media data dir (both are media-group members). It makes
  # no privilege changes — it runs as whoever invokes it (media-server from a
  # shell, cross-seed via systemd User=). The real binary is not on PATH, so it
  # can't be run with a wrong config dir or umask.
  crossSeedCli = pkgs.writeShellScriptBin "cross-seed" ''
    umask 002
    exec env HOME='${cfg.dataDir}' CONFIG_DIR='${cfg.dataDir}' \
      ${pkgs.cross-seed}/bin/cross-seed "$@"
  '';

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
      description = "Data directory for cross-seed";
    };
  };

  # Integration notes (post-deploy manual steps):
  #
  # 1. API key (no step needed):
  #    The declared key (apiKeys.cross-seed, derived deterministically from
  #    hostname+prefix — see common.nix) is embedded into config.js at build
  #    time and serves both webhook and CLI auth. v6 getApiKey() (src/auth.ts)
  #    reads the config.js apiKey before the SQLite settings table, so no DB
  #    sync is needed. Embedding (instead of the module's settingsFile /
  #    LoadCredential) keeps config.js free of systemd's CREDENTIALS_DIRECTORY
  #    so `cross-seed` also works from a shell.
  #
  # 2. Deluge on-completion webhook:
  #    The Execute plugin is enabled and the "Torrent Complete" command is
  #    pre-seeded into execute.conf by the deluge module, so no Web UI step is
  #    needed. The cross-seed-on-complete script is installed system-wide.
  #    No need to tag/filter cross-seed-injected torrents: /api/webhook defaults
  #    to ignoreCrossSeeds=true, so cross-seed skips torrents it injected itself.

  config = mkIf cfg.enable {
    services.cross-seed = {
      enable = true;
      configDir = cfg.dataDir;
      # PATH cross-seed is the env-setting launcher (see crossSeedCli); the
      # daemon and CLI share it, so the config dir and umask are always right.
      package = crossSeedCli;
      settings = {
        dataDirs = [
          "/media/downloads/completed"
        ];
        linkDirs = [
          "/media/downloads/xseeds"
        ];
        outputDir = null;
        port = 2468;
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
    };

    # cross-seed user is a member of the media group, which owns the /media
    # data and link dirs (2775 root:media), so both the daemon and the CLI
    # launcher can read dataDirs and hardlink into linkDirs.
    users.users.cross-seed = {
      extraGroups = [ "media" ];
    };

    systemd.services.cross-seed = {
      wants = [
        "deluged.service"
        "prowlarr.service"
      ];
      after = [
        "deluged.service"
        "prowlarr.service"
      ];
      serviceConfig = {
        SupplementaryGroups = [
          "media"
        ];
        # Clear the module's StateDirectory="cross-seed", which makes systemd
        # re-chown the data dir to cross-seed:cross-seed on every start — wiping
        # the declared cross-seed:media group. This nixpkgs exposes StateDirectory
        # only via the serviceConfig freeform (there is no `stateDirectory`
        # option). The tmpfiles d rule below owns creation and mode.
        StateDirectory = lib.mkForce [ ];
      };
      # Install config.js (settings + embedded apiKey) as cross-seed:media 0640 so
      # the CLI (run as a media-group member) can read it. Replaces the nixpkgs
      # module's preStart, which loaded the apiKey via LoadCredential and baked a
      # systemd-only CREDENTIALS_DIRECTORY dependency into config.js that crashed
      # `cross-seed` from a shell. Runs as the cross-seed service user (non-root).
      preStart = lib.mkForce ''
        ${pkgs.coreutils}/bin/install -D -m 0640 -g media ${configJs} ${cfg.dataDir}/config.js
      '';
    };

    # Webhook bridge: Deluge (VPN netns) -> UNIX socket -> cross-seed (root ns).
    # Filesystem UNIX sockets are shared across network namespaces, so a socket
    # in /run lets the deluge Execute plugin reach cross-seed's 127.0.0.1:2468
    # listener through a root-namespace systemd-socket-proxyd. This is the
    # proxy-deluge pattern from the deluge module, inverted (unix socket instead
    # of tcp, root namespace instead of vpn namespace). The directory is 0770
    # root:deluge so the Execute subprocess (running as the deluge user) can
    # traverse it; deluged also needs /run/cross-seed in its ReadWritePaths
    # because ProtectSystem=strict remounts /run read-only and the kernel
    # rejects connect() to a socket on a read-only mount.
    systemd.tmpfiles.settings."10-cross-seed" = {
      # Cross-seed's data dir: setgid cross-seed:media 2770, mirroring the /media
      # rules in common.nix — cross-seed owns it, and the media group (deluge,
      # sonarr, radarr, unpackerr, the media-server login) can run the CLI. mkForce
      # overrides the module's 0700 rule; Z recursively re-owns the legacy
      # root-owned files (left by pre-module root CLI runs that broke the daemon's
      # utime with EPERM) — declarative repair, no runtime chown.
      "${cfg.dataDir}" = {
        d = lib.mkForce {
          mode = "2770";
          user = "cross-seed";
          group = "media";
        };
        Z = {
          user = "cross-seed";
          group = "media";
        };
      };
      "/run/cross-seed" = {
        d = {
          mode = "0770";
          user = "root";
          group = "deluge";
        };
      };
    };

    systemd.sockets.cross-seed-webhook = {
      description = "Socket for cross-seed webhook from Deluge Execute plugin";
      listenStreams = [ "/run/cross-seed/webhook.sock" ];
      socketConfig = {
        SocketGroup = "deluge";
        SocketMode = "0660";
      };
      wantedBy = [ "sockets.target" ];
    };

    systemd.services.cross-seed-webhook = {
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
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --connections-max=4096 --exit-idle-time=5min 127.0.0.1:2468";
        # Hardening — mirror the proxy-deluge service profile.
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
    };

    # Make the on-completion script available for the Deluge Execute plugin.
    environment.systemPackages = [ onCompleteScript ];

  };
}
