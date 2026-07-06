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

  systemd.services.tailscaled = {
    wants = [
      "network-online.target"
      "systemd-resolved.service"
    ];
    after = [
      "network-online.target"
      "systemd-resolved.service"
    ];
    serviceConfig = {
      Environment = lib.mkAfter [
        "TS_DEBUG_FIREWALL_MODE=nftables"
      ];
      ExecStartPost = [
        "-${pkgs.tailscale}/bin/tailscale serve --set-path /prowlarr http://127.0.0.1:9696"
        "-${pkgs.tailscale}/bin/tailscale serve --set-path /sonarr http://127.0.0.1:8989"
        "-${pkgs.tailscale}/bin/tailscale serve --set-path /radarr http://127.0.0.1:7878"
        "-${pkgs.tailscale}/bin/tailscale serve --set-path /lidarr http://127.0.0.1:8686"
      ];
    };
  };

  environment.systemPackages = [ pkgs.tailscale ];
}
