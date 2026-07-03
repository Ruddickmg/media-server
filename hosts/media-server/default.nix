{ lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/auto-update.nix
    ../../modules/init.nix
    ../../modules/services/deluge.nix
    ../../modules/services/unpackerr.nix
    ../../modules/services/prowlarr.nix
    ../../modules/services/sonarr.nix
    ../../modules/services/radarr.nix
    ../../modules/services/lidarr.nix
    ../../modules/services/bazarr.nix
    ../../modules/services/plex.nix
  ];

  networking.hostName = "media-server";

  networking.firewall.allowedTCPPorts = [
    58846  # Deluge daemon (thin client)
    8112   # Deluge web UI
    8989   # Sonarr
    7878   # Radarr
    8686   # Lidarr
    9696   # Prowlarr
    6767   # Bazarr
    32400  # Plex
  ];

  networking.firewall.allowedUDPPorts = [
    1900   # Plex DLNA
    5353   # Plex mDNS
  ];

  system.stateVersion = "24.11";
}
