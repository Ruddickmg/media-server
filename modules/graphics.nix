{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.graphics;
in
{
  options.media-server.graphics = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable hardware accelerated graphics and the VA-API driver";
    };
  };

  config = mkIf cfg.enable {
    # hardware.graphics.enable symlinks /run/opengl-driver to a buildEnv of mesa
    # plus extraPackages. Non-NixOS binaries have no way to discover where nixpkgs
    # put drivers, and Plex's bundled ffmpeg is exactly that case -- the nixpkgs
    # Plex module already sets LD_LIBRARY_PATH=/run/opengl-driver/lib, so enabling
    # this is all it takes to point Plex at iHD.
    #
    # This does NOT load the i915 kernel module. DRM is loaded by udev via
    # modalias regardless; this option is purely the userspace driver lookup path.
    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs; [
        # iHD, the VA-API driver for the Tiger Lake iGPU (Intel Iris Xe, Xe-LP) in
        # this host. Supports Broadwell (2014) and newer; anything older would
        # need the mostly-unmaintained intel-vaapi-driver instead.
        intel-media-driver
      ];
    };
  };
}
