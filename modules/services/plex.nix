{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.plex;
in
{
  options.media-server.plex = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Plex Media Server";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open ports in firewall for Plex (remote access via Plex auth)";
    };
  };

  config = mkIf cfg.enable {
    services.plex = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
    };

    systemd.services.plex = {
      serviceConfig = {
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        LockPersonality = true;
      };
    };
  };
}
