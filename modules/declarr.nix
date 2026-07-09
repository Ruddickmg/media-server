{
  lib,
  pkgs,
  config,
  dictionarry-db,
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

  gotifyTokenFile = cfg.declarr.gotifyTokenFile;
  gotifyTokenPresent = builtins.pathExists gotifyTokenFile;
  mkGotifyNotification =
    priority:
    if gotifyTokenPresent then
      {
        "Gotify" = {
          implementation = "Gotify";
          fields = {
            server = "http://127.0.0.1:6789";
            appToken = "DECLARR_SECRET_FILE_GOTIFY_TOKEN";
            inherit priority;
          };
        };
      }
    else
      null;

  # Parse a YAML file from the Dictionarry Database flake input into a Nix
  # attribute set.  Uses yq at evaluation time (IFD).  The path MUST be a
  # path-type value (not a string) so Nix copies it into the store and the
  # sandboxed builder can read it.  We reference ${path} directly in the
  # build script to ensure the dependency is tracked.
  parseYaml =
    path:
    let
      json = pkgs.runCommand "yaml-to-json" { buildInputs = [ pkgs.yq ]; } ''
        yq -oj < ${path} > $out
      '';
    in
    builtins.fromJSON (builtins.readFile json);

  # Dictionarry Database profiles, parsed at evaluation time from the pinned
  # flake input.  These always reflect the upstream Database state.
  # NOTE: Use path concatenation (path + string) so the result stays a path
  # type and Nix tracks it as a derivation dependency.
  profile1080pQuality = parseYaml (dictionarry-db + "/profiles/1080p Quality.yml");
  profile2160pQuality = parseYaml (dictionarry-db + "/profiles/2160p Quality.yml");
  profile720pQuality = parseYaml (dictionarry-db + "/profiles/720p Quality.yml");
  profile1080pBalanced = parseYaml (dictionarry-db + "/profiles/1080p Balanced.yml");

  # Freeleech scores added to every profile so that freeleech releases are
  # preferred within the same quality tier.  Quality is always the primary
  # sort key, so freeleech never overrides a higher-quality non-freeleech
  # release.
  freeleechScores = [
    {
      name = "Freeleech";
      score = 500;
    }
    {
      name = "Freeleech75";
      score = 300;
    }
    {
      name = "Freeleech50";
      score = 200;
    }
  ];

  # Merge freeleech scores into the three custom-format lists that a profile
  # may carry.  Dictionarry profiles already have custom_formats,
  # custom_formats_radarr, and custom_formats_sonarr arrays; we append the
  # freeleech entries to each so the upstream scores are preserved.
  mkProfile =
    base:
    base
    // {
      custom_formats = (base.custom_formats or [ ]) ++ freeleechScores;
      custom_formats_radarr = (base.custom_formats_radarr or [ ]) ++ freeleechScores;
      custom_formats_sonarr = (base.custom_formats_sonarr or [ ]) ++ freeleechScores;
    };

  # Standard profiles that do not exist in the Dictionarry Database.
  standardQualityProfiles = {
    "Any" = {
      upgradesAllowed = true;
      language = "any";
      qualities = [
        {
          id = -1;
          name = "Any";
          qualities = [
            { name = "Bluray-2160p"; }
            { name = "WEBDL-2160p"; }
            { name = "Bluray-1080p"; }
            { name = "WEBDL-1080p"; }
            { name = "Bluray-720p"; }
            { name = "WEBDL-720p"; }
            { name = "Bluray-480p"; }
            { name = "WEBDL-480p"; }
            { name = "DVD"; }
            { name = "SDTV"; }
          ];
        }
      ];
      custom_formats = freeleechScores;
    };
    "HD-1080p" = {
      upgradesAllowed = true;
      upgrade_until = {
        id = -1;
        name = "1080p";
      };
      language = "any";
      qualities = [
        {
          id = -1;
          name = "1080p";
          qualities = [
            { name = "Bluray-1080p"; }
            { name = "WEBDL-1080p"; }
          ];
        }
        {
          id = -2;
          name = "720p";
          qualities = [
            { name = "Bluray-720p"; }
            { name = "WEBDL-720p"; }
          ];
        }
        {
          id = -3;
          name = "SD";
          qualities = [
            { name = "Bluray-480p"; }
            { name = "WEBDL-480p"; }
            { name = "DVD"; }
            { name = "SDTV"; }
          ];
        }
      ];
      custom_formats = freeleechScores;
    };
  };

  # Freeleech custom-format definitions (not present in the Dictionarry
  # Database).  These are detected via indexer flags returned by
  # Prowlarr/Jackett, not by regex on the release title.
  freeleechCustomFormats = {
    "Freeleech" = {
      description = "Matches releases with 100% Freeleech";
      tags = [ "Freeleech" ];
      conditions = [
        {
          type = "indexer_flag";
          flag = "freeleech";
          name = "Freeleech";
          negate = false;
          required = true;
        }
      ];
    };
    "Freeleech75" = {
      description = "Matches releases with 75% Freeleech";
      tags = [ "Freeleech" ];
      conditions = [
        {
          type = "indexer_flag";
          flag = "freeleech75";
          name = "Freeleech75";
          negate = false;
          required = true;
        }
      ];
    };
    "Freeleech50" = {
      description = "Matches releases with 50% Freeleech";
      tags = [ "Freeleech" ];
      conditions = [
        {
          type = "indexer_flag";
          flag = "halfleech";
          name = "Freeleech50";
          negate = false;
          required = true;
        }
      ];
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

      rootFolder = [ "/media/tv" ];

      qualityProfile = standardQualityProfiles // {
        "1080p Balanced" = mkProfile profile1080pBalanced;
        "1080p Quality" = mkProfile profile1080pQuality;
        "2160p Quality" = mkProfile profile2160pQuality;
        "720p Quality" = mkProfile profile720pQuality;
      };

      customFormat = freeleechCustomFormats;
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

      rootFolder = [ "/media/movies" ];

      qualityProfile = standardQualityProfiles // {
        "1080p Quality" = mkProfile profile1080pQuality;
        "2160p Quality" = mkProfile profile2160pQuality;
        "720p Quality" = mkProfile profile720pQuality;
      };

      customFormat = freeleechCustomFormats;
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
          enableRss = false;
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
            formatDbRepo = "https://github.com/Dictionarry-Hub/Database";
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

      after =
        optionals cfg.sonarr.enable [ "sonarr.service" ]
        ++ optionals cfg.radarr.enable [ "radarr.service" ]
        ++ optionals cfg.lidarr.enable [ "lidarr.service" ]
        ++ optionals cfg.prowlarr.enable [ "prowlarr.service" ]
        ++ optionals cfg.deluge.enable [ "deluged.service" ];
      wants = [ "network.target" ];
      unitConfig = {
        StartLimitBurst = 10;
      };
      serviceConfig = {
        RestartSec = "1s";
      };
    };
  };
}
