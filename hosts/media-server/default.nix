{ lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/headless-server.nix
    ../../modules/auto-update.nix
    ../../modules/auto-reboot.nix
    ../../modules/vpn-confinement.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/deluge.nix
    ../../modules/services/unpackerr.nix
    ../../modules/services/prowlarr.nix
    ../../modules/services/sonarr.nix
    ../../modules/services/radarr.nix
    ../../modules/services/lidarr.nix
    ../../modules/services/bazarr.nix
    ../../modules/services/plex.nix
    ../../modules/services/seerr.nix
    ../../modules/services/netdata.nix
    ../../modules/declarr.nix
  ];

  # we don't use jellyseerr, it is causing issues when attempting to start seerr so disabling it here
  disabledModules = [ "jellyseerr.nix" ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  networking.hostName = "media-server";

  time.timeZone = "Pacific/Honolulu";

  media-server = {
    headless.authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFtQlXM4BBmMjr0B35YzlQIOJRPRUdiCas6Yzk5So2w3 grant@grant-XPS-15-9530"
    ];

    vpn.enable = true;
    # Copy these values from your WireGuard .conf file:
    #   privateKeyFile -> extract with: awk '/^PrivateKey/ {print $3}' vpn.conf > vpn-key
    vpn.privateKeyFile = "/etc/nixos/secrets/vpn-key";
    vpn.address = [
      "10.2.0.2/32"
      "2a07:b944::2:2/128"
    ]; # from [Interface] Address
    vpn.peerPublicKey = "E7Z4Q99+CTZSOKlLwHHSOV1U8vMhqqCpVRTeGBQIu2s="; # from [Peer] PublicKey
    vpn.endpoint = "37.120.137.194:51820"; # from [Peer] Endpoint
    vpn.dns = [
      "10.2.0.1"
      "2a07:b944::2:1"
    ]; # from [Interface] DNS

    sonarr.enable = true;
    radarr.enable = true;
    lidarr.enable = true;
    prowlarr.enable = true;
    deluge.enable = true;
    deluge.vpnConfinement = true;
    bazarr.enable = true;
    plex.enable = true;
    seerr.enable = true;
    unpackerr.enable = true;
    declarr.gotifyTokenFile = "/etc/nixos/secrets/gotify-token";

    netdata.enable = true;
    netdata.gotifyTokenFile = "/etc/nixos/secrets/gotify-token";
  };

  services.gotify = {
    enable = true;
    environment = {
      GOTIFY_SERVER_PORT = 6789;
      GOTIFY_SERVER_LISTENADDR = "127.0.0.1";
    };
  };

  services.resolved.enable = true;

  networking.nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      # Deluge, Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, Plex
      # opened conditionally per-service via openFirewall option
    ];
    allowedUDPPorts = [
      # Opened conditionally per-service
    ];
    rejectPackets = true;
    logReversePathDrops = true;
  };

  nixpkgs.config.allowUnfree = true;

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 30d";
  };

  nix.settings.auto-optimise-store = true;

  system.stateVersion = "26.05";
}
