{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.lidarr;
in
{
  options.media-server.lidarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Lidarr";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Lidarr";
    };
  };

  config = mkIf cfg.enable {
    services.lidarr = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
      apiKeyFile = "${pkgs.writeText "lidarr-api-key" config.media-server.apiKeys.lidarr}";
      environmentFiles = [
        (pkgs.writeText "lidarr-env" ''
          LIDARR__CONFIG__HOST__APIKEY=${config.media-server.apiKeys.lidarr}
        '')
      ];
    };

    systemd.services.lidarr.serviceConfig = {
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
    };
  };
}
