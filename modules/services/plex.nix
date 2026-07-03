{ lib, ... }:
{
  services.plex = {
    enable = true;
    openFirewall = true;
    user = "plex";
    group = "media";
  };

  users.users.plex.extraGroups = [ "media" ];
}
