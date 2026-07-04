{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib)
    mkIf
    mkMerge
    optionals
    ;
  apiKeys = config.media-server.apiKeys;
  delugePassword = config.media-server.credentials.delugePassword;
  cfg = config.media-server;

  hasAnyArr = cfg.sonarr.enable || cfg.radarr.enable || cfg.lidarr.enable || cfg.prowlarr.enable;

  sonarrCfg = mkIf cfg.sonarr.enable {
    sonarr = {
      declarr = {
        type = "sonarr";
        url = "http://localhost:8989";
      };

      downloadClient.Deluge = {
        implementation = "Deluge";
        fields = {
          host = "localhost";
          port = 58846;
          password = delugePassword;
        };
      };

      rootFolder = [ "/media/tv" ];
    };
  };

  radarrCfg = mkIf cfg.radarr.enable {
    radarr = {
      declarr = {
        type = "radarr";
        url = "http://localhost:7878";
      };

      downloadClient.Deluge = {
        implementation = "Deluge";
        fields = {
          host = "localhost";
          port = 58846;
          password = delugePassword;
        };
      };

      rootFolder = [ "/media/movies" ];
    };
  };

  lidarrCfg = mkIf cfg.lidarr.enable {
    lidarr = {
      declarr = {
        type = "lidarr";
        url = "http://localhost:8686";
      };

      downloadClient.Deluge = {
        implementation = "Deluge";
        fields = {
          host = "localhost";
          port = 58846;
          password = delugePassword;
        };
      };

      rootFolder.main = {
        path = "/media/music";
        defaultMetadataProfileId = "Standard";
        defaultMonitorOption = "all";
        defaultNewItemMonitorOption = "all";
        defaultQualityProfileId = "Standard";
        defaultTags = [ ];
      };
    };
  };

  prowlarrCfg = mkIf cfg.prowlarr.enable {
    prowlarr = {
      declarr = {
        type = "prowlarr";
        url = "http://localhost:9696";
      };

      appProfile = {
        Standard = {
          enableAutomaticSearch = true;
          enableInteractiveSearch = true;
          enableRss = true;
          minimumSeeders = 1;
        };
        Automatic = {
          enableAutomaticSearch = true;
          enableInteractiveSearch = false;
          enableRss = true;
          minimumSeeders = 1;
        };
        "Interactive Search" = {
          enableAutomaticSearch = false;
          enableInteractiveSearch = true;
          enableRss = false;
          minimumSeeders = 1;
        };
      };

      applications = mkMerge [
        (mkIf cfg.sonarr.enable {
          Sonarr = {
            implementation = "Sonarr";
            syncLevel = "fullSync";
            fields = {
              baseUrl = "http://localhost:8989";
              prowlarrUrl = "http://localhost:9696";
              apiKey = apiKeys.sonarr;
            };
          };
        })
        (mkIf cfg.radarr.enable {
          Radarr = {
            implementation = "Radarr";
            syncLevel = "fullSync";
            fields = {
              baseUrl = "http://localhost:7878";
              prowlarrUrl = "http://localhost:9696";
              apiKey = apiKeys.radarr;
            };
          };
        })
        (mkIf cfg.lidarr.enable {
          Lidarr = {
            implementation = "Lidarr";
            syncLevel = "fullSync";
            fields = {
              baseUrl = "http://localhost:8686";
              prowlarrUrl = "http://localhost:9696";
              apiKey = apiKeys.lidarr;
            };
          };
        })
      ];
    };
  };
in
{
  services.declarr = mkIf hasAnyArr {
    enable = true;

    config = mkMerge [
      {
        declarr.stateDir = "/var/lib/declarr";
      }
      sonarrCfg
      radarrCfg
      lidarrCfg
      prowlarrCfg
    ];
  };

  systemd.services.declarr = mkIf hasAnyArr {
    after =
      optionals cfg.sonarr.enable [ "sonarr.service" ]
      ++ optionals cfg.radarr.enable [ "radarr.service" ]
      ++ optionals cfg.lidarr.enable [ "lidarr.service" ]
      ++ optionals cfg.prowlarr.enable [ "prowlarr.service" ]
      ++ optionals cfg.deluge.enable [ "deluged.service" ];
    wants = [ "network.target" ];
  };
}
