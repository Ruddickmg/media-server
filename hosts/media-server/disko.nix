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
                };
              };
            };
          };
        };
      };

      # 4TB NVMe data disk: the sole SSD tier behind /media. ext4 keeps the
      # hardlink/xattr/ACL topology simple; relatime (not noatime) preserves the
      # mover's atime-based LRU signal. This disk is internal and required, so a
      # failed mount stops the boot instead of leaving a partially mounted stack.
      # The 30s device timeout avoids a long stall before that failure is reported.
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
                mountpoint = paths.ssd;
                mountOptions = [
                  "relatime"
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
