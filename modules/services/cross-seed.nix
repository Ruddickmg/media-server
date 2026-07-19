{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.cross-seed;
  apiKeys = config.media-server.apiKeys;

  # Prowlarr assigns indexers sequential numeric IDs: /1/api, /2/api, etc.
  # List up to 10 — unused IDs 404 gracefully.
  torznabUrls = builtins.genList (
    i: "http://127.0.0.1:9696/prowlarr/${toString (i + 1)}/api?apikey=${apiKeys.prowlarr}"
  ) 10;

in
{
  options.media-server.cross-seed = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable cross-seed automatic cross-seeding";
    };
    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/cross-seed";
      description = "Data directory for cross-seed";
    };
  };

  config = mkIf cfg.enable {
    services.cross-seed = {
      enable = true;
      configDir = cfg.dataDir;
      settings = {
        dataDirs = [
          "/media/downloads/completed"
        ];
        linkDirs = [
          "/media/downloads/completed"
        ];
        torrentDir = "/var/lib/deluge/.config/deluge/state";
        port = 2468;
        host = "127.0.0.1";
        apiAuth = true;
        action = "inject";
        torznab = torznabUrls;
        sonarr = "http://127.0.0.1:8989/sonarr?apikey=${apiKeys.sonarr}";
        radarr = "http://127.0.0.1:7878/radarr?apikey=${apiKeys.radarr}";
        linkType = "hardlink";
        duplicateCategories = true;
        matchMode = "safe";
        searchCadence = 60;
        rssCadence = 10;
        torrentClients = [
          {
            client = "deluge";
            host = "127.0.0.1";
            port = 8112;
            username = "localclient";
            password = "deluge";
            label = "cross-seed";
          }
        ];
      };
    };

    systemd.services.cross-seed = {
      wants = [
        "deluged.service"
        "prowlarr.service"
      ];
      after = [
        "deluged.service"
        "prowlarr.service"
      ];
      # --base-path tells the SPA where it's mounted; Caddy strips the prefix before proxying
      serviceConfig.ExecStart = lib.mkForce
        "${pkgs.cross-seed}/bin/cross-seed daemon --config ${cfg.dataDir} --base-path /cross-seed";
      serviceConfig = {
        SupplementaryGroups = [ "media" ];
        ReadWritePaths = [
          "/media/downloads/completed"
        ];
      };
    };

  };
}
