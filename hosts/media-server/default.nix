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
    ../../modules/declarr.nix
  ];

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

    sonarr.enable = true;
    radarr.enable = true;
    lidarr.enable = true;
    prowlarr.enable = true;
    deluge.enable = true;
    bazarr.enable = true;
    plex.enable = true;
    seerr.enable = true;
    unpackerr.enable = true;
  };

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
