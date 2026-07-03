{ lib, ... }:
{
  services.prowlarr = {
    enable = true;
    user = "prowlarr";
    group = "media";
  };

  users.users.prowlarr.extraGroups = [ "media" ];
}
