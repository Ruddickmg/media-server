{ lib, config, pkgs, ... }:
let
  dataDir = "/var/lib/radarr";
  apiKey = config.media-server.apiKeys.radarr;
  configXml = pkgs.writeText "radarr-config.xml" (
    ''<?xml version="1.0" encoding="utf-8"?>
<Config>
  <ApiKey>'' + "${apiKey}" + ''</ApiKey>
  <Port>7878</Port>
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
  services.radarr = {
    enable = true;
    user = "radarr";
    group = "media";
    inherit dataDir;
  };

  systemd.services.radarr.preStart =
    "if [ ! -f ${dataDir}/config.xml ]; then "
    + "install -m 0644 -o radarr -g radarr ${configXml} ${dataDir}/config.xml; fi";

  users.users.radarr.extraGroups = [ "media" ];
}
