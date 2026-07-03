{ lib, config, ... }:
let
  dataDir = "/var/lib/deluge";
  password = config.media-server.credentials.delugePassword;
in
{
  services.deluge = {
    enable = true;
    user = "deluge";
    group = "media";
    inherit dataDir;

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
  };

  systemd.services.deluged.preStart =
    "install -d -o deluge -g deluge -m 700 ${dataDir} && "
    + "echo 'localclient:${password}:10' > ${dataDir}/auth && "
    + "chmod 600 ${dataDir}/auth";

  users.users.deluge.extraGroups = [ "media" ];
}
