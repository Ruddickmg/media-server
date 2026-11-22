{ pkgs, ... }:

let
  nodeId = "4";

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

  unplugCmd = pkgs.writeShellScriptBin "unplug" ''
    exec ${matterToggleScript} ${nodeId} Off
  '';

  pluginCmd = pkgs.writeShellScriptBin "plug-in" ''
    exec ${matterToggleScript} ${nodeId} On
  '';

  resetChargerCmd = pkgs.writeShellScriptBin "reset-charger" ''
    echo "Turning Node ${nodeId} Off..."
    ${matterToggleScript} ${nodeId} Off || true

    # Poll until AC/online actually drops to 0 (brick capacitors bled down), up to 60s max
    WAITED=0
    while [ "$(cat /sys/class/power_supply/AC/online 2>/dev/null || true)" = "1" ] && [ "$WAITED" -lt 60 ]; do
      sleep 1
      WAITED=$((WAITED + 1))
    done

    AC_ONLINE_POST=$(cat /sys/class/power_supply/AC/online 2>/dev/null || true)
    if [ "$AC_ONLINE_POST" = "1" ]; then
      echo "AC still reports online after ''${WAITED}s; proceeding anyway. Waiting 2s for CC pins to settle before turning On..."
    else
      echo "AC disconnected after ''${WAITED}s. Waiting 2s for CC pins to settle before turning On..."
    fi
    sleep 2

    ${matterToggleScript} ${nodeId} On || true

    # Wait up to 45s for AC/online to return and charge power to climb above 1W
    SETTLED=0
    while [ "$SETTLED" -lt 45 ]; do
      sleep 3
      SETTLED=$((SETTLED + 3))
      NEW_AC=$(cat /sys/class/power_supply/AC/online 2>/dev/null || true)
      NEW_CURR=$(cat /sys/class/power_supply/BAT0/current_now 2>/dev/null || echo "0")
      NEW_VOLT=$(cat /sys/class/power_supply/BAT0/voltage_now 2>/dev/null || true)
      if [ "$NEW_AC" = "1" ] && [[ "$NEW_CURR" =~ ^-?[0-9]+$ ]] && [[ "$NEW_VOLT" =~ ^[0-9]+$ ]]; then
        NEW_MW=$(( (''${NEW_CURR#-} * NEW_VOLT) / 1000000000 ))
        if [ "$NEW_MW" -ge 1000 ]; then
          echo "Charging restored ($NEW_MW mW) after ''${SETTLED}s."
          exit 0
        fi
      fi
    done

    echo "Finished reset cycle (charging did not exceed 1W within 45s)."
  '';
in
{
  # Install unplug, plug-in, and reset-charger globally into PATH
  environment.systemPackages = [
    unplugCmd
    pluginCmd
    resetChargerCmd
  ];

  # for pairing matter server (smart outlet)
  # networking.networkmanager.enable = true;

  # Point matter-server to your active network interface
  services.matter-server = {
    enable = true;
    port = 5580;
    extraArgs = {
      primary-interface = "enp0s20f0u1u4";
      # For pairing, uncomment and refactor as necessary if needing to pair
      # bluetooth-adapter = 0;
    };
  };

  # Watchdog to power-cycle the GE Cync plug (Node 4) when plugged in but drops
  # below 1W with the battery under 50%. The box runs 24/7 on AC, so the battery
  # is kept near 50% — the low-stress point for Li-ion calendar aging — instead
  # of topped up: above 50% a stalled charger is left alone and the battery
  # discharges, below 50% the stall gets power-cycled.
  systemd.services.xps-pd-watchdog = {
    description = "Power-cycle GE Cync Matter plug (Node 4) when Dell XPS 9530 is plugged in, battery below 50%, but drops below 1W";
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
      while true; do
        AC_ONLINE=$(cat /sys/class/power_supply/AC/online 2>/dev/null || true)
        CAPACITY=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || true)
        CURR_UA=$(cat /sys/class/power_supply/BAT0/current_now 2>/dev/null || echo "0")
        CURR_UA=''${CURR_UA:-0}
        VOLT_UV=$(cat /sys/class/power_supply/BAT0/voltage_now 2>/dev/null || true)

        # Only trigger if the charger is physically plugged in (AC/online == 1)
        if [ "$AC_ONLINE" = "1" ] && [[ "$CAPACITY" =~ ^[0-9]+$ ]] && [[ "$CURR_UA" =~ ^-?[0-9]+$ ]] && [[ "$VOLT_UV" =~ ^[0-9]+$ ]]; then
          # Only rescue a stalled charge when the battery actually needs it.
          if [ "$CAPACITY" -lt 50 ]; then
            POWER_MW=$(( (''${CURR_UA#-} * VOLT_UV) / 1000000000 ))
            if [ "$POWER_MW" -lt 1000 ]; then
              echo "Charger plugged in, but stalled at $CAPACITY% ($POWER_MW mW < 1000 mW). Running reset-charger..."
              ${resetChargerCmd}/bin/reset-charger
            fi
          fi
        fi

        sleep 10
      done
    '';
  };
}
