{
  lib,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.thunderbolt;
in
{
  options.media-server.thunderbolt = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Thunderbolt tooling and automatic device authorization.";
    };
  };

  config = mkIf cfg.enable {
    # boltctl is the CLI for inspecting Thunderbolt docks and their authorization
    # state. boltd is D-Bus activated by udev, so no extra service enable is needed.
    services.hardware.bolt.enable = true;

    # Authorize any Thunderbolt device as soon as the kernel sees it. Without
    # this, a dock can enumerate its USB hub while its DisplayPort tunnel stays
    # down, which looks like "the monitor is not picked up".
    #
    # This is deliberately permissive: any attached TB device gets DMA access.
    # IOMMU below confines that DMA; do not drop it while this rule is active.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
    '';

    # Thunderbolt DMA is only safe when the IOMMU is actually translating; on
    # 11th/12th-gen Intel hosts it is often left off by firmware.
    boot.kernelParams = [ "intel_iommu=on" ];

    # Dock firmware can fix display-link negotiation bugs. LVFS distributes
    # Sonnet/Thunderbolt dock updates through fwupd on Linux.
    services.fwupd.enable = true;
  };
}
