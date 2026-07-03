{ lib, config, pkgs, ... }:
let
  dataDir = "/var/lib/bazarr";
  configIni = pkgs.writeText "bazarr-config.ini" (
    ''
[General]
ip = 0.0.0.0
port = 6767
base_url = /
cleanup = 0
daily_logs = 0

[sonarr]
ip = 127.0.0.1
port = 8989
base_url = /
api_key = '' + "${config.media-server.apiKeys.sonarr}" + ''
ssl = False

[radarr]
ip = 127.0.0.1
port = 7878
base_url = /
api_key = '' + "${config.media-server.apiKeys.radarr}" + ''
ssl = False
''
  );
in
{
  services.bazarr = {
    enable = true;
    user = "bazarr";
    group = "media";
    inherit dataDir;
  };

  systemd.services.bazarr.preStart =
    "if [ ! -f ${dataDir}/config/config.ini ]; then "
    + "mkdir -p ${dataDir}/config && "
    + "install -m 0644 -o bazarr -g bazarr ${configIni} ${dataDir}/config/config.ini; fi";

  users.users.bazarr.extraGroups = [ "media" ];
}
