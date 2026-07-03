{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.sonarr;
  authXml = lib.optionalString config.media-server.security.enableAuthentication "<AuthenticationMethod>Forms</AuthenticationMethod>";
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
    };

    systemd.services.sonarr = {
      preStart = ''
                CONFIG_FILE="/var/lib/sonarr/config.xml"
                API_KEY="${config.media-server.apiKeys.sonarr}"
                if [ ! -f "$CONFIG_FILE" ]; then
                  cat > "$CONFIG_FILE" << EOF
        <Config>
          <ApiKey>''${API_KEY}</ApiKey>
          <Port>8989</Port>
          <UrlBase></UrlBase>
          <BindAddress>*</BindAddress>
          <EnableSsl>False</EnableSsl>
          ${authXml}
        </Config>
        EOF
                  chown sonarr:sonarr "$CONFIG_FILE"
                  chmod 600 "$CONFIG_FILE"
                  echo "Seeded Sonarr config.xml"
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
