{ lib, pkgs, config, ... }:
let
  cfg = config.media-server.netdata;

  healthAlarmNotify = pkgs.writeText "health_alarm_notify.conf" ''
    SEND_GOTIFY="YES"
    GOTIFY_SERVER_URL="http://127.0.0.1:6789"
    GOTIFY_APP_TOKEN=$(cat ${cfg.gotifyTokenFile} 2>/dev/null || echo "")
    DEFAULT_RECIPIENT_GOTIFY="*"
  '';

  servicesAlarm = pkgs.writeText "services.conf" ''
    alarm: service_failed
       on: systemd.service_state
       lookup: max -1m of failed units
       every: 30s
       units: services
       warn: $this > 0
       info: One or more systemd services are in failed state
  '';
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
