{ lib, pkgs, ... }:
{
  systemd.services.media-server-init = {
    description = "Wire up media server service interconnections";
    after = [
      "deluged.service"
      "sonarr.service"
      "radarr.service"
      "lidarr.service"
      "prowlarr.service"
      "bazarr.service"
    ];
    wants = [
      "deluged.service"
      "sonarr.service"
      "radarr.service"
      "lidarr.service"
      "prowlarr.service"
      "bazarr.service"
    ];
    path = with pkgs; [ curl gnugrep coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      MARKER="/var/lib/media-server/.configured"
      [ -f "$MARKER" ] && exit 0

      wait_file() {
        local f="$1" n=0
        while [ ! -f "$f" ] && [ $n -lt 60 ]; do
          sleep 2
          n=$((n + 1))
        done
        [ -f "$f" ]
      }

      wait_file /var/lib/sonarr/config.xml || true
      wait_file /var/lib/radarr/config.xml || true
      wait_file /var/lib/lidarr/config.xml || true
      wait_file /var/lib/prowlarr/config.xml || true

      SONARR_KEY=$(grep -oP '<ApiKey>\K[^<]+' /var/lib/sonarr/config.xml 2>/dev/null || echo "")
      RADARR_KEY=$(grep -oP '<ApiKey>\K[^<]+' /var/lib/radarr/config.xml 2>/dev/null || echo "")
      LIDARR_KEY=$(grep -oP '<ApiKey>\K[^<]+' /var/lib/lidarr/config.xml 2>/dev/null || echo "")
      PROWLARR_KEY=$(grep -oP '<ApiKey>\K[^<]+' /var/lib/prowlarr/config.xml 2>/dev/null || echo "")

      DELUGE_PASS=$(cat /var/lib/deluge/.password 2>/dev/null || echo "")

      # Configure Bazarr with Sonarr and Radarr API keys
      if [ -n "$SONARR_KEY" ] || [ -n "$RADARR_KEY" ]; then
        mkdir -p /var/lib/bazarr/config
        cat > /var/lib/bazarr/config/config.ini << 'INI'
[General]
ip = 0.0.0.0
port = 6767
base_url = /
cleanup = 0
daily_logs = 0
INI

        if [ -n "$SONARR_KEY" ]; then
          cat >> /var/lib/bazarr/config/config.ini << EOF
[sonarr]
ip = 127.0.0.1
port = 8989
base_url = /
api_key = $SONARR_KEY
ssl = False
EOF
        fi

        if [ -n "$RADARR_KEY" ]; then
          cat >> /var/lib/bazarr/config/config.ini << EOF
[radarr]
ip = 127.0.0.1
port = 7878
base_url = /
api_key = $RADARR_KEY
ssl = False
EOF
        fi

        chown -R bazarr:bazarr /var/lib/bazarr/config
        systemctl restart bazarr || true
      fi

      # Add Deluge as download client to Sonarr, Radarr, Lidarr
      add_deluge() {
        local key="$1" port="$2" category="$3" api_ver="$4"
        [ -z "$key" ] || [ -z "$DELUGE_PASS" ] && return
        curl -s -X POST "http://127.0.0.1:$port/api/$api_ver/downloadclient" \
          -H "X-Api-Key: $key" \
          -H "Content-Type: application/json" \
          -d "$(cat << END
        {
          "enable": true,
          "protocol": "torrent",
          "priority": 1,
          "name": "Deluge",
          "fields": [
            { "name": "Host", "value": "127.0.0.1" },
            { "name": "Port", "value": 58846 },
            { "name": "Password", "value": "$DELUGE_PASS" },
            { "name": "Category", "value": "$category" }
          ],
          "implementationName": "Deluge",
          "implementation": "Deluge",
          "configContract": "DelugeSettings"
        }
END
)" > /dev/null 2>&1 || echo "Warning: failed to add Deluge to ${category^}"
      }

      add_deluge "$SONARR_KEY" 8989 sonarr v3
      add_deluge "$RADARR_KEY" 7878 radarr v3
      add_deluge "$LIDARR_KEY" 8686 lidarr v1

      # Sync Sonarr, Radarr, Lidarr into Prowlarr
      if [ -n "$PROWLARR_KEY" ]; then
        prowlarr_app() {
          local name="$1" port="$2" api_key="$3"
          [ -z "$api_key" ] && return
          curl -s -X POST "http://127.0.0.1:9696/api/v1/applications" \
            -H "X-Api-Key: $PROWLARR_KEY" \
            -H "Content-Type: application/json" \
            -d "$(cat << END
          {
            "name": "$name",
            "implementation": "$name",
            "configContract": {
              "prowlarrUrl": "http://127.0.0.1:9696",
              "baseUrl": "http://127.0.0.1:$port",
              "apiKey": "$api_key",
              "syncLevel": "addAndRemove"
            }
          }
END
)" > /dev/null 2>&1 || echo "Warning: failed to add $name to Prowlarr"
        }

        prowlarr_app "Sonarr" 8989 "$SONARR_KEY"
        prowlarr_app "Radarr" 7878 "$RADARR_KEY"
        prowlarr_app "Lidarr" 8686 "$LIDARR_KEY"
      fi

      mkdir -p "$(dirname "$MARKER")"
      date > "$MARKER"
    '';
  };
}
