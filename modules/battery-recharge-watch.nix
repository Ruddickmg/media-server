{ pkgs, ... }:

let
  # Python helper to send Matter On/Off commands to the local matter-server WebSocket
  matterToggleScript = pkgs.writers.writePython3 "matter-toggle" {
    libraries = [ pkgs.python3Packages.websockets ];
  } ''
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
  # 1. Local Matter Controller
  services.matter-server = {
    enable = true;
    port = 5580;
  };

  # 2. Watchdog to power-cycle the GE Cync plug when plugged in but drops below 1W
  systemd.services.xps-pd-watchdog = {
    description = "Power-cycle GE Cync Matter plug when Dell XPS 9530 is plugged in but drops below 1W";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" "matter-server.service" ];
    wants = [ "matter-server.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "15s";
    };
    script = ''
      NODE_ID=1  # Update if your plug was assigned a different Node ID

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
              echo "Charger plugged in, but stalled at $CAPACITY% ($POWER_MW mW < 1000 mW). Power-cycling GE Cync plug..."
              ${matterToggleScript} "$NODE_ID" Off || true
              # Wait 12s so the Dell 130W brick capacitors drain and USB-C CC pins reset to 0V
              sleep 12
              ${matterToggleScript} "$NODE_ID" On || true

              # Wait 30s for the brick to boot and renegotiate 130W PD before checking again
              sleep 30
            fi
          fi
        fi

        sleep 10
      done
    '';
  };
}
