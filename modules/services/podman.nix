{
  lib,
  pkgs,
  config,
  ...
}:
{
  # Enable the common OCI container infrastructure and Podman backend.
  virtualisation.containers.enable = true;
  virtualisation.oci-containers.backend = "podman";
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };
}
