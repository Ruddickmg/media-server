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
      # The API key is injected via the environment file below. (nixpkgs
      # removed services.radarr.apiKeyFile.)
      environmentFiles = [
        (pkgs.writeText "radarr-env" ''
          RADARR__CONFIG__HOST__APIKEY=${config.media-server.apiKeys.radarr}
        '')
      ];
    };

    systemd.services.radarr = {
      # The union must be mounted before imports touch the library/torrents.
      unitConfig.RequiresMountsFor = [
        "/media/data/torrents/complete"
        "/media/data/library/movies"
      ];
      serviceConfig = {
        # Keep *arr-created dirs/files group-writable for media (nixpkgs sets
        # 0022, which would break Plex/delete-media-watch unlinks).
        UMask = lib.mkForce "0002";
        PrivateTmp = true;
        NoNewPrivileges = true;
        LockPersonality = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        RemoveIPC = true;
        ReadWritePaths = [
          "/var/lib/radarr"
          "/media/data/torrents/complete"
          "/media/data/library/movies"
        ];
        KeyringMode = "private";
        RestrictSUIDSGID = true;
      };
    };
  };
}
