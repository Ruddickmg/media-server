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

  # Deluge Execute plugin script: triggers cross-seed search when a torrent
  # finishes downloading. Add in Deluge via Edit -> Preferences -> Plugins ->
  # Execute -> Add: Event = "Torrent Complete", Command = "cross-seed-on-complete".
  # The auto-generated API key is retrieved at runtime from the cross-seed data
  # directory. Run `cross-seed api-key` (with CONFIG_DIR set) to view it.
  onCompleteScript = pkgs.writeShellScriptBin "cross-seed-on-complete" ''
    # Arguments from Deluge Execute plugin: $1 = infoHash, $2 = name, $3 = path
    CONFIG_DIR="${cfg.dataDir}"
    API_KEY=$(cat "$CONFIG_DIR/apiKey" 2>/dev/null)
    if [ -n "$API_KEY" ] && [ -n "$1" ]; then
      curl -sf -XPOST \
        "http://127.0.0.1:2468/api/webhook?apikey=$API_KEY&infoHash=$1&includeSingleEpisodes=true" \
        >/dev/null 2>&1
    fi
  '';

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

  # Integration notes (post-deploy manual steps):
  #
  # 1. Deluge on-completion webhook:
  #    The cross-seed-on-complete script is installed system-wide. In Deluge,
  #    enable the Execute plugin (Edit -> Preferences -> Plugins -> Execute),
  #    add a command: Event = "Torrent Complete", Command = "cross-seed-on-complete".
  #    This triggers a cross-seed search every time a torrent finishes downloading.
  #
  # 2. autobrr announce webhook:
  #    In autobrr (Settings -> Filters), create a high-priority filter with:
  #    - Indexers: all
  #    - External tab: Type = Webhook, Host = http://127.0.0.1:2468/api/announce
  #    - Headers: x-api-key=<cross-seed API key>
  #    - Data (v6 format):
  #      {"name":{{ toRawJson .TorrentName }},"guid":"{{ .TorrentUrl }}","link":"{{ .TorrentUrl }}","tracker":{{ toRawJson .IndexerName }}}
  #    - Retry: status 202, max 100 retries, 900s delay
  #
  # 3. API key retrieval:
  #    Run: sudo -u cross-seed CONFIG_DIR=/var/lib/cross-seed cross-seed api-key
  #    Or read: cat /var/lib/cross-seed/apiKey

  config = mkIf cfg.enable {
    services.cross-seed = {
      enable = true;
      configDir = cfg.dataDir;
      settings = {
        dataDirs = [
          "/media/downloads/completed"
        ];
        linkDirs = [
          "/media/downloads/xseeds"
        ];
        outputDir = null;
        port = 2468;
        host = "127.0.0.1";
        action = "inject";
        useClientTorrents = true;
        torznab = torznabUrls;
        sonarr = [ "http://127.0.0.1:8989/sonarr?apikey=${apiKeys.sonarr}" ];
        radarr = [ "http://127.0.0.1:7878/radarr?apikey=${apiKeys.radarr}" ];
        linkType = "hardlink";
        duplicateCategories = true;
        matchMode = "safe";
        rssCadence = "10 minutes";
        searchCadence = "1 day";
        excludeOlder = "2 weeks";
        excludeRecentSearch = "3 days";
        skipRecheck = false;
        autoResumeMaxDownload = 0;
        includeSingleEpisodes = false;
        ignoreNonRelevantFilesToResume = true;
        torrentClients = [
          "deluge:http://localclient:deluge@127.0.0.1:8112/json"
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
      serviceConfig = {
        SupplementaryGroups = [
          "media"
        ];
      };
    };

    # Make the on-completion script available for the Deluge Execute plugin.
    environment.systemPackages = [ onCompleteScript ];

  };
}
