{ lib, pkgs, config, ... }:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.lidarr;
  authXml = lib.optionalString config.media-server.security.enableAuthentication
    "<AuthenticationMethod>Forms</AuthenticationMethod>";
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
    };

    systemd.services.lidarr = {
      preStart = ''
        CONFIG_FILE="/var/lib/lidarr/config.xml"
        API_KEY="${config.media-server.apiKeys.lidarr}"
        if [ ! -f "$CONFIG_FILE" ]; then
          cat > "$CONFIG_FILE" << EOF
<Config>
  <ApiKey>''${API_KEY}</ApiKey>
  <Port>8686</Port>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <EnableSsl>False</EnableSsl>
  ${authXml}
</Config>
EOF
          chown lidarr:lidarr "$CONFIG_FILE"
          chmod 600 "$CONFIG_FILE"
          echo "Seeded Lidarr config.xml"
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
