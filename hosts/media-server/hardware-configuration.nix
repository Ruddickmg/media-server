{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-partlabel/disk-main-root";
    fsType = "btrfs";
  };
  fileSystems."/boot" = lib.mkForce {
    device = "/dev/disk/by-uuid/dummy-boot";
    fsType = "vfat";
  };
  fileSystems."/nix" = lib.mkForce {
    device = "/dev/disk/by-uuid/dummy-nix";
    fsType = "ext4";
  };
  fileSystems."/var/lib" = lib.mkForce {
    device = "/dev/disk/by-uuid/dummy-var";
    fsType = "ext4";
  };
  fileSystems."/media" = lib.mkForce {
    device = "/dev/disk/by-uuid/dummy-media";
    fsType = "ext4";
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
