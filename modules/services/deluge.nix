{ lib, pkgs, ... }:
{
  services.deluge = {
    enable = true;
    user = "deluge";
    group = "media";
    dataDir = "/var/lib/deluge";

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

  systemd.services.deluge-auth = {
    description = "Generate Deluge auth credentials";
    before = [ "deluged.service" ];
    requiredBy = [ "deluged.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -f /var/lib/deluge/auth ]; then
        PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
        echo "localclient:$PASSWORD:10" > /var/lib/deluge/auth
        chown deluge:deluge /var/lib/deluge/auth
        chmod 600 /var/lib/deluge/auth
        echo "$PASSWORD" > /var/lib/deluge/.password
        chown deluge:deluge /var/lib/deluge/.password
        chmod 600 /var/lib/deluge/.password
        echo "Deluge thin client credentials: localclient / $PASSWORD" | systemd-cat -t deluge-auth
      fi
    '';
  };

  users.users.deluge.extraGroups = [ "media" ];
}
