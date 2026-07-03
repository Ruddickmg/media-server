{ lib, config, pkgs, ... }:
let
  dataDir = "/var/lib/sonarr";
  apiKey = config.media-server.apiKeys.sonarr;
  configXml = pkgs.writeText "sonarr-config.xml" (
    ''<?xml version="1.0" encoding="utf-8"?>
<Config>
  <ApiKey>'' + "${apiKey}" + ''</ApiKey>
  <Port>8989</Port>
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
  services.sonarr = {
    enable = true;
    user = "sonarr";
    group = "media";
    inherit dataDir;
  };

  systemd.services.sonarr.preStart =
    "if [ ! -f ${dataDir}/config.xml ]; then "
    + "install -m 0644 -o sonarr -g sonarr ${configXml} ${dataDir}/config.xml; fi";

  users.users.sonarr.extraGroups = [ "media" ];
}
