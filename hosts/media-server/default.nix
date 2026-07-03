{ lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/auto-update.nix
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
  ];

  networking.hostName = "media-server";

  networking.firewall = {
    enable = true;
    trustedInterfaces = [
      "tailscale0"
      "lo"
    ];
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

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 30d";
  };

  nix.settings.auto-optimise-store = true;

  system.stateVersion = "24.11";
}
