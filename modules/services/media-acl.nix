{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.media-acl;
in
{
  options.media-server.media-acl = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Grant media-group write ACLs on the Plex library roots";
    };
  };

  config = mkIf cfg.enable {
    # Why ACLs at all: the *arr apps create subdirectories under the 2775
    # root:media roots with the default umask 022, i.e. mode 755 — group media
    # (and Plex, whose primary group is media) cannot unlink anything inside
    # them, so deleting from the Plex UI would fail and the delete-media-watch
    # trigger would never fire. ACLs are the declarative-ish fix: they cannot
    # be expressed as a NixOS option, so this is the allowed script carve-out.
    # Grants are limited to the Plex-writable library roots; /media/downloads
    # and /media/xseeds stay untouched, matching the ReadOnlyPaths restriction
    # on the Plex service. Existing dirs are fixed in place, future ones inherit
    # the default ACL automatically (POSIX propagates it through new dirs).
    systemd.services.media-acl = {
      description = "Ensure media-group ACLs on Plex library roots";
      requiresMountsFor = [
        "/media/movies"
        "/media/tv"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.acl ];

      script = ''
        for root in /media/movies /media/tv; do
          [ -d "$root" ] || continue
          # dirs: group read+write+execute (execute = pass into / delete entries)
          find "$root" -type d -exec setfacl -m g:media:rwx -m m::rwx -- {} + 2>/dev/null
          # future files/dirs inherit these defaults
          setfacl -d -m g:media:rwx -m m::rwx -- "$root" 2>/dev/null
        done
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}