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
    };
  };

  services.caddy = {
    enable = true;
    virtualHosts.":8080".extraConfig = ''
      bind 127.0.0.1
      reverse_proxy /prowlarr* http://127.0.0.1:9696
      reverse_proxy /sonarr* http://127.0.0.1:8989
      reverse_proxy /radarr* http://127.0.0.1:7878
      reverse_proxy /lidarr* http://127.0.0.1:8686
    '';
  };

  systemd.services.tailscale-serve-paths = {
    description = "Configure Tailscale Serve path-based routing for *arr apps";
    after = [
      "tailscaled.service"
      "caddy.service"
    ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.tailscale ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "3s";
      TimeoutStartSec = "60s";
    };
    script = ''
      # Wait for tailscale to be authenticated
      for i in $(seq 1 30); do
        if tailscale status --peers=false 2>/dev/null; then
          break
        fi
        sleep 1
      done

      # Clear any existing serve config, then serve root to local Caddy
      tailscale serve reset
      tailscale serve --bg http://127.0.0.1:8080
    '';
  };

  environment.systemPackages = [ pkgs.tailscale ];
}
