{
  lib,
  pkgs,
  config,
  pkgs-unstable,
  ...
}:
let
  inherit (lib)
    mkIf
    mkOption
    types
    optionalString
    ;
  cfg = config.media-server.seerr;
  apiKeys = config.media-server.apiKeys;
  sonarrEnabled = config.media-server.sonarr.enable or false;
  radarrEnabled = config.media-server.radarr.enable or false;
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
    systemd.tmpfiles.rules = [
      "d /var/lib/seerr/config 0755 seerr seerr -"
    ];

    users.users.seerr = {
      group = "seerr";
      isSystemUser = true;
    };

    users.groups.seerr = { };

    systemd.services.seerr = {
      description = "Seerr - Media request and discovery manager";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        SEERR_DATA_DIR = "/var/lib/seerr";
        PORT = toString cfg.port;
        NODE_ENV = "production";
        SEERR_API_KEY = apiKeys.seerr;
      };
      preStart = ''
                CONFIG_FILE="/var/lib/seerr/settings.json"
                if [ ! -f "$CONFIG_FILE" ]; then
                  cat > "$CONFIG_FILE" << EOF
              {
                "initialized": true${optionalString sonarrEnabled ''
                  ,
                  "sonarr": [
                    {
                      "name": "Sonarr",
                      "hostname": "localhost",
                      "port": 8989,
                      "apiKey": "${apiKeys.sonarr}",
                      "useSsl": false,
                      "baseUrl": "",
                      "activeProfileId": 1,
                      "activeProfileName": "Any",
                      "activeAnimeProfileId": 1,
                      "activeAnimeProfileName": "Any",
                      "activeDirectory": "/media/tv",
                      "activeAnimeDirectory": "/media/tv",
                      "id": 0,
                      "is4k": false,
                      "enableScan": true,
                      "enableAutomaticSearch": false
                    }
                  ]''}${optionalString radarrEnabled ''
                  ,
                  "radarr": [
                    {
                      "name": "Radarr",
                      "hostname": "localhost",
                      "port": 7878,
                      "apiKey": "${apiKeys.radarr}",
                      "useSsl": false,
                      "baseUrl": "",
                      "activeProfileId": 1,
                      "activeProfileName": "Any",
                      "activeDirectory": "/media/movies",
                      "id": 0,
                      "is4k": false,
                      "enableScan": true,
                      "enableAutomaticSearch": false,
                      "minimumAvailability": "announced"
                    }
                  ]''}
              }
        EOF
                  chown seerr:seerr "$CONFIG_FILE"
                  chmod 600 "$CONFIG_FILE"
                  echo "Seeded Seerr settings.json with Sonarr/Radarr configuration"
                fi
      '';
      serviceConfig = {
        Type = "exec";
        User = "seerr";
        Group = "seerr";
        WorkingDirectory = "/var/lib/seerr";
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
        BindPaths = [ "/var/lib/seerr/config:${pkgs-unstable.seerr}/share/config" ];
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
    };
  };
}
