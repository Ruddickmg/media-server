{ ... }: {
  boot.initrd.availableKernelModules = [
    "ahci"
    "nvme"
    "usb_storage"
    "sd_mod"
    "sr_mod"
    "xhci_pci"
    "ehci_pci"
  ];
}
