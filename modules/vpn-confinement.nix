{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.media-server.vpn;
  ns = cfg.namespace;

  # Generate resolv.conf nameserver lines from a list of addresses.
  nameserverLines = addrs: lib.concatMapStrings (a: "nameserver ${a}\n") addrs;
  dnsAddrs = if cfg.dns != null then cfg.dns else [ "1.1.1.1" ];
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

        Set privateKeyFile to the path of a file containing just the base64
        private key (one line, no [Interface] header). Generate from your
        provider's wg-quick config:

          awk '/^PrivateKey/ {print $3}' vpn.conf > vpn-key
      '';
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/etc/nixos/secrets/vpn-key";
      description = ''
        Absolute path to file containing the WireGuard private key (base64, one line).
      '';
    };
    address = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = [ "10.5.0.2/32" ];
      description = ''
        IP address(es) of the WireGuard interface inside the namespace.
        Pass a list so both IPv4 and IPv6 can be included if the provider
        assigns both (e.g. Proton VPN WireGuard configs).
      '';
    };
    peerPublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Base64 public key of the WireGuard peer";
    };
    endpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "is80.nordvpn.com:51820";
      description = "Endpoint of the WireGuard peer (host:port)";
    };
    dns = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = [ "10.2.0.1" ];
      description = ''
        DNS server(s) for the network namespace. Falls back to 1.1.1.1 if
        not set. Pass a list when the provider gives multiple resolvers
        (e.g. Proton VPN provides both IPv4 and IPv6 DNS addresses).
      '';
    };
    persistentKeepalive = lib.mkOption {
      type = lib.types.int;
      default = 25;
      description = "Persistent keepalive interval in seconds";
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
        assertion = cfg.privateKeyFile != null;
        message = "media-server.vpn.privateKeyFile must be set when VPN is enabled";
      }
      {
        assertion = cfg.address != null;
        message = "media-server.vpn.address must be set when VPN is enabled";
      }
      {
        assertion = cfg.peerPublicKey != null;
        message = "media-server.vpn.peerPublicKey must be set when VPN is enabled";
      }
      {
        assertion = cfg.endpoint != null;
        message = "media-server.vpn.endpoint must be set when VPN is enabled";
      }
    ];

    networking.wireguard.interfaces."wg-${ns}" = {
      ips = cfg.address;
      privateKeyFile = cfg.privateKeyFile;
      interfaceNamespace = ns;
      peers = [
        {
          publicKey = cfg.peerPublicKey;
          allowedIPs = [
            "0.0.0.0/0"
            "::/0"
          ];
          endpoint = cfg.endpoint;
          persistentKeepalive = cfg.persistentKeepalive;
        }
      ];
    };

    # Ensure the netns exists before the WireGuard interface is brought up.
    systemd.services."wireguard-wg-${ns}" = {
      bindsTo = [ "create-netns-${ns}.service" ];
      after = [ "create-netns-${ns}.service" ];
    };

    systemd.services."create-netns-${ns}" = {
      description = "Create network namespace ${ns}";
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
                ip netns add ${ns} 2>/dev/null || true
                ip netns exec ${ns} ip link set lo up

                # Write DNS configuration for confined services.
                # Use the configured DNS servers if available, otherwise fall
                # back to a public resolver.
                mkdir -p /etc/netns/${ns}
                cat > /etc/netns/${ns}/resolv.conf << EOF
        ${nameserverLines dnsAddrs}
        nameserver 1.1.1.1
        options edns0 trust-ad
        EOF
      '';
    };
  };
}
