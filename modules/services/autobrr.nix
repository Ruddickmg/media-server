{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.autobrr;
  apiKeys = config.media-server.apiKeys;

  settingsFormat = pkgs.formats.json { };

  # autobrr config — generated declaratively
  configFile = settingsFormat.generate "autobrr-config.json" {
    host = cfg.listenAddress;
    port = cfg.port;
    logLevel = "INFO";
    logPath = "stdout";
    sessionSecretFile = "${cfg.dataDir}/session.secret";
    databasePath = "${cfg.dataDir}/autobrr.db";
    # IRC, indexers, filters, download clients, and *arr integrations
    # are configured via the web UI at first run, then persist in the DB.
    # Declarative seeding of initial config is limited; we set up the
    # critical connectivity so the UI can be used to finish configuration.
  };
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
    };

    systemd.services.autobrr = {
      description = "autobrr - IRC announce-based release automation";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        AUTOBRR__HOST = cfg.listenAddress;
        AUTOBRR__PORT = toString cfg.port;
        AUTOBRR__LOG_LEVEL = "INFO";
        AUTOBRR__LOG_PATH = "stdout";
      };

      preStart = ''
        # Create session secret if it doesn't exist
        if [ ! -f "${cfg.dataDir}/session.secret" ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "${cfg.dataDir}/session.secret"
          chown autobrr:autobrr "${cfg.dataDir}/session.secret"
          chmod 600 "${cfg.dataDir}/session.secret"
        fi
      '';

      serviceConfig = {
        Type = "simple";
        User = "autobrr";
        Group = "autobrr";
        ExecStart = "${pkgs.autobrr}/bin/autobrr --config=${cfg.dataDir}";
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

    environment.systemPackages = [ pkgs.autobrr ];

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
    };
  };
}
