{ lib, ... }:
{
  services.lidarr = {
    enable = true;
    user = "lidarr";
    group = "media";
  };

  users.users.lidarr.extraGroups = [ "media" ];
}
