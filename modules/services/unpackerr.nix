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

      preStart = ''
                CONFIG_FILE="/var/lib/unpackerr/unpackerr.conf"
                if [ ! -f "$CONFIG_FILE" ]; then
                  mkdir -p "$(dirname "$CONFIG_FILE")"
                  cat > "$CONFIG_FILE" << EOF
        [[sonarr]]
          url = "http://localhost:8989"
          api_key = "${apiKeys.sonarr}"
        [[radarr]]
          url = "http://localhost:7878"
          api_key = "${apiKeys.radarr}"
        [[lidarr]]
          url = "http://localhost:8686"
          api_key = "${apiKeys.lidarr}"
        [folders]
          enable = true
          paths = ["/media/downloads/completed"]
          interval = "1s"
        [extractor]
          delete_after = true
        EOF
                  chown unpackerr:media "$CONFIG_FILE"
                  chmod 600 "$CONFIG_FILE"
                  echo "Seeded Unpackerr config"
                fi
      '';

      serviceConfig = {
        Type = "simple";
        User = "unpackerr";
        Group = "media";
        ExecStart = "${pkgs.unpackerr}/bin/unpackerr -c /var/lib/unpackerr/unpackerr.conf";
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
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ 5656 ];
    };
  };
}
