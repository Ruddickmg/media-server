{
  lib,
  pkgs,
  config,
  ...
}:
{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
  };

  networking.nftables.enable = true;

  networking.firewall = {
    trustedInterfaces = [
      "tailscale0"
      "lo"
    ];
    allowedUDPPorts = [ config.services.tailscale.port ];
  };

  systemd.services.tailscaled.serviceConfig.Environment = lib.mkAfter [
    "TS_DEBUG_FIREWALL_MODE=nftables"
  ];

  environment.systemPackages = [ pkgs.tailscale ];
}
