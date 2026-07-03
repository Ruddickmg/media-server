{ lib, pkgs, config, ... }:
let
  inherit (builtins) substring hashString;
  inherit (config.networking) hostName;
  key = prefix: substring 0 32 (hashString "sha256" "${hostName}-${prefix}");
in
{
  options.media-server = {
    apiKeys = {
      sonarr = lib.mkOption {
        type = lib.types.str;
        default = key "sonarr";
        description = "API key for Sonarr";
      };
      radarr = lib.mkOption {
        type = lib.types.str;
        default = key "radarr";
        description = "API key for Radarr";
      };
      lidarr = lib.mkOption {
        type = lib.types.str;
        default = key "lidarr";
        description = "API key for Lidarr";
      };
      prowlarr = lib.mkOption {
        type = lib.types.str;
        default = key "prowlarr";
        description = "API key for Prowlarr";
      };
    };
    credentials = {
      delugePassword = lib.mkOption {
        type = lib.types.str;
        default = substring 0 16 (hashString "sha256" "${hostName}-deluge");
        description = "Password for Deluge thin client authentication";
      };
    };
  };

  users.groups.media = {};

  systemd.tmpfiles.rules = [
    "d /media 2775 root media"
    "d /media/downloads 2775 root media"
    "d /media/downloads/incomplete 2775 root media"
    "d /media/downloads/completed 2775 root media"
    "d /media/movies 2775 root media"
    "d /media/tv 2775 root media"
    "d /media/music 2775 root media"
  ];

  environment.systemPackages = with pkgs; [
    unzip
    unrar
    p7zip
    git
    ripgrep
    jq
    vim
  ];
}
