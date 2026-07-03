{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.radarr;
  authXml = lib.optionalString config.media-server.security.enableAuthentication "<AuthenticationMethod>Forms</AuthenticationMethod>";
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
    };

    systemd.services.radarr = {
      preStart = ''
                CONFIG_FILE="/var/lib/radarr/config.xml"
                API_KEY="${config.media-server.apiKeys.radarr}"
                if [ ! -f "$CONFIG_FILE" ]; then
                  cat > "$CONFIG_FILE" << EOF
        <Config>
          <ApiKey>''${API_KEY}</ApiKey>
          <Port>7878</Port>
          <UrlBase></UrlBase>
          <BindAddress>*</BindAddress>
          <EnableSsl>False</EnableSsl>
          ${authXml}
        </Config>
        EOF
                  chown radarr:radarr "$CONFIG_FILE"
                  chmod 600 "$CONFIG_FILE"
                  echo "Seeded Radarr config.xml"
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
