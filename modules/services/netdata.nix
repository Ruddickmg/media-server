{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.media-server.netdata;

  healthAlarmNotify = pkgs.writeText "health_alarm_notify.conf" ''
    SEND_GOTIFY="YES"
    GOTIFY_SERVER_URL="http://127.0.0.1:6789"
    GOTIFY_APP_TOKEN=$(cat ${cfg.gotifyTokenFile} 2>/dev/null || echo "")
    DEFAULT_RECIPIENT_GOTIFY="*"
  '';

  monitoredServices = [
    {
      name = "sonarr";
      label = "Sonarr";
    }
    {
      name = "radarr";
      label = "Radarr";
    }
    {
      name = "lidarr";
      label = "Lidarr";
    }
    {
      name = "prowlarr";
      label = "Prowlarr";
    }
    {
      name = "bazarr";
      label = "Bazarr";
    }
    {
      name = "deluged";
      label = "Deluge";
    }
    {
      name = "plex";
      label = "Plex";
    }
    {
      name = "unpackerr";
      label = "Unpackerr";
    }
    {
      name = "nixos-auto-update";
      label = "NixOS Auto-Update";
    }
  ];

  alarmFor = svc: ''
    alarm: ${svc.name}_failed
       on: systemd.service_state
       lookup: max -1m of ${svc.name}.service
       every: 30s
       units: state
       warn: $this > 0
       info: ${svc.label} service is in failed state
  '';

  servicesAlarm = pkgs.writeText "services.conf" (
    builtins.concatStringsSep "\n" (map alarmFor monitoredServices)
  );
in
{
  options.media-server.netdata = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Netdata monitoring with Gotify alerts";
    };
    gotifyTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to file containing Gotify app token";
    };
  };

  config = lib.mkIf cfg.enable {
    services.netdata = {
      enable = true;
      config = {
        web = {
          "bind to" = "127.0.0.1";
          "default port" = 19999;
          "web files owner" = "root";
          "web files group" = "root";
        };
        global = {
          "memory mode" = "ram";
          "debug log" = "none";
          "access log" = "none";
          "error log" = "syslog";
        };
      };
    };

    services.netdata.configDir = {
      "health_alarm_notify.conf" = healthAlarmNotify;
      "health.d/services.conf" = servicesAlarm;
    };
  };
}
