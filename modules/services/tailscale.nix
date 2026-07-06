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

  systemd.services.tailscale-serve-paths = {
    description = "Configure Tailscale Serve port-based routing for *arr apps";
    after = [ "tailscaled.service" ];
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

      tailscale serve --bg --https=9696 http://127.0.0.1:9696
      tailscale serve --bg --https=8989 http://127.0.0.1:8989
      tailscale serve --bg --https=7878 http://127.0.0.1:7878
      tailscale serve --bg --https=8686 http://127.0.0.1:8686
    '';
  };

  environment.systemPackages = [ pkgs.tailscale ];
}
