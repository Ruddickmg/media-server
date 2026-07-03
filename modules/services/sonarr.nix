{ lib, ... }:
{
  services.sonarr = {
    enable = true;
    user = "sonarr";
    group = "media";
  };

  users.users.sonarr.extraGroups = [ "media" ];
}
