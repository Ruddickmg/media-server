{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.media-server.storage;
  inherit (lib) mkIf mkOption types;

  hddDisks = lib.attrValues cfg.hddDisks;
  hddMounts = map (d: d.mountPoint) hddDisks;
  parityDisks = lib.attrValues cfg.parityDisks;

  hddPoolBranches = lib.concatStringsSep ":" hddMounts;
  unifiedBranches = lib.concatStringsSep ":" [
    cfg.ssdPath
    cfg.hddPoolPath
  ];

  # SnapRAID requires one more content file than parity files. Keep one content
  # file on the first data disk (rebuilt with the array) and one on the root
  # filesystem (a lost data disk still leaves a usable content list).
  contentFiles =
    lib.optional (hddMounts != [ ]) "${builtins.head hddMounts}/data/snapraid.content"
    ++ [ "/var/lib/snapraid/snapraid.content" ];

  # The hard-link topology: every tree that can share an inode. The mover, the
  # delete scripts, and the tmpfiles skeleton all derive from this list.
  dataDirs = [
    "data"
    "data/torrents"
    "data/torrents/incomplete"
    "data/torrents/complete"
    "data/torrents/xseeds"
    "data/library"
    "data/library/movies"
    "data/library/tv"
    "data/library/music"
  ];

  mkDataDirs = root: map (d: "d ${root}/${d} 2775 root media") dataDirs;

  # The nixpkgs snapraid module flattens parityFiles incorrectly when it builds
  # ReadWritePaths (it leaves the splitString result as nested lists), so
  # override it with a flat list whenever the array is enabled. Grant the parity
  # directory, not the parity file: the file does not exist before the first
  # sync, and a missing ReadWritePaths entry makes the unit fail to start.
  snapraidReadWritePaths = lib.unique (
    map (d: "${d.mountPoint}/data") hddDisks
    ++ map builtins.dirOf (lib.concatMap (p: lib.splitString "," p) cfg.parityFiles)
    ++ map builtins.dirOf contentFiles
  );
in
{
  options.media-server.storage = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the SSD-first tiered storage layout (mergerfs pools + nightly mover).";
    };
    ssdPath = mkOption {
      type = types.str;
      default = "/mnt/ssd";
      description = "Mount point of the SSD cache/ingest filesystem (the disko @media subvolume).";
    };
    hddPoolPath = mkOption {
      type = types.str;
      default = "/mnt/hddpool";
      description = "Mount point of the HDD-only mergerfs pool.";
    };
    unifiedPath = mkOption {
      type = types.str;
      default = "/media";
      description = "Mount point of the unified SSD+HDD mergerfs pool.";
    };
    hddDisks = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            mountPoint = mkOption { type = types.str; };
            device = mkOption { type = types.str; };
          };
        }
      );
      default = { };
      description = "Data HDDs in the JBOD enclosure, keyed by a stable name.";
    };
    parityDisks = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            mountPoint = mkOption { type = types.str; };
            device = mkOption { type = types.str; };
          };
        }
      );
      default = { };
      description = "SnapRAID parity disks.";
    };
    parityFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        SnapRAID parity file paths. May point at a disk that is not installed
        yet while `snapraid.enable` is false.
      '';
    };
    snapraid = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable SnapRAID. Requires at least one parity disk.";
      };
      syncInterval = mkOption {
        type = types.str;
        default = "04:00";
        description = "systemd OnCalendar expression for snapraid sync.";
      };
      scrubInterval = mkOption {
        type = types.str;
        default = "Sun *-*-* 05:00:00";
        description = "systemd OnCalendar expression for snapraid scrub.";
      };
      scrubPlan = mkOption {
        type = types.ints.positive;
        default = 8;
        description = "Percentage of the array to scrub per run.";
      };
      scrubOlderThan = mkOption {
        type = types.ints.positive;
        default = 10;
        description = "Only scrub blocks older than this many days.";
      };
    };
    tiering = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable the nightly SSD-to-HDD mover.";
      };
      highPercent = mkOption {
        type = types.ints.between 1 99;
        default = 85;
        description = "Start moving when the SSD is at least this full.";
      };
      lowPercent = mkOption {
        type = types.ints.between 1 99;
        default = 60;
        description = "Stop moving once the SSD is below this full.";
      };
      minFreeGiB = mkOption {
        type = types.ints.positive;
        default = 150;
        description = "Never write to an HDD with less than this much free space.";
      };
      time = mkOption {
        type = types.str;
        default = "02:00";
        description = "Time of day (HH:MM) to run the mover.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.hddDisks != { };
        message = "media-server.storage.enable requires at least one data disk in media-server.storage.hddDisks.";
      }
      {
        assertion = cfg.tiering.highPercent > cfg.tiering.lowPercent;
        message = "media-server.storage.tiering.highPercent must be greater than lowPercent.";
      }
      {
        assertion = !cfg.snapraid.enable || (cfg.parityFiles != [ ] && cfg.parityDisks != { });
        message = "media-server.storage.snapraid.enable requires parityFiles and parityDisks.";
      }
    ];

    boot.kernelModules = [ "fuse" ];
    system.fsPackages = [ pkgs.mergerfs ];

    fileSystems = lib.mkMerge (
      # Data HDDs. nofail keeps boot working when the DAS is unplugged; the 15s
      # device timeout avoids a long stall on a missing USB disk.
      map (d: {
        "${d.mountPoint}" = {
          device = d.device;
          fsType = "ext4";
          options = [
            "noatime"
            "nofail"
            "x-systemd.device-timeout=15s"
          ];
        };
      }) hddDisks
      ++ map (d: {
        "${d.mountPoint}" = {
          device = d.device;
          fsType = "ext4";
          options = [
            "noatime"
            "nofail"
            "x-systemd.device-timeout=15s"
          ];
        };
      }) parityDisks
      ++ [
        # HDD-only backing pool. category.create=mfs balances new files across
        # data disks. The mover deliberately bypasses this pool and writes to a
        # specific disk, so an inode group's hardlinks always stay on one
        # filesystem (hardlinks cannot cross disks).
        {
          "${cfg.hddPoolPath}" = {
            device = hddPoolBranches;
            fsType = "fuse.mergerfs";
            options = [
              "allow_other"
              "default_permissions"
              # mergerfs removed use_ino in 2.35; inodecalc is the replacement.
              # hybrid-hash keeps directories stable (path-hash) and hashes
              # branch+inode for files, so hard links on one branch report the
              # same st_ino while unrelated inodes on other branches do not.
              # That is what makes find -samefile work through the union.
              "inodecalc=hybrid-hash"
              "category.create=mfs"
              "minfreespace=${toString cfg.tiering.minFreeGiB}G"
              "nofail"
            ];
            depends = hddMounts;
            noCheck = true;
          };
        }
        # Unified pool. ff = first branch with enough free space, so new files
        # land on the SSD until it drops below minfreespace, then on the HDD
        # pool. moveonenospc is enabled as requested, but it can split a
        # hardlink set; the 20G reserve and the Deluge disk guard make it a
        # last resort.
        {
          "${cfg.unifiedPath}" = {
            device = unifiedBranches;
            fsType = "fuse.mergerfs";
            options = [
              "allow_other"
              "default_permissions"
              "inodecalc=hybrid-hash"
              "category.create=ff"
              "minfreespace=20G"
              "moveonenospc=true"
              "nofail"
            ];
            depends = [
              cfg.ssdPath
              cfg.hddPoolPath
            ];
            noCheck = true;
          };
        }
      ]
    );

    # Create the directory skeleton on the underlying filesystems, never through
    # the union: if a pool fails to mount, services must not fall back to the
    # root filesystem's /media directory.
    systemd.tmpfiles.rules =
      mkDataDirs cfg.ssdPath
      ++ lib.concatMap mkDataDirs hddMounts
      ++ [
        "d /var/lib/snapraid 0700 root root"
      ];

    # SnapRAID is preconfigured but disabled until a parity disk is installed.
    # dataDisks point at the raw HDD mounts, never at the mergerfs union.
    services.snapraid = {
      enable = cfg.snapraid.enable;
      dataDisks = lib.listToAttrs (
        lib.imap0 (i: d: {
          name = "d${toString (i + 1)}";
          value = "${d.mountPoint}/data";
        }) hddDisks
      );
      parityFiles = cfg.parityFiles;
      contentFiles = contentFiles;
      exclude = [
        "lost+found/"
        ".rsync-partial/"
        "*.partial"
        "snapraid.*"
        ".mergerfs*"
      ];
      sync.interval = cfg.snapraid.syncInterval;
      scrub.interval = cfg.snapraid.scrubInterval;
      scrub.plan = cfg.snapraid.scrubPlan;
      scrub.olderThan = cfg.snapraid.scrubOlderThan;
    };

    systemd.services = lib.mkIf cfg.snapraid.enable {
      snapraid-sync = {
        unitConfig = {
          # Skip the timer run when the DAS is unplugged.
          ConditionPathIsMountPoint = hddMounts ++ map (d: d.mountPoint) parityDisks;
          # Never sync while the mover is relocating files: SnapRAID would scan
          # half-moved inode groups.
          Conflicts = [ "media-tier.service" ];
        };
        serviceConfig.ReadWritePaths = lib.mkForce snapraidReadWritePaths;
      };
      snapraid-scrub = {
        unitConfig = {
          ConditionPathIsMountPoint = hddMounts ++ map (d: d.mountPoint) parityDisks;
          Conflicts = [ "media-tier.service" ];
        };
        serviceConfig.ReadWritePaths = lib.mkForce snapraidReadWritePaths;
      };
    };
  };
}
