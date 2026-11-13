{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.sonarr;
in
{
  options.media-server.sonarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Sonarr";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Sonarr";
    };
  };

  config = mkIf cfg.enable {
    services.sonarr = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
      settings = {
        server.bindaddress = "127.0.0.1";
        server.urlbase = "/sonarr";
      };
      # The API key is injected via the environment file below. (nixpkgs
      # removed services.sonarr.apiKeyFile.)
      environmentFiles = [
        (pkgs.writeText "sonarr-env" ''
          SONARR__CONFIG__HOST__APIKEY=${config.media-server.apiKeys.sonarr}
        '')
      ];
    };

    systemd.services.sonarr = {
      # The union must be mounted before imports touch the library/torrents.
      unitConfig.RequiresMountsFor = [
        "/media/data/torrents/complete"
        "/media/data/library/tv"
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
          "/var/lib/sonarr"
          "/media/data/torrents/complete"
          "/media/data/library/tv"
        ];
        KeyringMode = "private";
        RestrictSUIDSGID = true;
      };
    };
  };
}
