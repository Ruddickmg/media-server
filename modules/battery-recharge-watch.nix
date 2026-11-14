{ pkgs, ... }:

let
  # Python helper to send Matter On/Off commands to the local matter-server WebSocket
  matterToggleScript =
    pkgs.writers.writePython3 "matter-toggle"
      {
        libraries = [ pkgs.python3Packages.websockets ];
        flakeIgnore = [
          "E302"
          "E501"
        ];
      }
      ''
        import asyncio
        import json
        import sys
        import websockets

        node_id = int(sys.argv[1])
        command = sys.argv[2]  # "Off" or "On"

        async def main():
            uri = "ws://127.0.0.1:5580/ws"
            async with websockets.connect(uri) as ws:
                # Read initial server_info message
                await ws.recv()
                payload = {
                    "message_id": "1",
                    "command": "device_command",
                    "args": {
                        "endpoint_id": 1,
                        "node_id": node_id,
                        "cluster_id": 6,        # Matter OnOff Cluster (0x0006)
                        "command_name": command,
                        "payload": {}
                    }
                }
                await ws.send(json.dumps(payload))
                resp = await ws.recv()
                print(f"Matter {command} response: {resp}")


        asyncio.run(main())
      '';
in
{

  # Point matter-server to your active network interface
  services.matter-server = {
    enable = true;
    port = 5580;
    # For pairing, uncomment and refactor as necessary if needing to pair
    # extraArgs = {
    #   primary-interface = "wlp0s20f3";
    #   bluetooth-adapter = 0;
    # };
  };

  # Watchdog to power-cycle the GE Cync plug (Node 4) when plugged in but drops below 1W
  systemd.services.xps-pd-watchdog = {
    description = "Power-cycle GE Cync Matter plug (Node 4) when Dell XPS 9530 is plugged in but drops below 1W";
    wantedBy = [ "multi-user.target" ];
    after = [ "matter-server.service" ];
    wants = [ "matter-server.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "15s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
    script = ''
      NODE_ID=4

      while true; do
        AC_ONLINE=$(cat /sys/class/power_supply/AC/online 2>/dev/null || true)
        CAPACITY=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || true)
        CURR_UA=$(cat /sys/class/power_supply/BAT0/current_now 2>/dev/null || true)
        VOLT_UV=$(cat /sys/class/power_supply/BAT0/voltage_now 2>/dev/null || true)

        # Only trigger if the charger is physically plugged in (AC/online == 1)
        if [ "$AC_ONLINE" = "1" ] && [[ "$CAPACITY" =~ ^[0-9]+$ ]] && [[ "$CURR_UA" =~ ^-?[0-9]+$ ]] && [[ "$VOLT_UV" =~ ^[0-9]+$ ]]; then
          if [ "$CAPACITY" -lt 95 ]; then
            POWER_MW=$(( (CURR_UA * VOLT_UV) / 1000000000 ))

            if [ "$POWER_MW" -lt 1000 ]; then
              echo "Charger plugged in, but stalled at $CAPACITY% ($POWER_MW mW < 1000 mW). Turning Node $NODE_ID Off..."
              ${matterToggleScript} "$NODE_ID" Off || true

              # Poll until AC/online actually drops to 0 (brick capacitors bled down), up to 60s max
              WAITED=0
              while [ "$(cat /sys/class/power_supply/AC/online 2>/dev/null || true)" = "1" ] && [ "$WAITED" -lt 60 ]; do
                sleep 1
                WAITED=$((WAITED + 1))
              done
              echo "AC disconnected after ''${WAITED}s. Waiting 2s for CC pins to settle before turning On..."
              sleep 2

              ${matterToggleScript} "$NODE_ID" On || true

              # Wait up to 45s for AC/online to return and charge power to climb above 1W
              SETTLED=0
              while [ "$SETTLED" -lt 45 ]; do
                sleep 3
                SETTLED=$((SETTLED + 3))
                NEW_AC=$(cat /sys/class/power_supply/AC/online 2>/dev/null || true)
                NEW_CURR=$(cat /sys/class/power_supply/BAT0/current_now 2>/dev/null || true)
                NEW_VOLT=$(cat /sys/class/power_supply/BAT0/voltage_now 2>/dev/null || true)
                if [ "$NEW_AC" = "1" ] && [[ "$NEW_CURR" =~ ^-?[0-9]+$ ]] && [[ "$NEW_VOLT" =~ ^[0-9]+$ ]]; then
                  NEW_MW=$(( (NEW_CURR * NEW_VOLT) / 1000000000 ))
                  if [ "$NEW_MW" -ge 1000 ]; then
                    echo "Charging restored ($NEW_MW mW) after ''${SETTLED}s."
                    break
                  fi
                fi
              done
            fi
          fi
        fi

        sleep 10
      done
    '';
  };
}
