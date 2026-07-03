{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.media-server.vpn;
  ns = cfg.namespace;
in
{
  options.media-server.vpn = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable WireGuard VPN network namespace for isolating service traffic.
        Services with VPN confinement enabled will run in a network namespace
        where WireGuard is the only network interface, providing a built-in
        kill switch and IP leak protection.

        Set wireguardConfig to the path of a WireGuard .conf file from your
        VPN provider (Mullvad, AirVPN, ProtonVPN, PIA, etc.).
      '';
    };
    wireguardConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/etc/nixos/secrets/vpn.conf";
      description = "Path to WireGuard configuration file from your VPN provider";
    };
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "vpn";
      description = "Name of the network namespace";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.wireguardConfig != null;
        message = "media-server.vpn.wireguardConfig must be set when VPN is enabled";
      }
    ];

    systemd.services."create-netns-${ns}" = {
      description = "Create network namespace ${ns}";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ip netns add ${ns} 2>/dev/null || true
        ip netns exec ${ns} ip link set lo up
      '';
    };

    systemd.services."wg-${ns}" = {
      description = "WireGuard in namespace ${ns}";
      bindsTo = [ "create-netns-${ns}.service" ];
      after = [ "create-netns-${ns}.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        NetworkNamespacePath = "/var/run/netns/${ns}";
      };
      script = ''
        ${pkgs.wireguard-tools}/bin/wg-quick up ${cfg.wireguardConfig}
      '';
      preStop = ''
        ${pkgs.wireguard-tools}/bin/wg-quick down ${cfg.wireguardConfig}
      '';
    };
  };
}
