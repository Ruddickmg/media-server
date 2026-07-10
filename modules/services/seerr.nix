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
    isDefault = true;
    externalUrl = "https://media-server.tailbac0df.ts.net/sonarr";
    syncEnabled = true;
    enableAutomaticSearch = true;
    preventSearch = false;
    tagRequests = true;
    tags = [ ];
    overrideRule = [ ];
    seriesType = "standard";
    animeSeriesType = "standard";
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
    isDefault = true;
    externalUrl = "https://media-server.tailbac0df.ts.net/radarr";
    syncEnabled = true;
    enableAutomaticSearch = true;
    preventSearch = false;
    tagRequests = true;
    tags = [ ];
    overrideRule = [ ];
    minimumAvailability = "announced";
  };

  mkJobs = {
    "radarr-scan" = {
      schedule = "0 */5 * * * *";
    };
    "sonarr-scan" = {
      schedule = "0 */5 * * * *";
    };
    "availability-sync" = {
      schedule = "0 */5 * * * *";
    };
  };

  settingsJson = builtins.toJSON (
    {
      main = {
        applicationUrl = "https://media-server.tailbac0df.ts.net";
        mediaServerType = 4;
      };
      network = {
        trustProxy = true;
      };
      jobs = mkJobs;
    }
    // optionalAttrs sonarrEnabled {
      sonarr = [ mkSonarr ];
    }
    // optionalAttrs radarrEnabled {
      radarr = [ mkRadarr ];
    }
  );

  patchJson = builtins.toJSON (
    {
      main = {
        mediaServerType = 4;
        applicationUrl = "https://media-server.tailbac0df.ts.net";
      };
      network = {
        trustProxy = true;
      };
      jobs = mkJobs;
    }
    // optionalAttrs sonarrEnabled {
      sonarr = [ mkSonarr ];
    }
    // optionalAttrs radarrEnabled {
      radarr = [ mkRadarr ];
    }
  );

  settingsFile = pkgs.writeText "seerr-settings" settingsJson;
  patchFile = pkgs.writeText "seerr-patch" patchJson;
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
      environment.HOST = "127.0.0.1";
      serviceConfig = {
        ExecStart = mkOverride 40 (lib.getExe pkgs-unstable.seerr);
        EnvironmentFile = [
          (toString (
            pkgs.writeText "seerr-env" ''
              SEERR_API_KEY=${apiKeys.seerr}
            ''
          ))
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        CapabilityBoundingSet = [ "" ];
        PrivateDevices = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        ProtectHome = true;
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        ReadWritePaths = [
          "/var/lib/seerr"
          "/media"
        ];
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
      };
      preStart = ''
        if [ ! -f /var/lib/seerr/settings.json ]; then
          cp ${settingsFile} /var/lib/seerr/settings.json
        else
          TMPFILE="$(mktemp -p /var/lib/seerr seerr-settings.XXXXXXXXXX.json)"
          ${pkgs.jq}/bin/jq -s '.[0] * .[1]' /var/lib/seerr/settings.json ${patchFile} > "$TMPFILE" && mv "$TMPFILE" /var/lib/seerr/settings.json || rm -f "$TMPFILE"
        fi
        chmod 600 /var/lib/seerr/settings.json
        chown --reference=/var/lib/seerr /var/lib/seerr/settings.json
      '';
    };
  };
}
