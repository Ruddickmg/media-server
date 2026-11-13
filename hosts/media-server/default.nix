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

  services.gotify = {
    enable = true;
    environment = {
      GOTIFY_SERVER_PORT = 6789;
      GOTIFY_SERVER_LISTENADDR = "127.0.0.1";
      # Gotify 2.x parses env vars as YAML; corsalloworigins is a []string
      GOTIFY_SERVER_CORS_ALLOWORIGINS = ''[".*"]'';
    };
  };

  # The XPS 15 EC stops charging while AC is still connected, typically after
  # gaining ~3% of charge, and keeps reporting "Charging" while the pack drains.
  # Only physically replugging the charger reliably re-arms it, so this service
  # reproduces that in software as a ladder of escalating tiers, verifying each
  # one against the charge_now trend. See system/battery-recharge-watch.nix.
  services.batteryRechargeWatch = {
    enable = true;
    dryRun = false;

    # Detection is over a 3 minute window; at the observed 0.8-2.1A charge
    # rates that is tens of mAh, well above gauge noise.
    window = 180;

    # The fault recurs roughly every 20-30 minutes of charging, so recover fast
    # and retry quickly instead of backing off into a dead battery.
    cooldown = 60;
    maxCooldown = 300;
    verifyWait = 25;

    # Tiers 1-2: rebind the ACPI AC and battery drivers (cheap, re-runs _PSR
    # and _BST so the EC is asked to re-detect the adapter).
    enableAcRebind = true;
    enableBatteryRebind = true;

    # Tier 3: UCSI PPM_RESET via ucsi_acpi rebind, then a full typec/ucsi
    # stack reload. /sys/class/typec/port0..2 appears when the machine is
    # healthy; during some faults the ports disappear entirely.
    enableUcsiReset = true;

    # Tier 4: the Dell SMM charge-mode knobs. Harmless, but they have never
    # been observed to re-arm a stopped charger on this machine.
    enableDellModes = true;

    # Tier 5: suspend/resume with rtcwake reinitializes EC state. Allowed here
    # because this is a desktop session; a headless appliance that sets
    # AllowSuspend=no must leave this off.
    enableSuspendReset = true;
    suspendAfterFailures = 0;
    suspendSeconds = 8;

    # Tier 6: rebind the ACPI EC driver itself, the closest software analogue
    # of Dell's "drain flea power" reset.
    enableEcReset = true;

    # Tier 7: only as a very last resort, and only once the pack is nearly
    # empty, reboot to re-run the firmware's EC init. This is what a headless
    # media server relies on, since it cannot be replugged remotely.
    enableRebootReset = true;
    rebootBelowCapacity = 10;
    rebootCooldown = 1800;
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
