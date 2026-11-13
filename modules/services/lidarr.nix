{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.lidarr;
in
{
  options.media-server.lidarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Lidarr";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Lidarr";
    };
  };

  config = mkIf cfg.enable {
    services.lidarr = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
      settings = {
        server.bindaddress = "127.0.0.1";
        server.urlbase = "/lidarr";
      };
      # The API key is injected via the environment file below. (nixpkgs
      # removed services.lidarr.apiKeyFile.)
      environmentFiles = [
        (pkgs.writeText "lidarr-env" ''
          LIDARR__CONFIG__HOST__APIKEY=${config.media-server.apiKeys.lidarr}
        '')
      ];
    };

    systemd.services.lidarr = {
      # The union must be mounted before imports touch the library/torrents.
      unitConfig.RequiresMountsFor = [
        "/media/data/torrents/complete"
        "/media/data/library/music"
      ];
      serviceConfig = {
        # Keep *arr-created dirs/files group-writable for media (systemd's
        # default 0022 would break Plex/delete-media-watch unlinks).
        UMask = lib.mkForce "0002";
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
        ReadWritePaths = [
          "/var/lib/lidarr"
          "/media/data/torrents/complete"
          "/media/data/library/music"
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
