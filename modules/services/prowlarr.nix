{ lib, pkgs, config, ... }:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.prowlarr;
  authXml = lib.optionalString config.media-server.security.enableAuthentication
    "<AuthenticationMethod>Forms</AuthenticationMethod>";
in
{
  options.media-server.prowlarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Prowlarr";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Prowlarr";
    };
  };

  config = mkIf cfg.enable {
    services.prowlarr = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
    };

    systemd.services.prowlarr = {
      preStart = ''
        CONFIG_FILE="/var/lib/prowlarr/config.xml"
        API_KEY="${config.media-server.apiKeys.prowlarr}"
        if [ ! -f "$CONFIG_FILE" ]; then
          cat > "$CONFIG_FILE" << EOF
<Config>
  <ApiKey>''${API_KEY}</ApiKey>
  <Port>9696</Port>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <EnableSsl>False</EnableSsl>
  ${authXml}
</Config>
EOF
          chown prowlarr:prowlarr "$CONFIG_FILE"
          chmod 600 "$CONFIG_FILE"
          echo "Seeded Prowlarr config.xml"
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
