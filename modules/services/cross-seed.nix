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
  # -> 127.0.0.1:2468. The API key is declared in apiKeys.cross-seed and must be
  # synced into cross-seed's DB once (see integration notes below).
  onCompleteScript = pkgs.writeShellScriptBin "cross-seed-on-complete" ''
    # Arguments from Deluge Execute plugin: $1 = infoHash, $2 = name, $3 = path
    if [ -n "$1" ]; then
      ${pkgs.curl}/bin/curl -sf -XPOST \
        --unix-socket /run/cross-seed/webhook.sock \
        "http://cross-seed/api/webhook?apikey=${apiKeys.cross-seed}&infoHash=$1&includeSingleEpisodes=true" \
        >/dev/null 2>&1
    fi
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
  # 1. One-time API key sync (existing installs only):
  #    cross-seed stores its API key in its SQLite DB, which takes precedence
  #    over config.js. The declared key only takes effect on a freshly
  #    initialized data directory. On an existing install, sync the DB once:
  #      sudo -u cross-seed CONFIG_DIR=/var/lib/cross-seed cross-seed api-key --api-key '<declared key>'
  #    The declared key is derived deterministically from hostname+prefix
  #    (see common.nix), so DB and config.js then agree permanently.
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
      # Declared API key for the webhook. Must live in settingsFile (not
      # settings) — the nixpkgs module asserts against apiKey in `settings` and
      # loads settingsFile as a LoadCredential, merging it into config.js.
      settingsFile = (pkgs.formats.json { }).generate "cross-seed-secrets.json" {
        apiKey = apiKeys.cross-seed;
      };
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
      };
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
      "/run/cross-seed".d = {
        mode = "0770";
        user = "root";
        group = "deluge";
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
