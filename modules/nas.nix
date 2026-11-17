{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.media-server.nas;
  storage = config.media-server.storage;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  nologin = "${pkgs.shadow}/bin/nologin";

  nasRoot = "${storage.unifiedPath}/data/nas";
  publicSource = "${nasRoot}/public";
  privateSource = "${nasRoot}/private";

  hddMounts = map (d: d.mountPoint) (lib.attrValues storage.hddDisks);

  # Shared by both smbd instances. The private listener gets its own config
  # file so port 445 cannot expose the private share at all.
  commonSambaGlobal = {
    "workgroup" = "WORKGROUP";
    "server string" = "media-server NAS";
    "server role" = "standalone server";
    "security" = "user";
    "map to guest" = "Bad User";
    "guest account" = "nas-guest";
    # Hide shares a user cannot access. The private share is additionally
    # browseable = no in its own listener.
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

  privateSambaFormat = pkgs.formats.ini {
    listToValue = lib.concatMapStringsSep " " (lib.generators.mkValueStringDefault { });
  };

  privateSambaConfig = privateSambaFormat.generate "smb-private.conf" {
    global = commonSambaGlobal // {
      "log file" = "/var/log/samba/log.smbd-private";
      # smbd creates its own PID file in this directory; it must not collide
      # with the public daemon's /run/samba/smbd.pid.
      "pid directory" = "/run/samba-private";
    };
    private = {
      comment = "Private NAS";
      path = cfg.privateMount;
      # Not advertised, and served only on the restricted port.
      browseable = "no";
      "guest ok" = "yes";
      "read only" = "no";
      "create mask" = "0660";
      "directory mask" = "2770";
      "force user" = cfg.privateShareUser;
      "force group" = "nas-private";
    };
  };

  # Create the NAS skeleton on the raw branch, never through the union: if a
  # pool fails to mount, services must not fall back to the root filesystem's
  # /media directory. public and private are siblings, so the public share
  # cannot traverse into the private tree.
  #
  # data/nas is traverse-only: group nas can reach public, and the "other"
  # execute bit lets Samba's forced nas-private group reach private on the
  # branch side (mergerfs switches to the request's primary gid; supplementary
  # groups do not cross). It is not writable and not listable, so neither the
  # guest identity nor media-group services can rename or delete either share.
  # z rules re-assert the mode on existing installs because d only creates.
  mkNasDirs =
    root:
    map (line: "d ${root}/${line}") [
      "data/nas 0711 root nas"
      "data/nas/public 2770 root nas"
      "data/nas/private 2770 root nas-private"
    ];
  fixNasDirMode = root: "z ${root}/data/nas 0711 root nas";

  mkMount = what: where: {
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
            description = "Pinned Unix UID for this SMB-only identity.";
          };
        }
      );
      default = { };
      example = {
        moon.uid = 3001;
      };
      description = ''
        Unix identities used by the private share. Each gets an account with no
        login shell and no home directory, membership in the media, nas, and
        nas-private groups, and no password. Pin the UID explicitly so adding
        another identity never renumbers existing files.
      '';
    };

    privateShareUser = mkOption {
      type = types.str;
      default = "moon";
      description = ''
        Unix identity that all guest connections to the private share are forced
        to use. Tailscale ACLs, not SMB passwords, decide who may reach the share.
      '';
    };

    privatePort = mkOption {
      type = types.ints.between 1 65535;
      default = 1445;
      description = ''
        TCP port for the separate smbd instance that serves only the private
        share. The public and library shares stay on the standard port 445 so
        Tailscale ACLs can grant them separately.
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
      {
        assertion = builtins.hasAttr cfg.privateShareUser cfg.privateUsers;
        message = "media-server.nas.privateShareUser must exist in media-server.nas.privateUsers.";
      }
      {
        assertion = cfg.privatePort != 445;
        message = "media-server.nas.privatePort must differ from 445 so public and private SMB access can be gated separately.";
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

    users.users = {
      # Internal Samba guest identity. media lets it read the read-only
      # library share; nas lets it read/write the public share. It is
      # deliberately not in nas-private: private-share guests reach the tree
      # only through the forced privateShareUser below.
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
      ++ lib.concatMap mkNasDirs hddMounts
      ++ map fixNasDirMode ([ storage.ssdPath ] ++ hddMounts);

    # /nas and /nas-private are real top-level mounts, separate from /media.
    # They bind the union paths so NAS data keeps following the tier mover and
    # SnapRAID. The private tree never appears below the public mount.
    systemd.mounts = [
      (mkMount publicSource cfg.publicMount)
      (mkMount privateSource cfg.privateMount)
    ];

    # openFirewall defaults to false. tailscale0 is a trusted interface in
    # modules/services/tailscale.nix, so both SMB listeners are reachable over
    # the tailnet without opening LAN ports. Tailscale ACLs gate public (445)
    # and private (privatePort) separately.
    services.samba = {
      enable = true;
      openFirewall = cfg.openFirewall;
      # Standalone SMB only: no NetBIOS browsing and no domain services.
      nmbd.enable = false;
      winbindd.enable = false;

      settings = {
        global = commonSambaGlobal;

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

        library = {
          comment = "Media library (read-only)";
          path = "${storage.unifiedPath}/data/library";
          browseable = "yes";
          "guest ok" = "yes";
          # Read-only for everyone over SMB.
          "read only" = "yes";
          "force group" = "media";
        };
      };
    };

    # The private share is served by a second smbd process with its own config,
    # so a client allowed only to port 445 cannot mount it. Type=notify matches
    # the upstream smbd unit; the PID file is distinct from the public daemon.
    environment.etc."samba/smb-private.conf".source = privateSambaConfig;

    systemd.services."samba-smbd-private" = {
      description = "Samba SMB Daemon (private share)";
      documentation = [
        "man:smbd(8)"
        "man:samba(7)"
        "man:smb.conf(5)"
      ];

      after = [
        "network.target"
        "network-online.target"
      ];

      partOf = [ "samba.target" ];
      wantedBy = [ "samba.target" ];
      wants = [ "network-online.target" ];

      environment.LD_LIBRARY_PATH = config.system.nssModules.path;

      serviceConfig = {
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        ExecStart =
          "${config.services.samba.package}/sbin/smbd "
          + (lib.escapeShellArgs [
            "--foreground"
            "--no-process-group"
            "--configfile=${privateSambaConfig}"
            "--port=${toString cfg.privatePort}"
          ]);
        LimitCORE = "infinity";
        LimitNOFILE = "16384";
        PIDFile = "/run/samba-private/smbd.pid";
        RuntimeDirectory = "samba-private";
        RuntimeDirectoryMode = "0755";
        Slice = "system-samba.slice";
        Type = "notify";
      };

      unitConfig.RequiresMountsFor = [
        "/var/lib/samba"
        cfg.privateMount
      ];

      restartTriggers = [ privateSambaConfig ];
    };

    # Never serve an empty root-filesystem fallback if a NAS mount failed.
    # Merged with the existing RequiresMountsFor = "/var/lib/samba".
    systemd.services.samba-smbd.unitConfig.RequiresMountsFor = [
      cfg.publicMount
    ];
  };
}
