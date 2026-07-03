{ lib, config, pkgs, ... }:
let
  dataDir = "/var/lib/prowlarr";
  apiKey = config.media-server.apiKeys.prowlarr;
  configXml = pkgs.writeText "prowlarr-config.xml" (
    ''<?xml version="1.0" encoding="utf-8"?>
<Config>
  <ApiKey>'' + "${apiKey}" + ''</ApiKey>
  <Port>9696</Port>
  <LogLevel>info</LogLevel>
  <UpdateMechanism>External</UpdateMechanism>
  <BindAddress>*</BindAddress>
</Config>''
  );
in
{
  services.prowlarr = {
    enable = true;
    user = "prowlarr";
    group = "media";
    inherit dataDir;
  };

  systemd.services.prowlarr.preStart =
    "if [ ! -f ${dataDir}/config.xml ]; then "
    + "install -m 0644 -o prowlarr -g prowlarr ${configXml} ${dataDir}/config.xml; fi";

  users.users.prowlarr.extraGroups = [ "media" ];
}
