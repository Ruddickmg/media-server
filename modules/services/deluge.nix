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
        listen_ports = [
          6881
          6881
        ];
        # Deluge/libtorrent uses OS-assigned ephemeral ports for outgoing
        # connections by default. Explicitly setting outgoing_ports is not
        # recommended: it limits the number of concurrent peers and breaks
        # reconnection to the same client due to socket TIME_WAIT. See
        # libtorrent docs: https://libtorrent.org/reference-Settings.html

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
        seed_time_limit = 86400; # 60 days in minutes
        share_ratio_limit = 3.0;
        remove_seed_at_ratio = true;
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
          ProtectSystem = "strict";
          LockPersonality = true;
          KeyringMode = "private";
          RestrictSUIDSGID = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
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
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        CapabilityBoundingSet = [ "" ];
        ProtectHome = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectClock = true;
        PrivateMounts = true;
        PrivateDevices = true;
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --connections-max=4096 --exit-idle-time=5min 127.0.0.1:58846";
      };
    };

    # Run deluge-web inside the VPN namespace so it can talk to deluged
    # directly, then proxy it back to the root namespace for the *arr apps.
    systemd.services.delugeweb = mkIf useVpn {
      after = [ "create-netns-${vpnNs}.service" ];
      requires = [ "create-netns-${vpnNs}.service" ];
      serviceConfig = {
        NetworkNamespacePath = "/var/run/netns/${vpnNs}";
        BindReadOnlyPaths = [ "/etc/netns/${vpnNs}/resolv.conf:/etc/resolv.conf" ];
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
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        MemoryDenyWriteExecute = true;
        ReadWritePaths = [
          "/var/lib/deluge"
        ];
      };
    };

    systemd.sockets.proxy-deluge-web = mkIf useVpn {
      description = "Socket for proxy to Deluge Web UI in VPN namespace";
      listenStreams = [ "8112" ];
      wantedBy = [ "sockets.target" ];
    };

    systemd.services.proxy-deluge-web = mkIf useVpn {
      description = "Proxy Deluge Web UI from VPN namespace to root namespace";
      requires = [
        "delugeweb.service"
        "proxy-deluge-web.socket"
      ];
      after = [
        "delugeweb.service"
        "proxy-deluge-web.socket"
      ];
      serviceConfig = {
        NetworkNamespacePath = "/var/run/netns/${vpnNs}";
        BindReadOnlyPaths = [ "/etc/netns/${vpnNs}/resolv.conf:/etc/resolv.conf" ];
        User = "deluge";
        Group = "deluge";
        LimitNOFILE = mkForce 65536;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        CapabilityBoundingSet = [ "" ];
        ProtectHome = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectClock = true;
        PrivateMounts = true;
        PrivateDevices = true;
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --connections-max=4096 --exit-idle-time=5min 127.0.0.1:8112";
      };
    };

    # Keep ProtonVPN's NAT-PMP forwarded port in sync with Deluge's listen port.
    # Proton assigns a random public port for both UDP and TCP; the mapping
    # expires after 60 s, so we refresh every 45 s.  When the port changes we
    # update Deluge via deluge-console (both run inside the VPN namespace, so
    # the console connects to 127.0.0.1:58846 directly).  The thin client still
    # reaches the daemon through proxy-deluge from the root namespace.
    systemd.services.deluge-natpmp = mkIf useVpn {
      description = "Refresh ProtonVPN NAT-PMP port mapping and sync Deluge listen port";
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
      partOf = [ "deluged.service" ];
      path = with pkgs; [
        libnatpmp
        gawk
        deluge
      ];
      environment.HOME = config.services.deluge.dataDir;
      script = ''
        #!/usr/bin/env bash
        set -euo pipefail

        LAST_PORT=""

        while true; do
          # Refresh both UDP and TCP mappings — Proton assigns the same public
          # port for both.  Lifetime is 60 s; we refresh every 45 s.
          udp_out=$(natpmpc -a 1 0 udp 60 -g 10.2.0.1) \
            || { echo "natpmpc UDP request failed" >&2; exit 1; }
          tcp_out=$(natpmpc -a 1 0 tcp 60 -g 10.2.0.1) \
            || { echo "natpmpc TCP request failed" >&2; exit 1; }

          tcp_port=$(awk '/Mapped public port/ {print $4; exit}' <<<"$tcp_out")
          udp_port=$(awk '/Mapped public port/ {print $4; exit}' <<<"$udp_out")

          if [[ -z "$tcp_port" || -z "$udp_port" ]]; then
            echo "natpmpc did not return a mapped port (tcp=$tcp_port udp=$udp_port)" >&2
            exit 1
          fi

          if [[ "$tcp_port" != "$udp_port" ]]; then
            echo "natpmpc returned mismatched ports (tcp=$tcp_port udp=$udp_port)" >&2
            exit 1
          fi

          port="$tcp_port"

          if [[ "$port" != "$LAST_PORT" ]]; then
            echo "ProtonVPN forwarded port changed: $port"
            deluge-console \
              "connect 127.0.0.1:58846 localclient deluge; \
               config --set random_port False; \
               config --set listen_ports ($port,$port)"
            LAST_PORT="$port"
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
        RestartSec = "10s";
        # Hardening — mirror the deluged service profile.
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
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        MemoryDenyWriteExecute = true;
        ReadWritePaths = [
          "/var/lib/deluge"
        ];
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ 58846 ];
      allowedUDPPorts = [ 58846 ];
    };
  };
}
