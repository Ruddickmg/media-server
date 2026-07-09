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

        # Check if this is a fresh install (no users exist yet)
        FIRST_RUN=$(curl -s "$HUB_URL/api/beszel/first-run" 2>/dev/null | jq -r '.firstRun // false')

        if [ "$FIRST_RUN" = "true" ]; then
          echo "First run detected — creating initial user..."
          CREATE_RESPONSE=$(curl -s -X POST "$HUB_URL/api/beszel/create-user" \
            -H "Content-Type: application/json" \
            -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null)

          CREATE_MSG=$(echo "$CREATE_RESPONSE" | jq -r '.msg // empty')

          if [ "$CREATE_MSG" = "User created" ]; then
            echo "Initial user created successfully"
          else
            CREATE_ERR=$(echo "$CREATE_RESPONSE" | jq -r '.err // "unknown error"')
            echo "WARNING: Failed to create initial user: $CREATE_ERR" >&2
            echo "Verify the hub data is clean (/var/lib/beszel-hub/beszel_data) and restart beszel-hub.service." >&2
            exit 0
          fi
        else
          echo "User already exists — attempting authentication..."
        fi

        # Authenticate as a Beszel user (users collection, not _superusers)
        AUTH_RESPONSE=$(curl -s -X POST "$HUB_URL/api/collections/users/auth-with-password" \
          -H "Content-Type: application/json" \
          -d "{\"identity\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null)

        USER_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.token // empty')
        USER_ID=$(echo "$AUTH_RESPONSE" | jq -r '.record.id // empty')

        if [ -z "$USER_TOKEN" ]; then
          echo "ERROR: Failed to authenticate as user $ADMIN_EMAIL" >&2
          echo "Verify credentials or reset by deleting /var/lib/beszel-hub/beszel_data and restarting beszel-hub.service." >&2
          exit 1
        fi

        echo "Authenticated as user (ID: $USER_ID)"

        # Get the hub's SSH public key
        echo "Getting hub SSH public key..."
        KEY_RESPONSE=$(curl -s "$HUB_URL/api/beszel/getkey" \
          -H "Authorization: $USER_TOKEN" 2>/dev/null)

        HUB_KEY=$(echo "$KEY_RESPONSE" | jq -r '.key // empty')

        if [ -z "$HUB_KEY" ]; then
          echo "ERROR: Failed to get hub SSH key" >&2
          exit 1
        fi

        # Write env file if key changed
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
        else
          echo "Agent key already up to date"
        fi

        # Update or create the system record for this host
        echo "Checking system record..."
        SYSTEMS=$(curl -s "$HUB_URL/api/collections/systems/records?filter=name%3D%27media-server%27" \
          -H "Authorization: $USER_TOKEN" 2>/dev/null)

        SYSTEM_COUNT=$(echo "$SYSTEMS" | jq -r '.totalItems // 0')

        if [ "$SYSTEM_COUNT" = "0" ]; then
          echo "Creating system record for media-server..."
          curl -s -X POST "$HUB_URL/api/collections/systems/records" \
            -H "Authorization: $USER_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"media-server\",\"host\":\"127.0.0.1\",\"port\":45876,\"users\":\"$USER_ID\",\"info\":{},\"status\":\"up\"}" >/dev/null 2>&1
          echo "System record created"
        else
          SYSTEM_ID=$(echo "$SYSTEMS" | jq -r '.items[0].id')
          echo "Updating system record (ID: $SYSTEM_ID)..."
          curl -s -X PATCH "$HUB_URL/api/collections/systems/records/$SYSTEM_ID" \
            -H "Authorization: $USER_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"host\":\"127.0.0.1\",\"port\":45876,\"users\":\"$USER_ID\"}" >/dev/null 2>&1
          echo "System record updated"
        fi

        echo "Beszel initialization complete"
      '';
    };

    # Keep failure notifications for the agent without adding ordering
    # dependencies that would re-create the cycle with beszel-init.
    systemd.services.beszel-agent = {
      unitConfig = {
        ConditionPathExists = "/var/lib/beszel-agent/env";
        OnFailure = "notify-gotify@%n.service";
      };
    };

    # Starts the agent after init writes the env file (agent is skipped on first
    # boot by ConditionPathExists). Harmless restart on subsequent boots.
    systemd.services.beszel-agent-restart = {
      description = "Restart Beszel agent after initialization";
      after = [ "beszel-init.service" ];
      wants = [ "beszel-init.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        systemctl restart beszel-agent.service
      '';
    };

  };
}
