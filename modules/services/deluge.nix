{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib)
    mkForce
    mkIf
    mkMerge
    mkOption
    types
    ;
  cfg = config.media-server.deluge;
  vpnNs = config.media-server.vpn.namespace;
  useVpn = cfg.vpnConfinement && config.media-server.vpn.enable;

  blocklistUrl = "https://github.com/colindean/transmission-blocklist/releases/latest/download/blocklist.gz";

  blocklistConfig = pkgs.writeText "blocklist.conf" (
    builtins.toJSON {
      url = blocklistUrl;
      load_on_start = true;
      check_after_days = 3;
      timeout = 600;
      try_times = 3;
      whitelisted = [ ];
    }
  );
in
{
  options.media-server.deluge = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Deluge headless daemon";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Deluge";
    };
    vpnConfinement = mkOption {
      type = types.bool;
      default = false;
      description = "Run Deluge inside the VPN network namespace";
    };
  };

  config = mkIf cfg.enable {
    services.deluge = {
      enable = true;
      declarative = true;
      web.enable = true;
      config = {
        daemon_port = 58846;
        allow_remote = true;
        enabled_plugins = [
          "Label"
          "Blocklist"
        ];
        download_location = "/media/downloads/incomplete";
        move_completed = true;
        move_completed_path = "/media/downloads/completed";
        copy_torrent_file = false;
        del_copy_torrent_file = false;
        prioritize_first_last_pieces = false;
        random_port = false;
        outgoing_ports = [
          49152
          65535
        ];

        # Service discovery — irrelevant behind VPN/Tailscale
        upnp = false;
        natpmp = false;
        lsd = false;

        # Bandwidth (capped at ~80% of 73.4/10.3 Mbps connection)
        max_download_speed = 7000.0;
        max_upload_speed = 1000.0;

        # Connections
        max_connections_global = 500;
        max_connections_per_torrent = 100;
        max_connections_per_second = 20;
        max_upload_slots_global = 20;
        max_upload_slots_per_torrent = 8;
        max_half_open_connections = 50;

        # Cache
        cache_size = 8192;
        cache_expiry = 90;

        # Queue — *arrs remove their own torrents via per-indexer goals
        max_active_limit = 100;
        max_active_downloading = 5;
        max_active_seeding = 40;

        # Seeding ceiling: stop at 3.0 ratio or 14 days, whichever first
        # *arrs will remove their torrents earlier; manual torrents hit this cap
        stop_seed_at_ratio = true;
        stop_seed_ratio = 3.0;
        seed_time_limit = 43200; # 30 days in minutes
        share_ratio_limit = 3.0;
        remove_seed_at_ratio = false;
        auto_managed = true;
      };
      authFile = pkgs.writeText "deluge-auth" ''
        localclient:deluge:10
        ruddickmg:deluge:10
      '';
      user = "deluge";
      group = "deluge";
      dataDir = "/var/lib/deluge";
    };

    users.users.deluge = {
      extraGroups = [ "media" ];
    };

    systemd.services.deluged = mkMerge [
      {
        preStart = lib.mkAfter ''
          cp ${blocklistConfig} ${config.services.deluge.dataDir}/.config/deluge/blocklist.conf
        '';
        serviceConfig = {
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          CapabilityBoundingSet = [ "" ];
          ProtectSystem = "strict";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
          PrivateDevices = true;
          LockPersonality = true;
          RestrictNamespaces = true;
          LimitNOFILE = mkForce 65536;
          ReadWritePaths = [
            "/var/lib/deluge"
            "/media/downloads"
          ];
        };
      }
      (mkIf useVpn {
        after = [ "create-netns-${vpnNs}.service" ];
        requires = [ "create-netns-${vpnNs}.service" ];
        serviceConfig = {
          NetworkNamespacePath = "/var/run/netns/${vpnNs}";
          BindReadOnlyPaths = [ "/etc/netns/${vpnNs}/resolv.conf:/etc/resolv.conf" ];
        };
      })
    ];

    systemd.sockets.proxy-deluge = mkIf useVpn {
      description = "Socket for proxy to Deluge daemon in VPN namespace";
      listenStreams = [ "58846" ];
      wantedBy = [ "sockets.target" ];
    };

    systemd.services.proxy-deluge = mkIf useVpn {
      description = "Proxy Deluge daemon from VPN namespace to root namespace";
      requires = [
        "deluged.service"
        "proxy-deluge.socket"
      ];
      after = [
        "deluged.service"
        "proxy-deluge.socket"
      ];
      serviceConfig = {
        NetworkNamespacePath = "/var/run/netns/${vpnNs}";
        BindReadOnlyPaths = [ "/etc/netns/${vpnNs}/resolv.conf:/etc/resolv.conf" ];
        User = "deluge";
        Group = "deluge";
        LimitNOFILE = mkForce 65536;
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --connections-max=4096 --exit-idle-time=5min 127.0.0.1:58846";
      };
    };

    systemd.services.deluge-natpmp = mkIf useVpn {
      description = "Configure a NAT-PMP port and configure Deluge with it";
      wantedBy = [ "multi-user.target" ];
      after = [
        "deluged.service"
        "wireguard-wg-${vpnNs}.service"
        "create-netns-${vpnNs}.service"
      ];
      requires = [
        "deluged.service"
        "wireguard-wg-${vpnNs}.service"
        "create-netns-${vpnNs}.service"
      ];
      path = with pkgs; [
        libnatpmp
        gawk
        deluge
      ];
      script = ''
        #!/usr/bin/env bash
        set -euo pipefail

        OLD_PORT=""

        while true; do
          out="$(natpmpc -a 1 0 tcp 60 -g 10.2.0.1 2>/dev/null || true)"

          port="$(awk '/Mapped public port/ {print $4; exit}' <<<"$out")"

          if [[ -n "$port" && "$port" != "$OLD_PORT" ]]; then
            echo "Got ProtonVPN forwarded port: $port – updating Deluge"
            deluge-console \
              "config --set random_port False ; \
              config --set listen_ports ($port,$port)"
            OLD_PORT="$port"
          fi

          sleep 45
        done
      '';
      serviceConfig = {
        NetworkNamespacePath = "/var/run/netns/${vpnNs}";
        BindReadOnlyPaths = [ "/etc/netns/${vpnNs}/resolv.conf:/etc/resolv.conf" ];
        User = "deluge";
        Group = "deluge";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ 58846 ];
      allowedUDPPorts = [ 58846 ];
    };
  };
}
