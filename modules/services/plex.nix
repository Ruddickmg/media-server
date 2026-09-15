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
    # - ProtectSystem=true (set by the nixpkgs module) does not protect /media;
    #   ReadOnlyPaths=/media pins Plex's writable surface to its own data dir
    #   plus the two Plex library roots, keeping downloads/xseeds/music
    #   read-only to the Plex process (the media-group ACLs would otherwise let
    #   it modify the whole tree).
    systemd.services.plex = {
      # Plex has no NixOS option for its own preferences. PMS persists them as
      # attributes on Preferences.xml and rewrites that file on shutdown, so the
      # keys are re-enforced on every boot. preStart (no "+" prefix) runs as
      # plex:media, so the file stays owned by Plex. "Allow media deletion" is
      # what makes Plex unlink media on the UI; autoEmptyTrash drops the deleted
      # item from the library on the next scan. ("Move deleted media to Trash"
      # is a no-op on Linux — PMS has no OS-trash integration and unlinks files
      # directly — so it needs no key.)
      path = [ pkgs.xmlstarlet ];
      preStart = ''
        prefs="/var/lib/plex/Plex Media Server/Preferences.xml"
        # Best effort only — if the data dir isn't there yet (fresh install),
        # PMS creates it and its own Preferences.xml on first start; never
        # fail the unit over these prefs.
        [ -d "$(dirname -- "$prefs")" ] || mkdir -p "$(dirname -- "$prefs")" 2>/dev/null || exit 0
        [ -f "$prefs" ] || printf '<Preferences/>\n' > "$prefs" 2>/dev/null || exit 0
        # both keys take the value 1; xmlstarlet can only insert or update, not
        # "set if absent", so probe whether each attribute exists first.
        for k in allowMediaDeletion autoEmptyTrash; do
          cur=$(xmlstarlet sel -t -v "string(/Preferences/@$k)" "$prefs" 2>/dev/null) || cur=
          [ "$cur" = 1 ] && continue
          if [ -n "$cur" ]; then
            xmlstarlet ed -L -u "/Preferences/@$k" -v 1 "$prefs" || true
          else
            xmlstarlet ed -L -s /Preferences -t attr -n "$k" -v 1 "$prefs" || true
          fi
        done
      '';
      serviceConfig = {
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
        # /media is read-only to Plex except the two Plex-managed library roots
        # (delete-media-watch, sonarr/radarr/etc. keep their own access).
        ReadOnlyPaths = [
          "/media"
        ];
        ReadWritePaths = [
          "/var/lib/plex"
          "/media/movies"
          "/media/tv"
        ];
      };
    };
  };
}
