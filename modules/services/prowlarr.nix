{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.prowlarr;
  vpnNs = config.media-server.vpn.namespace;
  useVpn = cfg.vpnConfinement && config.media-server.vpn.enable;
in
{
  options.media-server.prowlarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Prowlarr";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Prowlarr";
    };
    vpnConfinement = mkOption {
      type = types.bool;
      default = false;
      description = "Run Prowlarr inside the VPN network namespace";
    };
  };

  config = mkIf cfg.enable {
    services.prowlarr = {
      enable = true;
      openFirewall = cfg.openFirewall;
      apiKeyFile = "${pkgs.writeText "prowlarr-api-key" config.media-server.apiKeys.prowlarr}";
      environmentFiles = [
        (pkgs.writeText "prowlarr-env" ''
          PROWLARR__CONFIG__HOST__APIKEY=${config.media-server.apiKeys.prowlarr}
        '')
      ];
    };

    systemd.services.prowlarr.serviceConfig = {
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = [ "" ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      SystemCallArchitectures = "native";
      PrivateDevices = true;
      LockPersonality = true;
      RestrictNamespaces = true;
    }
    // mkIf useVpn {
      serviceConfig.NetworkNamespacePath = "/var/run/netns/${vpnNs}";
    };

    systemd.sockets.proxy-prowlarr = mkIf useVpn {
      description = "Socket for proxy to Prowlarr in VPN namespace";
      listenStreams = [ "9696" ];
      wantedBy = [ "sockets.target" ];
    };

    systemd.services.proxy-prowlarr = mkIf useVpn {
      description = "Proxy Prowlarr from VPN namespace to root namespace";
      requires = [
        "prowlarr.service"
        "proxy-prowlarr.socket"
      ];
      after = [
        "prowlarr.service"
        "proxy-prowlarr.socket"
      ];
      unitConfig.JoinsNamespaceOf = "prowlarr.service";
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=5min 127.0.0.1:9696";
        PrivateNetwork = true;
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ 9696 ];
      allowedUDPPorts = [ 9696 ];
    };
  };
}
