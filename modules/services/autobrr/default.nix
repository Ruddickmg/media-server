{
  lib,
  pkgs,
  config,
  pkgs-unstable,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.autobrr;
  apiKeys = config.media-server.apiKeys;
  autobrrApiKeyFile = pkgs.writeText "autobrr-api-key" apiKeys.autobrr;

  # Lua runtime for the setup script, with the modules it requires.
  luaRuntime = pkgs.lua5_3.withPackages (ps: [ ps.cjson ps.luasocket ps.luasql-sqlite3 ]);

  # Runtime values that only exist at eval time, injected as JSON overrides
  # (see load_config in setup.lua). The API key file may not exist yet on a
  # fresh boot, so the writeText fallback (always present in the store) backs
  # it up — same cat-A-||-cat-B logic the bash script used.
  setupConfig = pkgs.writeText "autobrr-setup.json" (builtins.toJSON {
    autobrr_base = "http://127.0.0.1:${toString cfg.port}/autobrr/api";
    autobrr_db = "${cfg.dataDir}/autobrr.db";
    api_key_file = cfg.apiKeyFile;
    api_key_file_fallback = autobrrApiKeyFile;
    gotify_token_file = cfg.gotifyTokenFile;
    arrs = [
      {
        name = "Sonarr";
        api_key = apiKeys.sonarr;
        fallback_categories = cfg.fallbackCategories.sonarr;
      }
      {
        name = "Radarr";
        api_key = apiKeys.radarr;
        fallback_categories = cfg.fallbackCategories.radarr;
      }
      {
        name = "Lidarr";
        api_key = apiKeys.lidarr;
        fallback_categories = cfg.fallbackCategories.lidarr;
      }
    ];
  });

  postStartScript = pkgs.writeShellScriptBin "autobrr-setup" ''
    exec ${luaRuntime}/bin/lua ${./setup.lua} ${setupConfig}
  '';
in
{
  options.media-server.autobrr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable autobrr IRC announce-based release automation";
    };
    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/autobrr";
      description = "Data directory for autobrr";
    };
    port = mkOption {
      type = types.port;
      default = 7474;
      description = "Web UI listen port";
    };
    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Listen address";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open port in firewall for autobrr web UI";
    };
    apiKeyFile = mkOption {
      type = types.path;
      default = "/var/lib/autobrr/apiKey";
      description = "Path to file containing the autobrr API key";
    };
    gotifyTokenFile = mkOption {
      type = types.path;
      default = "/etc/nixos/secrets/gotify-token";
      description = "Path to Gotify application token file";
    };
    fallbackCategories = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = {
        sonarr = [ "TV*" ];
        radarr = [ "Movie*" ];
        lidarr = [ "Audio*" "Music*" "FLAC*" "MP3*" ];
      };
      description = "Category patterns (substring/wildcard, case-insensitive, OR within the list) used by the low-priority fallback filters. When a release's title matches no list-backed title filter, its announce category routes it to the matching *arr (e.g. TV* -> Sonarr). An empty list skips that *arr's fallback filter.";
    };
  };

  config = mkIf cfg.enable {
    users.users.autobrr = {
      group = "autobrr";
      description = "autobrr service user";
      isSystemUser = true;
      home = cfg.dataDir;
    };

    users.groups.autobrr = { };

    systemd.tmpfiles.settings."10-autobrr" = {
      "${cfg.dataDir}".d = {
        user = "autobrr";
        group = "autobrr";
        mode = "700";
      };
      # Ensure secret files are readable by the autobrr group.
      # Rules only apply to existing files — create them after first boot.
      "${cfg.apiKeyFile}".z = {
        mode = "0640";
        group = "autobrr";
      };
      "${cfg.gotifyTokenFile}".z = {
        mode = "0640";
        group = "autobrr";
      };
    };

    systemd.services.autobrr = {
      description = "autobrr - IRC announce-based release automation";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        AUTOBRR__HOST = cfg.listenAddress;
        AUTOBRR__PORT = toString cfg.port;
        AUTOBRR__BASE_URL = "/autobrr/";
        AUTOBRR__BASE_URL_MODE_LEGACY = "false";
        AUTOBRR__LOG_LEVEL = "INFO";
      };

      preStart = ''
        # Create session secret if it doesn't exist
        if [ ! -f "${cfg.dataDir}/session.secret" ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "${cfg.dataDir}/session.secret"
          chown autobrr:autobrr "${cfg.dataDir}/session.secret"
          chmod 600 "${cfg.dataDir}/session.secret"
        fi
      '';

      postStart = "${postStartScript}/bin/autobrr-setup";

      serviceConfig = {
        Type = "simple";
        User = "autobrr";
        Group = "autobrr";
        ExecStart = "${pkgs-unstable.autobrr}/bin/autobrr --config=${cfg.dataDir}";
        Restart = "on-failure";
        RestartSec = "10s";
        StateDirectory = "autobrr";
        StateDirectoryMode = "0750";
        ReadWritePaths = [ cfg.dataDir ];

        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        PrivateDevices = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectSystem = "strict";
        MemoryDenyWriteExecute = true;
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
      };

      unitConfig = {
        StartLimitBurst = 10;
        OnFailure = "notify-gotify@%n.service";
      };
    };

    environment.systemPackages = [
      pkgs-unstable.autobrr
      postStartScript
    ];

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
    };
  };
}
