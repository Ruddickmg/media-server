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
    mkOption
    optionalAttrs
    optionals
    types
    ;
  apiKeys = config.media-server.apiKeys;
  cfg = config.media-server;

  hasAnyArr = cfg.sonarr.enable || cfg.radarr.enable || cfg.lidarr.enable || cfg.prowlarr.enable;

  mkGotifyNotification = priority: {
    "Gotify" = {
      implementation = "Gotify";
      fields = {
        server = "http://127.0.0.1:6789";
        appToken = "DECLARR_SECRET_FILE_GOTIFY_TOKEN";
        inherit priority;
      };
    };
  };

  sonarrCfg = mkIf cfg.sonarr.enable {
    sonarr = {
      declarr = {
        type = "sonarr";
        url = "http://localhost:8989";
      };

      config = {
        host = {
          apiKey = apiKeys.sonarr;
        };
        mediamanagement = {
          enableCompletedDownloadHandling = true;
          copyUsingHardlinks = true;
        };
        naming = {
          renameEpisodes = true;
          standardEpisodeFormat = "{Series Title} - S{season:00}E{episode:00} - {Episode Title}";
          dailyEpisodeFormat = "{Series Title} - {Air-Date} - {Episode Title}";
          animeEpisodeFormat = "{Series Title} - S{season:00}E{episode:00} - {Episode Title}";
          seriesFolderFormat = "{Series Title}";
          seasonFolderFormat = "Season {season:00}";
        };
      };

      qualityProfile = { };
      customFormat = { };

      downloadClient.Deluge = {
        implementation = "Deluge";
        fields = {
          host = "127.0.0.1";
          port = 8112;
          username = "localclient";
          # Tailscale/LAN firewall is the access control, not this password
          # Change via Settings -> Download Client in the *arr web UI at runtime
          password = "deluge";
        };
      };

      notification = mkGotifyNotification 5;

      rootFolder = [ "/media/tv" ];
    };
  };

  radarrCfg = mkIf cfg.radarr.enable {
    radarr = {
      declarr = {
        type = "radarr";
        url = "http://localhost:7878";
      };

      config = {
        host = {
          apiKey = apiKeys.radarr;
        };
        mediamanagement = {
          enableCompletedDownloadHandling = true;
          copyUsingHardlinks = true;
        };
        naming = {
          renameMovies = true;
          standardMovieFormat = "{Movie CleanTitle} ({Release Year})";
          movieFolderFormat = "{Movie CleanTitle} ({Release Year})";
        };
      };

      qualityProfile = { };
      customFormat = { };

      downloadClient.Deluge = {
        implementation = "Deluge";
        fields = {
          host = "127.0.0.1";
          port = 8112;
          username = "localclient";
          # Tailscale/LAN firewall is the access control, not this password
          # Change via Settings -> Download Client in the *arr web UI at runtime
          password = "deluge";
        };
      };

      notification = mkGotifyNotification 5;

      rootFolder = [ "/media/movies" ];
    };
  };

  lidarrCfg = mkIf cfg.lidarr.enable {
    lidarr = {
      declarr = {
        type = "lidarr";
        url = "http://localhost:8686";
      };

      config = {
        host = {
          apiKey = apiKeys.lidarr;
        };
        mediamanagement = {
          enableCompletedDownloadHandling = true;
          copyUsingHardlinks = true;
        };
        naming = {
          renameTracks = true;
          standardTrackFormat = "{Artist Name} - {Album Title} - {track:00} - {Track Title}";
          albumFolderFormat = "{Artist Name} - {Album Title} ({Release Year})";
          artistFolderFormat = "{Artist Name}";
        };
      };

      downloadClient.Deluge = {
        implementation = "Deluge";
        fields = {
          host = "127.0.0.1";
          port = 8112;
          username = "localclient";
          # Tailscale/LAN firewall is the access control, not this password
          # Change via Settings -> Download Client in the *arr web UI at runtime
          password = "deluge";
        };
      };

      notification = mkGotifyNotification 5;

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

      config = {
        host = {
          apiKey = apiKeys.prowlarr;
        };
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
          enableRss = true;
          minimumSeeders = 1;
        };
      };

      applications =
        optionalAttrs cfg.sonarr.enable {
          Sonarr = {
            implementation = "Sonarr";
            syncLevel = "fullSync";
            fields = {
              baseUrl = "http://localhost:8989";
              prowlarrUrl = "http://localhost:9696";
              apiKey = apiKeys.sonarr;
            };
          };
        }
        // optionalAttrs cfg.radarr.enable {
          Radarr = {
            implementation = "Radarr";
            syncLevel = "fullSync";
            fields = {
              baseUrl = "http://localhost:7878";
              prowlarrUrl = "http://localhost:9696";
              apiKey = apiKeys.radarr;
            };
          };
        }
        // optionalAttrs cfg.lidarr.enable {
          Lidarr = {
            implementation = "Lidarr";
            syncLevel = "fullSync";
            fields = {
              baseUrl = "http://localhost:8686";
              prowlarrUrl = "http://localhost:9696";
              apiKey = apiKeys.lidarr;
            };
          };
        };
      notification = mkGotifyNotification 3;

      indexerProxy = null;
    };
  };
