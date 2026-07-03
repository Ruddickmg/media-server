{ lib, pkgs, ... }:
{
  services.deluge = {
    enable = true;
    user = "deluge";
    group = "media";

    config = {
      download_location = "/media/downloads/completed";
      move_completed = true;
      move_completed_path = "/media/downloads/completed";
      torrentfiles_location = "/media/downloads/incomplete";
      prioritize_first_last_pieces = false;
      max_connections_global = 200;
      max_upload_slots_global = 20;
      max_upload_speed = -1.0;
      max_download_speed = -1.0;
      listen_ports = [ 6881 6889 ];
      random_port = false;
      daemon_port = 58846;
      allow_remote = true;
    };

    authFile = pkgs.writeText "deluge-auth" ''
      localclient:localclient:10
    '';
  };

  users.users.deluge.extraGroups = [ "media" ];
}
