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
    mkOverride
    types
    optionalAttrs
    ;
  cfg = config.media-server.seerr;
  apiKeys = config.media-server.apiKeys;
  sonarrEnabled = config.media-server.sonarr.enable or false;
  radarrEnabled = config.media-server.radarr.enable or false;

  mkSonarr = {
    name = "Sonarr";
    hostname = "localhost";
    port = 8989;
    apiKey = apiKeys.sonarr;
    useSsl = false;
    baseUrl = "";
    activeProfileId = 1;
    activeProfileName = "Any";
    activeAnimeProfileId = 1;
    activeAnimeProfileName = "Any";
    activeDirectory = "/media/tv";
    activeAnimeDirectory = "/media/tv";
    id = 0;
    is4k = false;
    enableScan = true;
    enableAutomaticSearch = false;
  };

  mkRadarr = {
    name = "Radarr";
    hostname = "localhost";
    port = 7878;
    apiKey = apiKeys.radarr;
    useSsl = false;
    baseUrl = "";
    activeProfileId = 1;
    activeProfileName = "Any";
    activeDirectory = "/media/movies";
    id = 0;
    is4k = false;
    enableScan = true;
    enableAutomaticSearch = false;
    minimumAvailability = "announced";
  };

  settingsJson = builtins.toJSON (
    {
      initialized = true;
      main = { };
    }
    // optionalAttrs sonarrEnabled {
      sonarr = [ mkSonarr ];
    }
    // optionalAttrs radarrEnabled {
      radarr = [ mkRadarr ];
    }
  );

  settingsFile = pkgs.writeText "seerr-settings" settingsJson;
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
  };

  config = mkIf cfg.enable {
    services.seerr = {
      enable = true;
      openFirewall = cfg.openFirewall;
      package = pkgs-unstable.seerr;
    };

    systemd.services.seerr = {
      environment.SEERR_API_KEY = apiKeys.seerr;
      serviceConfig.ExecStart = mkOverride 40 (lib.getExe pkgs-unstable.seerr);
      preStart = ''
        CONFIG_FILE="/var/lib/seerr/settings.json"
        if [ ! -f "$CONFIG_FILE" ]; then
          cp ${settingsFile} "$CONFIG_FILE"
          chmod 600 "$CONFIG_FILE"
          chown --reference=/var/lib/seerr "$CONFIG_FILE"
          echo "Seeded Seerr settings.json with Sonarr/Radarr configuration"
        fi
      '';
    };
  };
}
