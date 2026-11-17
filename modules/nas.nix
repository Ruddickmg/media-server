{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.media-server.nas;
  storage = config.media-server.storage;
  inherit (lib) mkEnableOption mkIf mkOption types;

  nologin = "${pkgs.shadow}/bin/nologin";

  nasRoot = "${storage.unifiedPath}/data/nas";
  publicSource = "${nasRoot}/public";
  privateSource = "${nasRoot}/private";

  hddMounts = map (d: d.mountPoint) (lib.attrValues storage.hddDisks);

  # Create the NAS skeleton on the raw branch, never through the union: if a
  # pool fails to mount, services must not fall back to the root filesystem's
  # /media directory. public and private are siblings, so the public share
  # cannot traverse into the private tree.
  mkNasDirs =
    root:
    map (line: "d ${root}/${line}") [
      "data/nas 2770 root nas"
      "data/nas/public 2770 root nas"
      "data/nas/private 2770 root nas-private"
    ];

  mkMount =
    what: where:
    {
      inherit what where;
      type = "none";
      options = "bind";
      wantedBy = [ "multi-user.target" ];
      # Mount only after tmpfiles has created the bind source. A plain
      # local-fs mount (the default for fstab entries) would be ordered before
      # tmpfiles and fail on first boot, so this unit opts out of the default
      # dependencies and is pulled in by multi-user.target instead.
      after = [ "systemd-tmpfiles-setup.service" ];
      before = [
        "multi-user.target"
        "umount.target"
      ];
      conflicts = [ "umount.target" ];
      unitConfig = {
        DefaultDependencies = false;
        # Pull /media (and transitively the SSD/HDD branches) in first.
        RequiresMountsFor = [ storage.unifiedPath ];
      };
    };
in
{
  options.media-server.nas = {
    enable = mkEnableOption "SMB NAS shares backed by the tiered storage";

    privateUsers = mkOption {
      type = types.attrsOf (
        types.submodule {
          options.uid = mkOption {
            # Matches the range NixOS allocates to normal users (1000-29999),
            # and satisfies isNormalUser's uid >= 1000 rule.
            type = types.ints.between 1000 29999;
            description = "Pinned Unix UID for this SMB-only user.";
          };
        }
      );
      default = { };
      example = {
        moon.uid = 3001;
      };
      description = ''
        SMB-only private users. Each gets a Unix account with no login shell and
        no home directory, membership in the media, nas, and nas-private groups,
        and read/write access to the private share. Pin the UID explicitly so
        adding another user never renumbers existing files.
      '';
    };

    publicMount = mkOption {
      type = types.str;
      default = "/nas";
      description = "Top-level bind mount exposing the public NAS tree.";
    };

    privateMount = mkOption {
      type = types.str;
      default = "/nas-private";
      description = "Top-level bind mount exposing the private NAS tree.";
    };

    openFirewall = mkEnableOption "opening SMB ports 139/445 on the LAN (the tailnet is always allowed)";
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = storage.enable;
        message = "media-server.nas.enable requires media-server.storage.enable.";
      }
      {
        # The private users are merged into users.users next to nas-guest, so a
        # private user with that name would silently replace the guest account.
        assertion = !(cfg.privateUsers ? nas-guest);
        message = "media-server.nas.privateUsers cannot define \"nas-guest\": that name is reserved for the internal Samba guest account.";
      }
    ];

    # Three groups keep the permission model explicit: media reaches the media
    # tree only, nas reaches the public NAS tree, and nas-private reaches the
    # private NAS tree. No group grants access to another group's tree.
    #
    # The gids are pinned, like media's, so adding users or groups can never
    # renumber them and strand files on a stale numeric group. High values keep
    # them clear of the automatically allocated system group range.
    users.groups = {
      nas = {
        gid = 3991;
      };
      nas-private = {
        gid = 3992;
      };
    };

    users.users =
      {
        # Internal Samba guest identity. media lets it read the read-only
        # library share; nas lets it read/write the public share. It is
        # deliberately not in nas-private, so unknown/guest users cannot reach
        # the private tree.
        nas-guest = {
          isSystemUser = true;
          uid = 3002;
          group = "nas";
          extraGroups = [ "media" ];
          shell = nologin;
          createHome = false;
        };
      }
      # SMB-only private users. No SSH key and no login shell: SSH stays with
      # the existing media-server account, exactly as before.
      // lib.mapAttrs (_: user: {
        isNormalUser = true;
        uid = user.uid;
        group = "nas";
        extraGroups = [
          "media"
          "nas-private"
        ];
        shell = nologin;
        createHome = false;
      }) cfg.privateUsers;

    systemd.tmpfiles.rules =
      mkNasDirs storage.ssdPath
      ++ lib.concatMap mkNasDirs hddMounts;

    # /nas and /nas-private are real top-level mounts, separate from /media.
    # They bind the union paths so NAS data keeps following the tier mover and
    # SnapRAID. The private tree never appears below the public mount.
    systemd.mounts = [
      (mkMount publicSource cfg.publicMount)
      (mkMount privateSource cfg.privateMount)
    ];

    services.samba = {
      enable = true;
      openFirewall = cfg.openFirewall;
      # Standalone SMB only: no NetBIOS browsing and no domain services.
      nmbd.enable = false;
      winbindd.enable = false;

      settings = {
        global = {
          "workgroup" = "WORKGROUP";
          "server string" = "media-server NAS";
          "server role" = "standalone server";
          "security" = "user";
          "map to guest" = "Bad User";
          "guest account" = "nas-guest";
          # Hide shares a user cannot access (notably `private` from guests).
          "access based share enum" = "yes";
          "server min protocol" = "SMB2";
          "load printers" = "no";
          "printing" = "bsd";
          "printcap name" = "/dev/null";
          "disable spoolss" = "yes";
          "invalid users" = [ "root" ];
          # Refuse symlinks that escape a share into /nas-private or /media.
          "wide links" = "no";
          "unix extensions" = "no";
        };

        public = {
          comment = "Public NAS";
          path = cfg.publicMount;
          browseable = "yes";
          "guest ok" = "yes";
          "read only" = "no";
          "create mask" = "0660";
          "directory mask" = "2770";
          "force group" = "nas";
        };

        private = {
          comment = "Private NAS";
          path = cfg.privateMount;
          # Guests cannot see or reach this share; only @nas-private can.
          browseable = "no";
          "guest ok" = "no";
          "read only" = "no";
          "valid users" = "@nas-private";
          "create mask" = "0660";
          "directory mask" = "2770";
          "force group" = "nas-private";
        };

        library = {
          comment = "Media library (read-only)";
          path = "${storage.unifiedPath}/data/library";
          browseable = "yes";
          "guest ok" = "yes";
          # Read-only for everyone over SMB, private users included.
          "read only" = "yes";
          "force group" = "media";
        };
      };
    };

    # Never serve an empty root-filesystem fallback if a NAS mount failed.
    # Merged with the existing RequiresMountsFor = "/var/lib/samba".
    systemd.services.samba-smbd.unitConfig.RequiresMountsFor = [
      cfg.publicMount
      cfg.privateMount
    ];
  };
}
