{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.sonarr;
in
{
  options.media-server.sonarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Sonarr";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Sonarr";
    };
  };

  config = mkIf cfg.enable {
    services.sonarr = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
      settings.config.host.apiKey = config.media-server.apiKeys.sonarr;
    };

    systemd.services.sonarr.serviceConfig = {
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