in
{
  # Notifications use Gotify via declarr's native DECLARR_SECRET_FILE_* env var resolution.
  # The token is set as a systemd env var pointing to the secret file; declarr reads
  # the file contents at runtime — no build-time exposure.
  options.media-server.declarr = {
    gotifyTokenFile = mkOption {
      type = types.str;
      default = "/etc/nixos/secrets/gotify-token";
      description = "Path to file containing Gotify app token for *arr notifications";
    };
  };

  config = mkIf hasAnyArr {
    services.declarr = {
      enable = true;

      config = mkMerge [
        {
          declarr = {
            stateDir = "/var/lib/declarr";
          };
        }
        sonarrCfg
        radarrCfg
        lidarrCfg
        prowlarrCfg
      ];
    };

    systemd.services.declarr = {
      environment = {
        DECLARR_SECRET_FILE_GOTIFY_TOKEN = cfg.declarr.gotifyTokenFile;
      };

      # declarr configures Deluge as a download client in the *arrs. Deluge's
      # Web UI runs in the VPN netns; root-ns 127.0.0.1:8112 is served by the
      # proxy-deluge-web socket proxy. Without this ordering declarr can race
      # ahead of the proxy, Lidarr's download-client test gets connection
      # refused (HTTP 400), and the 1s restart loop churns for the whole outage.
      after =
        optionals cfg.sonarr.enable [ "sonarr.service" ]
        ++ optionals cfg.radarr.enable [ "radarr.service" ]
        ++ optionals cfg.lidarr.enable [ "lidarr.service" ]
        ++ optionals cfg.prowlarr.enable [ "prowlarr.service" ]
        ++ optionals cfg.deluge.enable [
          "deluged.service"
          "delugeweb.service"
          "proxy-deluge-web.socket"
          "proxy-deluge-web.service"
        ]
        ++ [ "gotify-provision.service" ];
      wants = [
        "network.target"
        "delugeweb.service"
        "proxy-deluge-web.socket"
      ];
      unitConfig = {
        StartLimitBurst = 10;
        OnFailure = "notify-gotify@%n.service";
      };
      serviceConfig = {
        # Slow the self-heal loop: during a Deluge-stack outage each restart
        # re-runs the full *arr sync. 10s cuts API churn while still recovering
        # within 10s of Deluge returning. Notifications stay throttled by the
        # notify-gotify@ backoff.
        RestartSec = "10s";
        SupplementaryGroups = [ "gotify-readers" ];
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
        ProtectSystem = "strict";
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        MemoryDenyWriteExecute = true;
        ReadWritePaths = [
          "/var/lib/declarr"
        ];
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
      };
    };
  };
}
