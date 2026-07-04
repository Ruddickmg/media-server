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
      settings.config.host.apiKey = config.media-server.apiKeys.radarr;
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
