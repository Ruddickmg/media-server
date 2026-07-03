{ lib, pkgs, config, pkgs-unstable, ... }:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.seerr;
in
{
  options.media-server.seerr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Seerr media request manager";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open port 5055 for Seerr web UI";
    };
    port = mkOption {
      type = types.port;
      default = 5055;
      description = "Port for the Seerr web UI";
    };
  };

  config = mkIf cfg.enable {
    users.users.seerr = {
      group = "seerr";
      isSystemUser = true;
    };

    users.groups.seerr = {};

    systemd.services.seerr = {
      description = "Seerr - Media request and discovery manager";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        SEERR_DATA_DIR = "/var/lib/seerr";
        PORT = toString cfg.port;
        NODE_ENV = "production";
      };
      serviceConfig = {
        Type = "exec";
        User = "seerr";
        Group = "seerr";
        WorkingDirectory = "${pkgs-unstable.seerr}/share";
        ExecStart = "${pkgs-unstable.seerr}/bin/seerr";
        Restart = "on-failure";
        RestartSec = "10";
        StateDirectory = "seerr";
        StateDirectoryMode = "0700";
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

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
    };
  };
}
