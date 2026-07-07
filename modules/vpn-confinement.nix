{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.media-server.vpn;
  ns = cfg.namespace;

  # If wireguardConfig is provided, parse non-secret fields from the .conf at
  # evaluation time.  The PrivateKey is NOT parsed here — it is extracted at
  # runtime by the wireguard service preStart so the secret never enters the
  # Nix store.
  confText = if cfg.wireguardConfig != null then builtins.readFile cfg.wireguardConfig else null;

  parseField =
    key:
    if confText == null then
      null
    else
      let
        lines = lib.splitString "\n" confText;
        matchLine =
          line:
          let
            t = lib.trim line;
            prefix = "${key} = ";
          in
          if lib.hasPrefix prefix t then
            lib.removePrefix prefix t
          else if lib.hasPrefix "${key}=" t then
            lib.removePrefix "${key}=" t
          else
            null;
        matches = lib.filter (x: x != null) (map matchLine lines);
      in
      if matches != [ ] then lib.head matches else null;

  parsedAddressRaw = parseField "Address";
  parsedAddress = if parsedAddressRaw != null then lib.trim (lib.head (lib.splitString "," parsedAddressRaw)) else null;
  parsedPeerPublicKey = parseField "PublicKey";
  parsedEndpoint = parseField "Endpoint";
  parsedDnsRaw = parseField "DNS";
  parsedDns = if parsedDnsRaw != null then lib.trim (lib.head (lib.splitString "," parsedDnsRaw)) else null;

  effectivePrivateKeyFile = if cfg.wireguardConfig != null then "/run/vpn/wg-key" else cfg.privateKeyFile;
  effectiveAddress = if cfg.wireguardConfig != null then parsedAddress else cfg.address;
  effectivePeerPublicKey = if cfg.wireguardConfig != null then parsedPeerPublicKey else cfg.peerPublicKey;
  effectiveEndpoint = if cfg.wireguardConfig != null then parsedEndpoint else cfg.endpoint;
  effectiveDns = if cfg.dns != null then cfg.dns else parsedDns;
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
        VPN provider, or set the individual privateKeyFile/address/peerPublicKey/
        endpoint fields.
      '';
    };
    wireguardConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/etc/nixos/secrets/vpn.conf";
      description = ''
        Path to a standard WireGuard .conf file. When set, Address,
        PublicKey, Endpoint, and DNS are parsed automatically at evaluation
        time (the file must be present on the machine that evaluates the
        configuration — i.e. the target server during `nixos-rebuild switch`).
        The PrivateKey is extracted at runtime so it never enters the Nix
        store. Either this option OR all of privateKeyFile/address/
        peerPublicKey/endpoint must be set.
      '';
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/etc/nixos/secrets/vpn-key";
      description = ''
        Path to file containing the WireGuard private key (base64, one line).
        Required if wireguardConfig is not used.
      '';
    };
    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.5.0.2/32";
      description = "IP address of the WireGuard interface inside the namespace";
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
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.2.0.1";
      description = "DNS server for the network namespace. Parsed from wireguardConfig if not set.";
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
        assertion = cfg.wireguardConfig != null || (cfg.privateKeyFile != null && cfg.address != null && cfg.peerPublicKey != null && cfg.endpoint != null);
        message = "media-server.vpn: either set wireguardConfig to a .conf file, or set all of privateKeyFile, address, peerPublicKey, and endpoint";
      }
    ];

    networking.wireguard.interfaces."wg-${ns}" = {
      ips = [ effectiveAddress ];
      privateKeyFile = effectivePrivateKeyFile;
      interfaceNamespace = ns;
      peers = [
        {
          publicKey = effectivePeerPublicKey;
          allowedIPs = [
            "0.0.0.0/0"
            "::/0"
          ];
          endpoint = effectiveEndpoint;
          persistentKeepalive = cfg.persistentKeepalive;
        }
      ];
    };

    # Ensure the netns exists before the WireGuard interface is brought up.
    systemd.services."wireguard-wg-${ns}" = {
      bindsTo = [ "create-netns-${ns}.service" ];
      after = [ "create-netns-${ns}.service" ];
    };

    # If we are parsing a .conf file, extract the private key to /run before
    # the wireguard interface starts so privateKeyFile points at a valid path.
    systemd.services."wireguard-wg-${ns}" = lib.mkIf (cfg.wireguardConfig != null) {
      preStart = ''
        mkdir -p /run/vpn
        chmod 0700 /run/vpn
        ${pkgs.gawk}/bin/awk '/^PrivateKey/ {print $3}' ${cfg.wireguardConfig} > /run/vpn/wg-key
        chmod 0400 /run/vpn/wg-key
      '';
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
                # Use the DNS server from the WireGuard config if available,
                # otherwise fall back to a public resolver.
                mkdir -p /etc/netns/${ns}
                cat > /etc/netns/${ns}/resolv.conf << EOF
        nameserver ${if effectiveDns != null then effectiveDns else "1.1.1.1"}
        nameserver 1.1.1.1
        options edns0 trust-ad
        EOF
      '';
    };
  };
}
