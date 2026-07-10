{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.plex;
in
{
  options.media-server.plex = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Plex Media Server";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open ports in firewall for Plex (remote access via Plex auth)";
    };
  };

  config = mkIf cfg.enable {
    services.plex = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
    };

    # Hardware acceleration notes:
    # - /dev/dri (Intel QuickSync / VAAPI) is accessible because PrivateDevices
    #   is NOT set.  Do not add PrivateDevices or CapabilityBoundingSet or it
    #   will break GPU transcoding.
    # - ProtectSystem is intentionally omitted — Plex writes metadata to
    #   /var/lib/plex and reads media from /media/*.  ReadWritePaths documents
    #   the expected paths for when/if ProtectSystem is added later.
    systemd.services.plex.serviceConfig = {
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      SystemCallArchitectures = "native";
      LockPersonality = true;
      ProtectClock = true;
      PrivateMounts = true;
      RemoveIPC = true;
      KeyringMode = "private";
      RestrictSUIDSGID = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      ReadWritePaths = [
        "/var/lib/plex"
      ];
    };
  };
}
