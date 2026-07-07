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
        random_port = true;
        outgoing_ports = [
          49152
          65535
        ];

        # Bandwidth (capped at ~80% of 73.4/10.3 Mbps connection)
        max_download_speed = 7000.0;
        max_upload_speed = 1000.0;

        # Connections
        max_connections_global = 500;
        max_connections_per_torrent = 100;
        max_upload_slots_per_torrent = 8;

        # Queue — *arrs remove their own torrents via per-indexer goals
        max_active_limit = 50;
        max_active_downloading = 5;
        max_active_seeding = 40;

        # Seeding ceiling: stop at 3.0 ratio or 14 days, whichever first
        # *arrs will remove their torrents earlier; manual torrents hit this cap
        stop_seed_at_ratio = true;
        stop_seed_ratio = 3.0;
        seed_time_limit = 20160; # 14 days in minutes
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
        serviceConfig.NetworkNamespacePath = "/var/run/netns/${vpnNs}";
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
      unitConfig.JoinsNamespaceOf = "deluged.service";
      serviceConfig = {
        User = "deluge";
        Group = "deluge";
        LimitNOFILE = mkForce 65536;
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=5min 127.0.0.1:58846";
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ 58846 ];
      allowedUDPPorts = [ 58846 ];
    };
  };
}
