{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.bazarr;
in
{
  options.media-server.bazarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Bazarr";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Bazarr";
    };
  };

  config = mkIf cfg.enable {
    services.bazarr = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
    };

    systemd.services.bazarr = {
      preStart = ''
                CONFIG_FILE="/var/lib/bazarr/config/config.ini"
                SONARR_KEY="${config.media-server.apiKeys.sonarr}"
                RADARR_KEY="${config.media-server.apiKeys.radarr}"
                if [ ! -f "$CONFIG_FILE" ]; then
                  mkdir -p "$(dirname "$CONFIG_FILE")"
                  cat > "$CONFIG_FILE" << EOF
        [General]
        ip = 127.0.0.1
        port = 6767
        base_url = /bazarr

        [sonarr]
        api_key = ''${SONARR_KEY}
        full_update = True
        enabled = True

        [radarr]
        api_key = ''${RADARR_KEY}
        full_update = True
        enabled = True
        EOF
                  chown -R bazarr:bazarr "$(dirname "$CONFIG_FILE")"
                  chmod 600 "$CONFIG_FILE"
                  echo "Seeded Bazarr config.ini"
                fi
      '';
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
        PrivateDevices = true;
        LockPersonality = true;
        RestrictNamespaces = true;
      };
    };
  };
}
