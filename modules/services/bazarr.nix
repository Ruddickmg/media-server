{ lib, pkgs, ... }:
{
  services.bazarr = {
    enable = true;
    user = "bazarr";
    group = "media";
  };

  users.users.bazarr.extraGroups = [ "media" ];
}
