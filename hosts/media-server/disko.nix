let
  # Kept in a separate file because this module is also evaluated standalone by
  # the disko installer.
  paths = import ./storage-paths.nix;
in
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        # TODO: set to the target disk before running disko (lsblk).
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = {
              size = "8G";
              content = {
                type = "swap";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ];
                subvolumes = {
                  "@" = {
                    mountpoint = "/";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  "@state" = {
                    mountpoint = "/var/lib";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  "@log" = {
                    mountpoint = "/var/log";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  # The SSD is the fast tier, not the union mountpoint. relatime
                  # (not noatime) gives the media-tier mover an LRU signal for
                  # choosing which files to evict. SMB reads through /nas and
                  # /media must advance atime for that signal to work.
                  # atime <= mtime is treated as no read since the last write.
                  # This subvolume is removed after the 4TB data-disk cutover.
                  "@media" = {
                    mountpoint = paths.ssd;
                    mountOptions = [ "relatime" ];
                  };
                };
              };
            };
          };
        };
      };

      # New 4TB data disk. It is mounted at a temporary path during migration so
      # the old @media subvolume can keep serving /mnt/ssd. After the rsync
      # cutover, change mountpoint to paths.ssd and delete @media from the main
      # disk. ext4 is enough here: one filesystem, no subvolume management, and
      # full hardlink/xattr/ACL support for the media hardlink topology.
      data = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-TEAM_TM8FPW004T_TM702510160250200214";
        content = {
          type = "gpt";
          partitions = {
            data = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = paths.ssdNew;
                # relatime keeps the mover's atime-based LRU signal. nofail lets
                # the host boot if this disk is not installed yet.
                mountOptions = [
                  "relatime"
                  "nofail"
                  "x-systemd.device-timeout=30s"
                ];
              };
            };
          };
        };
      };
    };
  };
}
