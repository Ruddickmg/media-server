{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.media-server.profilarr;
in
{
  options.media-server.profilarr = {
    enable = lib.mkEnableOption "Profilarr profile management for Radarr and Sonarr";
  };

  config = lib.mkIf cfg.enable {
    # Ensure the config directory exists before the container starts.
    systemd.tmpfiles.rules = [
      "d /var/lib/profilarr 0755 root root -"
    ];

    virtualisation.oci-containers.containers.profilarr = {
      autoStart = true;
      image = "ghcr.io/dictionarry-hub/profilarr:latest";
      volumes = [ "/var/lib/profilarr:/config" ];
      extraOptions = [ "--network=host" ];
    };
  };
}
