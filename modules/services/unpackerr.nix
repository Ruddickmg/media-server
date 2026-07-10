{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.unpackerr;
  apiKeys = config.media-server.apiKeys;
in
{
  options.media-server.unpackerr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Unpackerr (automatic archive extraction)";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Unpackerr metrics endpoint";
    };
  };

  config = mkIf cfg.enable {
    users.users.unpackerr = {
      group = "media";
      isSystemUser = true;
    };

    systemd.services.unpackerr = {
      description = "Unpackerr - automated archive extraction";
      after = [
        "network.target"
        "sonarr.service"
        "radarr.service"
        "lidarr.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        EnvironmentFile = [
          (toString (
            pkgs.writeText "unpackerr-env" ''
              UN_SONARR_0_URL=http://localhost:8989
              UN_SONARR_0_API_KEY=${apiKeys.sonarr}
              UN_RADARR_0_URL=http://localhost:7878
              UN_RADARR_0_API_KEY=${apiKeys.radarr}
              UN_LIDARR_0_URL=http://localhost:8686
              UN_LIDARR_0_API_KEY=${apiKeys.lidarr}
              UN_FOLDER_0_ENABLE=true
              UN_FOLDER_0_PATH=/media/downloads/completed
              UN_FOLDER_0_INTERVAL=1s
              UN_EXTRACTOR_DELETE_AFTER=true
            ''
          ))
        ];
        Type = "simple";
        User = "unpackerr";
        Group = "media";
        ExecStart = "${pkgs.unpackerr}/bin/unpackerr";
        Restart = "on-failure";
        RestartSec = "10";
        StateDirectory = "unpackerr";
        StateDirectoryMode = "0750";
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
        ReadWritePaths = [
          "/var/lib/unpackerr"
          "/media/downloads/completed"
        ];
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ 5656 ];
    };
  };
}
