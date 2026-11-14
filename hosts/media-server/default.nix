let
  # Mount points/devices for the tiered storage layout. Shared with the
  # standalone disko module so the installer and the running system agree.
  paths = import ./storage-paths.nix;
in
{ lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/storage.nix
    ../../modules/media-tier.nix
    ../../modules/gotify.nix
    ../../modules/headless-server.nix
    ../../modules/auto-update.nix
    ../../modules/auto-reboot.nix
    ../../modules/vpn-confinement.nix
    ../../modules/graphics.nix
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
    ../../modules/services/beszel.nix
    ../../modules/services/podman.nix
    ../../modules/services/profilarr.nix
    ../../modules/services/cross-seed.nix
    ../../modules/services/delete-media-watch.nix
    ../../modules/battery-recharge-watch.nix
    ../../modules/services/media-acl.nix
    ../../modules/services/autobrr
    ../../modules/declarr.nix
  ];

  # we don't use jellyseerr, it is causing issues when attempting to start seerr so disabling it here
  disabledModules = [ "jellyseerr.nix" ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # disable monitor, no need for headless server
  boot.kernelParams = [
    "video=eDP-1:d"
  ];
  networking.hostName = "media-server";

  time.timeZone = "Pacific/Honolulu";

  media-server = {
    # SSD-first tiered storage: @media (SSD) + the HDD pool behind a single
    # /media union. Paths/devices live in storage-paths.nix so the standalone
    # disko module can read the same values.
    storage = {
      enable = true;
      ssdPath = paths.ssd;
      hddPoolPath = paths.hddPool;
      unifiedPath = paths.unified;
      inherit (paths)
        hddDisks
        parityDisks
        parityFiles
        ;
      # Keep SnapRAID off until a parity disk is installed. The array is already
      # described in storage.nix, so enabling it later is a one-line change.
      # TODO: set to true once a parity disk is added to storage-paths.nix.
      snapraid.enable = false;
    };

    headless.authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDpbe9bFjeQJCSYGd0FmAZ3ZlKbzHXv1CmsHzZ7sxTDd moon@nixos"
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
    deluge.authUsername = "ruddickmg";
    bazarr.enable = true;
    plex.enable = true;
    graphics.enable = true;
    seerr.enable = true;
    unpackerr.enable = true;
    profilarr.enable = true;
    cross-seed.enable = true;
    autobrr.enable = true;
    delete-media-watch.enable = true;
    media-acl.enable = true;

    beszel.enable = true;
  };
  hardware.bluetooth.enable = true;
  services.gotify = {
    enable = true;
    environment = {
      GOTIFY_SERVER_PORT = 6789;
      GOTIFY_SERVER_LISTENADDR = "127.0.0.1";
      # Gotify 2.x parses env vars as YAML; corsalloworigins is a []string
      GOTIFY_SERVER_CORS_ALLOWORIGINS = ''[".*"]'';
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
