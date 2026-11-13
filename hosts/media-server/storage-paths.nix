# Single source of truth for the storage mount points.
#
# The disko module is also evaluated standalone by the installer
# (`disko --mode disko hosts/media-server/disko.nix`), so these values cannot
# live only in the NixOS module tree. Replace the placeholders below with the
# real paths/devices from the target host before switching.
{
  # SSD cache/ingest filesystem (the btrfs @media subvolume). The old
  # mountpoint was /media; it moves here so /media can become the mergerfs
  # union every service already uses.
  ssd = "/mnt/ssd";

  # HDD-only mergerfs pool. Add future data disks to hddDisks; both this pool
  # and the unified pool derive their branches automatically.
  hddPool = "/mnt/hddpool";

  # Unified pool. Services use /media/data/... through this path.
  unified = "/media";

  # Data disks in the Sabrent JBOD enclosure. Use /dev/disk/by-id/... so the
  # device order in the enclosure does not matter.
  # TODO: replace the placeholder with the real device (ls -l /dev/disk/by-id/)
  # and add one entry per HDD (hdd2, hdd3, ...) as they are installed.
  hddDisks = {
    hdd1 = {
      mountPoint = "/mnt/hdd1";
      device = "/dev/disk/by-id/REPLACE-ME-HDD1";
    };
  };

  # TODO: when a parity disk is installed, add it here, format it ext4, and set
  # snapraid.enable = true in default.nix. Example:
  #   parity1 = { mountPoint = "/mnt/parity1"; device = "/dev/disk/by-id/..."; };
  parityDisks = { };

  # SnapRAID parity file path. Harmless while snapraid.enable = false.
  # TODO: keep this in sync with the parityDisks mountPoint above.
  parityFiles = [ "/mnt/parity1/snapraid.parity" ];
}
