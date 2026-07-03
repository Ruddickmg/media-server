{ lib, pkgs, config, ... }:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.unpackerr;
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
      description = "Open ports in firewall for Unpackerr web UI";
    };
  };

  config = mkIf cfg.enable {
    services.unpackerr = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
      settings = {
        sonarr = {
          "0" = {
            api_key = config.media-server.apiKeys.sonarr;
            urls = [ "http://127.0.0.1:8989" ];
          };
        };
        radarr = {
          "0" = {
            api_key = config.media-server.apiKeys.radarr;
            urls = [ "http://127.0.0.1:7878" ];
          };
        };
        lidarr = {
          "0" = {
            api_key = config.media-server.apiKeys.lidarr;
            urls = [ "http://127.0.0.1:8686" ];
          };
        };
        extractor_paths = [ "/media/downloads/completed" ];
        delete_after_extraction = true;
      };
    };

    systemd.services.unpackerr = {
      serviceConfig = {
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        MemoryDenyWriteExecute = true;
        PrivateDevices = true;
        LockPersonality = true;
        RestrictNamespaces = true;
      };
    };
  };
}
