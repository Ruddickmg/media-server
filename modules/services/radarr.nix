{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.radarr;
in
{
  options.media-server.radarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Radarr";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Radarr";
    };
  };

  config = mkIf cfg.enable {
    services.radarr = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
      settings = {
        server.bindaddress = "127.0.0.1";
        server.urlbase = "/radarr";
      };
      apiKeyFile = "${pkgs.writeText "radarr-api-key" config.media-server.apiKeys.radarr}";
      environmentFiles = [
        (pkgs.writeText "radarr-env" ''
          RADARR__CONFIG__HOST__APIKEY=${config.media-server.apiKeys.radarr}
        '')
      ];
    };

    systemd.services.radarr.serviceConfig = {
      PrivateTmp = true;
      NoNewPrivileges = true;
      LockPersonality = true;
      RestrictRealtime = true;
      SystemCallArchitectures = "native";
      RemoveIPC = true;
      ReadWritePaths = [
        "/var/lib/radarr"
        "/media/downloads/completed"
        "/media/movies"
      ];
      KeyringMode = "private";
      RestrictSUIDSGID = true;
    };
  };
}
