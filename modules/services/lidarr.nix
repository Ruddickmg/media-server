{
  lib,
  pkgs,
  pkgs-unstable,
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
      package = pkgs-unstable.lidarr;
      group = "media";
      openFirewall = cfg.openFirewall;
      settings = {
        server.bindaddress = "127.0.0.1";
        server.urlbase = "/lidarr";
      };
      apiKeyFile = "${pkgs.writeText "lidarr-api-key" config.media-server.apiKeys.lidarr}";
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
        # default 0022 would break Plex/Cleanuparr unlinks).
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
        # /media/data as a single entry: with ProtectSystem=strict each
        # ReadWritePaths entry becomes a separate bind mount, and link(2)
        # fails EXDEV across binds of the same filesystem. Hardlink imports go
        # torrents/complete -> library/music, so both must share one bind.
        ReadWritePaths = [
          "/var/lib/lidarr"
          "/media/data"
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
