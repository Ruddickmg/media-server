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
                  # choosing which files to evict.
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
    };
  };
}
