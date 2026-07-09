{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.media-server.beszel;
in
{
  options.media-server.beszel = {
    enable = lib.mkEnableOption "Beszel monitoring hub and agent";

    adminEmail = lib.mkOption {
      type = lib.types.str;
      default = "ruddickmg@gmail.com";
      description = "Email address for the Beszel admin account. Only used on first setup.";
    };

    adminPassword = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Password for the Beszel admin account. Only used on first setup. Tailscale is the access control layer.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Beszel hub — PocketBase-backed web dashboard
    services.beszel.hub = {
      enable = true;
      host = "127.0.0.1";
      port = 8090;
    };

    # Beszel agent — runs on the same host, hub connects via SSH
    services.beszel.agent = {
      enable = true;
      openFirewall = false;
      environment = {
        PORT = "45876";
      };
      environmentFile = "/var/lib/beszel-agent/env";
    };

    # Ensure podman docker socket is available so the agent can read container stats
    virtualisation.podman.dockerSocket.enable = lib.mkDefault true;

    # Create directories for agent env file and hub data
    systemd.tmpfiles.rules = [
      "d /var/lib/beszel-agent 0750 root beszel-agent -"
      "d /var/lib/beszel-hub 0750 beszel-hub beszel-hub -"
    ];

    systemd.services.beszel-init = {
      description = "Initialize Beszel hub and agent";
      after = [
        "beszel-hub.service"
      ];
      wants = [
        "beszel-hub.service"
      ];
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        OnFailure = "notify-gotify@%n.service";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.curl
        pkgs.jq
        pkgs.coreutils
      ];
      script = ''
        set -uo pipefail

        HUB_URL="http://127.0.0.1:8090"
        AGENT_ENV="/var/lib/beszel-agent/env"

        ADMIN_EMAIL="${cfg.adminEmail}"
        ADMIN_PASS="${cfg.adminPassword}"

        # Wait for Beszel hub to be ready
        for i in $(seq 1 60); do
          if curl -sf --connect-timeout 1 "$HUB_URL/api/health" >/dev/null 2>&1; then
            echo "Beszel hub is ready"
            break
          fi
          sleep 1
        done

        if ! curl -sf --connect-timeout 1 "$HUB_URL/api/health" >/dev/null 2>&1; then
          echo "ERROR: Beszel hub did not become ready in time" >&2
          exit 1
        fi

        # Try to authenticate with the configured credentials
        # Use -s without -f so curl returns the response body even on HTTP 400/401;
        # errexit would otherwise abort the script before the token check below.
        AUTH_RESPONSE=$(curl -s -X POST "$HUB_URL/api/collections/_superusers/auth-with-password" \
          -H "Content-Type: application/json" \
          -d "{\"identity\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null)

        if [ -z "$AUTH_RESPONSE" ] || [ "$(echo "$AUTH_RESPONSE" | jq -r '.token // empty')" = "" ]; then
          # Auth failed — try to create the first admin account (only works when DB is empty)
          echo "Authentication failed, checking if admin needs to be created..."

          ADMIN_EXISTS=$(curl -sf "$HUB_URL/api/collections/_superusers/records?perPage=1" 2>/dev/null | jq -r '.totalItems // 0')

          if [ "$ADMIN_EXISTS" = "0" ] || [ -z "$ADMIN_EXISTS" ]; then
            echo "Creating Beszel admin account..."
            curl -s -X POST "$HUB_URL/api/collections/_superusers/records" \
              -H "Content-Type: application/json" \
              -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"passwordConfirm\":\"$ADMIN_PASS\"}" >/dev/null 2>&1

            if [ $? -eq 0 ]; then
              echo "Admin account created successfully"
            else
              echo "WARNING: Failed to create admin account" >&2
            fi
          else
            echo "WARNING: Admin account exists but configured credentials do not match." >&2
            echo "To change credentials, delete the PocketBase data directory (e.g. /var/lib/beszel-hub/beszel_data) and restart beszel-hub.service." >&2
            exit 0
          fi

          # Retry authentication after creation
          AUTH_RESPONSE=$(curl -s -X POST "$HUB_URL/api/collections/_superusers/auth-with-password" \
            -H "Content-Type: application/json" \
            -d "{\"identity\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null)
        fi

        if [ -z "$AUTH_RESPONSE" ]; then
          echo "ERROR: Failed to authenticate with Beszel hub." >&2
          exit 1
        fi

        ADMIN_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.token')
        ADMIN_ID=$(echo "$AUTH_RESPONSE" | jq -r '.record.id')

        if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
          echo "ERROR: Failed to get admin token" >&2
          exit 1
        fi

        echo "Authenticated as admin (ID: $ADMIN_ID)"

        # Get the hub's SSH public key and write to agent env file
        echo "Getting hub SSH public key..."
        KEY_RESPONSE=$(curl -sf "$HUB_URL/api/beszel/getkey" \
          -H "Authorization: $ADMIN_TOKEN" 2>/dev/null)

        if [ -z "$KEY_RESPONSE" ]; then
          echo "ERROR: Failed to get hub SSH key" >&2
          exit 1
        fi

        HUB_KEY=$(echo "$KEY_RESPONSE" | jq -r '.key')

        if [ -z "$HUB_KEY" ] || [ "$HUB_KEY" = "null" ]; then
          echo "ERROR: Hub returned invalid key" >&2
          exit 1
        fi

        CURRENT_KEY=""
        if [ -s "$AGENT_ENV" ]; then
          CURRENT_KEY=$(grep "^KEY=" "$AGENT_ENV" | cut -d'=' -f2-)
        fi

        if [ "$CURRENT_KEY" != "$HUB_KEY" ]; then
          echo "Updating agent environment file..."
          printf '%s\n' \
            '# Beszel agent configuration' \
            '# Auto-generated by beszel-init.service' \
            'PORT=45876' \
            "KEY=$HUB_KEY" \
            > "$AGENT_ENV"
          
          chown root:beszel-agent "$AGENT_ENV"
          chmod 640 "$AGENT_ENV"

          echo "Agent key changed, flagging for restart..."
          touch /var/lib/beszel-agent/.restart-needed
        else
          echo "Agent key already up to date"
        fi

        # Update or create the system record for this host
        echo "Checking system record..."
        SYSTEMS=$(curl -sf "$HUB_URL/api/collections/systems/records?filter=name%3D%27media-server%27" \
          -H "Authorization: $ADMIN_TOKEN" 2>/dev/null)

        SYSTEM_COUNT=$(echo "$SYSTEMS" | jq -r '.totalItems // 0')

        if [ "$SYSTEM_COUNT" = "0" ] || [ -z "$SYSTEM_COUNT" ]; then
          echo "Creating system record for media-server..."
          curl -sf -X POST "$HUB_URL/api/collections/systems/records" \
            -H "Authorization: $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"media-server\",\"host\":\"127.0.0.1\",\"port\":45876,\"users\":\"$ADMIN_ID\",\"info\":{},\"status\":\"up\"}" >/dev/null 2>&1

          if [ $? -eq 0 ]; then
            echo "System record created successfully"
          else
            echo "WARNING: Failed to create system record." >&2
          fi
        else
          SYSTEM_ID=$(echo "$SYSTEMS" | jq -r '.items[0].id')
          echo "Updating system record (ID: $SYSTEM_ID)..."
          curl -sf -X PATCH "$HUB_URL/api/collections/systems/records/$SYSTEM_ID" \
            -H "Authorization: $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"host\":\"127.0.0.1\",\"port\":45876,\"users\":\"$ADMIN_ID\"}" >/dev/null 2>&1

          if [ $? -eq 0 ]; then
            echo "System record updated successfully"
          else
            echo "WARNING: Failed to update system record." >&2
          fi
        fi

        echo "Beszel initialization complete"
      '';
    };

    # Separate restart service runs after init finishes, avoiding the deadlock
    # that would occur if init itself tried to restart the agent (which has
    # After=/Requires= on beszel-init).
    systemd.services.beszel-agent-restart = {
      description = "Restart Beszel agent after initialization";
      after = [ "beszel-init.service" ];
      wants = [ "beszel-init.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        if [ -f /var/lib/beszel-agent/.restart-needed ]; then
          echo "Restarting beszel-agent due to key change..."
          systemctl restart beszel-agent.service
          rm -f /var/lib/beszel-agent/.restart-needed
        else
          echo "No beszel-agent restart needed"
        fi
      '';
    };

    # Ensure the agent starts after the init script
    systemd.services.beszel-agent = {
      after = [ "beszel-init.service" ];
      requires = [ "beszel-init.service" ];
      unitConfig = {
        OnFailure = "notify-gotify@%n.service";
      };
    };
  };
}
