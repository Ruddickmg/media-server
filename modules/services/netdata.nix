{ lib, pkgs, config, ... }:
let
  cfg = config.media-server.netdata;

  monitoredServices = [
    "sonarr"
    "radarr"
    "lidarr"
    "prowlarr"
    "bazarr"
    "deluged"
    "deluge-web"
    "plex"
    "unpackerr"
    "nixos-auto-update"
  ];

  healthAlarmNotify = pkgs.writeText "health_alarm_notify.conf" ''
    SEND_GOTIFY="YES"
    GOTIFY_SERVER_URL="http://127.0.0.1:6789"
    GOTIFY_APP_TOKEN=$(cat ${cfg.gotifyTokenFile} 2>/dev/null || echo "")
    DEFAULT_RECIPIENT_GOTIFY="*"
  '';

  serviceCheckScript = pkgs.writeShellScript "netdata-service-health" ''
    set -euo pipefail

    STATE_DIR="/run/service-health"
    TOKEN_FILE="${cfg.gotifyTokenFile}"
    GOTIFY_URL="http://127.0.0.1:6789"

    mkdir -p "$STATE_DIR"

    TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null || echo "")"
    [ -n "$TOKEN" ] || exit 0

    notify() {
      local title="$1" message="$2" priority="$3"
      curl -sf -X POST "$GOTIFY_URL/message?token=$TOKEN" \
        -F "title=$title" \
        -F "message=$message" \
        -F "priority=$priority" >/dev/null 2>&1 || true
    }

    for service in ${toString monitoredServices}; do
      if systemctl is-failed --quiet "$service.service" 2>/dev/null; then
        if [ ! -f "$STATE_DIR/$service.failed" ]; then
          touch "$STATE_DIR/$service.failed"
          case "$service" in
            nixos-auto-update)
              notify "NixOS Build Failed" "System auto-update exited with errors" 10
              ;;
            *)
              notify "Service Failed" "$service.service entered failed state" 8
              ;;
          esac
        fi
      else
        if [ -f "$STATE_DIR/$service.failed" ]; then
          rm -f "$STATE_DIR/$service.failed"
          case "$service" in
            nixos-auto-update)
              notify "NixOS Build Succeeded" "System auto-update completed successfully" 3
              ;;
            *)
              notify "Service Recovered" "$service.service is now running normally" 3
              ;;
          esac
        fi
      fi
    done
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
    };

    systemd.services.netdata-service-health = {
      description = "Monitor service health and alert via Gotify";
      after = [ "network.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [ curl systemd ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        RuntimeDirectory = "service-health";
        RuntimeDirectoryMode = "0755";
      };
      script = ''
        exec ${serviceCheckScript}
      '';
    };

    systemd.timers.netdata-service-health = {
      description = "Periodic service health check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:0/1";
        Persistent = true;
      };
    };
  };
}
