{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.radarr;
in
{
  options.media-server.radarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Radarr";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Radarr";
    };
  };

  config = mkIf cfg.enable {
    services.radarr = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
      settings.server.urlbase = "/radarr";
      apiKeyFile = "${pkgs.writeText "radarr-api-key" config.media-server.apiKeys.radarr}";
      environmentFiles = [
        (pkgs.writeText "radarr-env" ''
          RADARR__CONFIG__HOST__APIKEY=${config.media-server.apiKeys.radarr}
        '')
      ];
    };

    systemd.services.radarr.serviceConfig = {
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
