{ lib, ... }:
{
  services.radarr = {
    enable = true;
    user = "radarr";
    group = "media";
  };

  users.users.radarr.extraGroups = [ "media" ];
}
