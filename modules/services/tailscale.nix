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

      # *arr path-based routing
      handle /prowlarr* { reverse_proxy http://127.0.0.1:9696 }
      handle /sonarr*   { reverse_proxy http://127.0.0.1:8989 }
      handle /radarr*   { reverse_proxy http://127.0.0.1:7878 }
      handle /lidarr*   { reverse_proxy http://127.0.0.1:8686 }
      handle /bazarr*   { reverse_proxy http://127.0.0.1:6767 }

      # Seerr — strip /seerr prefix so it thinks it runs at root
      handle_path /seerr* { reverse_proxy http://127.0.0.1:5055 }

      # Seerr root-relative Next.js static assets and API
      handle /_next/*  { reverse_proxy http://127.0.0.1:5055 }
      handle /api/v1/* { reverse_proxy http://127.0.0.1:5055 }

      # Bazarr root-relative static assets (Vue.js app)
      handle /static/* { reverse_proxy http://127.0.0.1:6767 }

      # Catch-all — everything else (including root /) goes to Seerr
      # This makes refresh/deep-link work for Seerr SPA routes like /requests, /login
      handle { reverse_proxy http://127.0.0.1:5055 }
    '';

    # Gotify is served on a dedicated Tailscale HTTPS port because it
    # must run at root path. We reverse-proxy it through Caddy (which
    # adds X-Forwarded-Proto, Host, and WebSocket headers) to prevent
    # blank-page issues caused by mixed-content when tailscale serve
    # proxies HTTPS→HTTP directly.
    virtualHosts.":16789".extraConfig = ''
      bind 127.0.0.1
      reverse_proxy http://127.0.0.1:6789
    '';

    # Beszel is served on a dedicated Tailscale HTTPS port because it
    # must run at root path (PocketBase uses root-relative URLs).
    virtualHosts.":28090".extraConfig = ''
      bind 127.0.0.1
      reverse_proxy http://127.0.0.1:8090
    '';

    # Profilarr is served on a dedicated Tailscale HTTPS port because it
    # must run at root path (Vue/React apps use root-relative URLs).
    virtualHosts.":16868".extraConfig = ''
      bind 127.0.0.1
      reverse_proxy http://127.0.0.1:6868
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

      # Wait for Caddy to be listening (don't require upstreams to be healthy yet)
      for i in $(seq 1 30); do
        if ${pkgs.curl}/bin/curl -s --connect-timeout 1 http://127.0.0.1:8080 >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done

      # Clear any existing serve config, then serve root to local Caddy
      tailscale serve reset
      tailscale serve --bg http://127.0.0.1:8080
      # Gotify, Beszel, and Profilarr don't support subpath proxying (root-relative URLs in UI).
      # Serve them on dedicated Tailscale HTTPS ports, proxied through Caddy so
      # X-Forwarded-Proto and other reverse-proxy headers are set correctly.
      tailscale serve --bg --https 6789  http://127.0.0.1:16789
      tailscale serve --bg --https 28090 http://127.0.0.1:28090
      tailscale serve --bg --https 6868  http://127.0.0.1:16868
    '';
  };

  environment.systemPackages = [ pkgs.tailscale ];
}
