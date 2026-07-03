{ lib, pkgs, config, ... }:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.deluge;
  vpnNs = config.media-server.vpn.namespace;
  useVpn = cfg.vpnConfinement && config.media-server.vpn.enable;
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
      config = {
        daemon_port = 58846;
        download_location = "/media/downloads/incomplete";
        move_completed = true;
        move_completed_path = "/media/downloads/completed";
        copy_torrent_file = false;
        del_copy_torrent_file = false;
        max_connections_global = 400;
        max_active_limit = 20;
        max_active_downloading = 12;
        max_active_seeding = 8;
        prioritize_first_last_pieces = false;
        max_upload_speed = -1.0;
        max_download_speed = -1.0;
        random_port = true;
        listen_random_port_range = [ 49152 65535 ];
        outgoing_ports = [ 49152 65535 ];
      };
      daemonUser = "deluge";
      daemonGroup = "deluge";
      dataDir = "/var/lib/deluge";
    };

    users.users.deluge = {
      extraGroups = [ "media" ];
    };

    systemd.services.deluged = {
      preStart = ''
        PASSWORD_FILE="/var/lib/deluge/auth"
        PASSWORD="${config.media-server.credentials.delugePassword}"
        if [ ! -f "$PASSWORD_FILE" ]; then
          echo "localclient:''${PASSWORD}:10" > "$PASSWORD_FILE"
          chown deluge:deluge "$PASSWORD_FILE"
          chmod 600 "$PASSWORD_FILE"
          echo "Seeded Deluge auth file"
        fi
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
        ReadWritePaths = [ "/var/lib/deluge" ];
      };
    } // mkIf useVpn {
      serviceConfig.NetworkNamespacePath = "/var/run/netns/${vpnNs}";
    };

    systemd.sockets.proxy-deluge = mkIf useVpn {
      description = "Socket for proxy to Deluge daemon in VPN namespace";
      listenStreams = [ "58846" ];
      wantedBy = [ "sockets.target" ];
    };

    systemd.services.proxy-deluge = mkIf useVpn {
      description = "Proxy Deluge daemon from VPN namespace to root namespace";
      requires = [ "deluged.service" "proxy-deluge.socket" ];
      after = [ "deluged.service" "proxy-deluge.socket" ];
      unitConfig.JoinsNamespaceOf = "deluged.service";
      serviceConfig = {
        User = "deluge";
        Group = "deluge";
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=5min 127.0.0.1:58846";
        PrivateNetwork = true;
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ 58846 ];
      allowedUDPPorts = [ 58846 ];
    };
  };
}
