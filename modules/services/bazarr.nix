{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.bazarr;

  seedIni = pkgs.writeText "bazarr-seed.ini" ''
    [General]
    ip = 127.0.0.1
    port = 6767
    base_url = /bazarr

    [sonarr]
    api_key = ${config.media-server.apiKeys.sonarr}
    full_update = True
    enabled = True

    [radarr]
    api_key = ${config.media-server.apiKeys.radarr}
    full_update = True
    enabled = True
  '';

  mergeScript = pkgs.writeText "bazarr-merge.py" ''
    import configparser
    import sys

    seed_path = sys.argv[1]
    config_path = sys.argv[2]

    seed = configparser.ConfigParser()
    seed.read(seed_path)
    cfg = configparser.ConfigParser()
    cfg.read(config_path)

    for section in seed.sections():
        if not cfg.has_section(section):
            cfg.add_section(section)
        for key, value in seed.items(section):
            cfg.set(section, key, value)

    with open(config_path, "w") as f:
        cfg.write(f)
  '';
in
{
  options.media-server.bazarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Bazarr";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Bazarr";
    };
  };

  config = mkIf cfg.enable {
    services.bazarr = {
      enable = true;
      group = "media";
      openFirewall = cfg.openFirewall;
    };

    systemd.services.bazarr = {
      preStart = ''
        CONFIG_FILE="/var/lib/bazarr/config/config.ini"
        mkdir -p "$(dirname "$CONFIG_FILE")"

        if [ ! -f "$CONFIG_FILE" ]; then
          cp ${seedIni} "$CONFIG_FILE"
        else
          ${pkgs.python3}/bin/python3 ${mergeScript} ${seedIni} "$CONFIG_FILE"
        fi

        chown -R bazarr:media "$(dirname "$CONFIG_FILE")"
        chmod 600 "$CONFIG_FILE"
      '';
      serviceConfig = {
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        PrivateDevices = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectSystem = "strict";
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        ReadWritePaths = [ "/var/lib/bazarr" "/media" ];
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
      };
    };
  };
}
