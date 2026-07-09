{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (builtins) substring hashString;
  inherit (config.networking) hostName;
  key = prefix: substring 0 32 (hashString "sha256" "${hostName}-${prefix}");
in
{
  options.media-server = {
    gotifyTokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/nixos/secrets/gotify-token";
      description = "Path to file containing Gotify app token for system notifications";
    };

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
      seerr = lib.mkOption {
        type = lib.types.str;
        default = key "seerr";
        description = "API key for Seerr";
      };
    };
  };

  config = {
    users.groups.media = { };

    systemd.services."notify-gotify@" = {
      description = "Gotify notification for failed service %i";
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        TOKEN=$(cat ${config.media-server.gotifyTokenFile} 2>/dev/null || echo "")
        [ -z "$TOKEN" ] && exit 0
        ${pkgs.curl}/bin/curl -sf -X POST "http://127.0.0.1:6789/message?token=$TOKEN" \
          -F "title=Service Failed: %i" \
          -F "message=Systemd service %i has failed on $(hostname)" \
          -F "priority=5" >/dev/null 2>&1 || true
      '';
    };

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
  };
}
