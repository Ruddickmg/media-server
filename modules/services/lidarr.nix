{ lib, config, pkgs, ... }:
let
  dataDir = "/var/lib/lidarr";
  apiKey = config.media-server.apiKeys.lidarr;
  configXml = pkgs.writeText "lidarr-config.xml" (
    ''<?xml version="1.0" encoding="utf-8"?>
<Config>
  <ApiKey>'' + "${apiKey}" + ''</ApiKey>
  <Port>8686</Port>
  <SslPort>9898</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <UpdateMechanism>External</UpdateMechanism>
  <BindAddress>*</BindAddress>
  <LogLevel>Info</LogLevel>
</Config>''
  );
in
{
  services.lidarr = {
    enable = true;
    user = "lidarr";
    group = "media";
    inherit dataDir;
  };

  systemd.services.lidarr.preStart =
    "if [ ! -f ${dataDir}/config.xml ]; then "
    + "install -m 0644 -o lidarr -g lidarr ${configXml} ${dataDir}/config.xml; fi";

  users.users.lidarr.extraGroups = [ "media" ];
}
