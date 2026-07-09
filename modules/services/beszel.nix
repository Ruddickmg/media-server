{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.media-server.beszel;
  inherit (builtins) substring hashString;
  inherit (config.networking) hostName;
  
  # Deterministic admin credentials for Beszel hub, derived from hostname
  beszelAdminPassword = substring 0 32 (hashString "sha256" "${hostName}-beszel-admin");
  beszelAdminEmail = "admin@beszel.local";
  
  # Gotify app name for Beszel notifications
  gotifyAppName = "Beszel Alerts";
in
{
  options.media-server.beszel = {
    enable = lib.mkEnableOption "Beszel monitoring hub and agent";
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
      openFirewall = true;
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

    # Comprehensive automation service that sets up:
    # 1. Beszel admin account (deterministic password)
    # 2. Hub-to-agent SSH key exchange
    # 3. System record creation in the hub
    # 4. Gotify notification integration (if Gotify is enabled)
    systemd.services.beszel-init = {
      description = "Initialize Beszel hub, agent, and notifications";
      after = [ 
        "beszel-hub.service" 
        "beszel-agent.service" 
      ] ++ lib.optional config.services.gotify.enable "gotify.service";
      wants = [ 
        "beszel-hub.service" 
        "beszel-agent.service" 
      ] ++ lib.optional config.services.gotify.enable "gotify.service";
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
        pkgs.openssh 
        pkgs.coreutils 
      ];
      script = ''
        set -uo pipefail
        
        HUB_URL="http://127.0.0.1:8090"
        AGENT_ENV="/var/lib/beszel-agent/env"
        STATE_FILE="/var/lib/beszel-hub/init-state.json"
        GOTIFY_URL="http://127.0.0.1:6789"
        GOTIFY_TOKEN_FILE="/etc/nixos/secrets/gotify-token"
        
        ADMIN_EMAIL="${beszelAdminEmail}"
        ADMIN_PASS="${beszelAdminPassword}"
        
        # Ensure state directory exists
        mkdir -p /var/lib/beszel-hub
        
        # Function to wait for a service to be ready
        wait_for_service() {
          local url="$1"
          local max_wait="$2"
          local name="$3"
          
          if [ -z "$max_wait" ]; then
            max_wait=60
          fi
          
          for i in $(seq 1 "$max_wait"); do
            if curl -sf --connect-timeout 1 "$url" >/dev/null 2>&1; then
              echo "$name is ready"
              return 0
            fi
            sleep 1
          done
          
          echo "ERROR: $name did not become ready in time" >&2
          return 1
        }
        
        # Step 1: Wait for Beszel hub to be ready
        wait_for_service "$HUB_URL/api/health" 60 "Beszel hub" || exit 1
        
        # Step 2: Check if admin account exists and create if needed
        # PocketBase allows creating the first admin without authentication
        # when the database is empty. We check by trying to list superusers.
        
        ADMIN_EXISTS=$(curl -sf "$HUB_URL/api/collections/_superusers/records?perPage=1" 2>/dev/null | jq -r '.totalItems // 0')
        
        if [ "$ADMIN_EXISTS" = "0" ] || [ -z "$ADMIN_EXISTS" ]; then
          echo "Creating Beszel admin account..."
          echo "Admin email: $ADMIN_EMAIL"
          echo "Admin password: $ADMIN_PASS"
          
          # Create the first admin account
          curl -sf -X POST "$HUB_URL/api/collections/_superusers/records" \
            -H "Content-Type: application/json" \
            -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"passwordConfirm\":\"$ADMIN_PASS\"}" >/dev/null 2>&1
            
          if [ $? -ne 0 ]; then
            echo "WARNING: Failed to create admin account. It may already exist or the hub requires a different setup method." >&2
          else
            echo "Admin account created successfully"
          fi
        else
          echo "Admin account already exists"
        fi
        
        # Step 3: Authenticate as admin to get token
        echo "Authenticating with Beszel hub..."
        AUTH_RESPONSE=$(curl -sf -X POST "$HUB_URL/api/collections/_superusers/auth-with-password" \
          -H "Content-Type: application/json" \
          -d "{\"identity\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null)
        
        if [ -z "$AUTH_RESPONSE" ]; then
          echo "ERROR: Failed to authenticate with Beszel hub. The admin account may not exist or the password is incorrect." >&2
          echo "You can manually create an admin at $HUB_URL/_/" >&2
          exit 1
        fi
        
        ADMIN_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.token')
        ADMIN_ID=$(echo "$AUTH_RESPONSE" | jq -r '.record.id')
        
        if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
          echo "ERROR: Failed to get admin token" >&2
          exit 1
        fi
        
        echo "Authenticated as admin (ID: $ADMIN_ID)"
        
        # Step 4: Get the hub's SSH public key
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
        
        echo "Got hub SSH key"
        
        # Step 5: Write the key to the agent environment file
        # Check if the key has changed to avoid unnecessary agent restarts
        CURRENT_KEY=""
        if [ -s "$AGENT_ENV" ]; then
          CURRENT_KEY=$(grep "^KEY=" "$AGENT_ENV" | cut -d'=' -f2-)
        fi
        
        if [ "$CURRENT_KEY" != "$HUB_KEY" ]; then
          echo "Updating agent environment file with hub key..."
          cat > "$AGENT_ENV" <<EOF
        # Beszel agent configuration
        # Auto-generated by beszel-init.service
        # Do not edit manually — changes will be overwritten
        PORT=45876
        KEY=$HUB_KEY
        EOF
          
          chown root:beszel-agent "$AGENT_ENV"
          chmod 640 "$AGENT_ENV"
          
          echo "Agent environment updated. Restarting agent..."
          systemctl restart beszel-agent.service || true
        else
          echo "Agent key already up to date"
        fi
        
        # Step 6: Check if system record exists
        echo "Checking for existing system record..."
        SYSTEMS=$(curl -sf "$HUB_URL/api/collections/systems/records?perPage=1" \
          -H "Authorization: $ADMIN_TOKEN" 2>/dev/null)
        
        SYSTEM_COUNT=$(echo "$SYSTEMS" | jq -r '.totalItems // 0')
        
        if [ "$SYSTEM_COUNT" = "0" ] || [ -z "$SYSTEM_COUNT" ]; then
          echo "Creating system record for media-server..."
          
          # Create the system record for the local agent
          curl -sf -X POST "$HUB_URL/api/collections/systems/records" \
            -H "Authorization: $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"media-server\",\"host\":\"127.0.0.1\",\"port\":45876,\"users\":\"$ADMIN_ID\",\"info\":{},\"status\":\"up\"}" >/dev/null 2>&1
            
          if [ $? -eq 0 ]; then
            echo "System record created successfully"
          else
            echo "WARNING: Failed to create system record. You may need to add it manually via the UI." >&2
          fi
        else
          echo "System record already exists"
        fi
        
        # Step 7: Gotify notification setup (if Gotify is enabled)
        if ${lib.boolToString config.services.gotify.enable}; then
          echo "Gotify is enabled, checking notification setup..."
          
          # Wait for Gotify to be ready
          if ! wait_for_service "$GOTIFY_URL/health" 30 "Gotify"; then
            echo "WARNING: Gotify not ready, skipping notification setup" >&2
          else
            # Check if we already have a token saved
            if [ -s "$GOTIFY_TOKEN_FILE" ]; then
              GOTIFY_TOKEN=$(cat "$GOTIFY_TOKEN_FILE")
              echo "Using existing Gotify token"
            else
              # Login to Gotify with default admin credentials
              echo "Logging into Gotify to create app..."
              GOTIFY_AUTH=$(curl -sf -X POST "$GOTIFY_URL/client" \
                -H "Content-Type: application/json" \
                -d "{\"username\":\"admin\",\"password\":\"admin\"}" 2>/dev/null)
              
              if [ -z "$GOTIFY_AUTH" ]; then
                echo "WARNING: Failed to authenticate with Gotify. Default credentials may have been changed." >&2
                echo "Skipping Gotify notification setup." >&2
                GOTIFY_TOKEN=""
              else
                GOTIFY_CLIENT_TOKEN=$(echo "$GOTIFY_AUTH" | jq -r '.token')
                
                # Create an app for Beszel
                echo "Creating Gotify app for Beszel..."
                APP_RESPONSE=$(curl -sf -X POST "$GOTIFY_URL/application" \
                  -H "Content-Type: application/json" \
                  -H "X-Gotify-Key: $GOTIFY_CLIENT_TOKEN" \
                  -d "{\"name\":\"${gotifyAppName}\",\"description\":\"Server monitoring alerts from Beszel\"}" 2>/dev/null)
                
                if [ -z "$APP_RESPONSE" ]; then
                  echo "WARNING: Failed to create Gotify app" >&2
                  GOTIFY_TOKEN=""
                else
                  GOTIFY_TOKEN=$(echo "$APP_RESPONSE" | jq -r '.token')
                  
                  # Save the token
                  echo "$GOTIFY_TOKEN" | tee "$GOTIFY_TOKEN_FILE" >/dev/null
                  chmod 600 "$GOTIFY_TOKEN_FILE"
                  
                  echo "Gotify app created and token saved to $GOTIFY_TOKEN_FILE"
                fi
              fi
            fi
            
            # If we have a token, configure Beszel notifications
            if [ -n "$GOTIFY_TOKEN" ]; then
              echo "Configuring Beszel notifications..."
              
              # The notification URL format for Shoutrrr/Gotify
              NOTIFICATION_URL="gotify://127.0.0.1:6789/$GOTIFY_TOKEN?priority=1"
              
              # Update the user's settings in PocketBase to include the notification URL
              # Beszel stores notifications in the user_settings collection
              USER_SETTINGS=$(curl -sf "$HUB_URL/api/collections/user_settings/records?filter=user%3D%27$ADMIN_ID%27" \
                -H "Authorization: $ADMIN_TOKEN" 2>/dev/null)
              
              SETTINGS_COUNT=$(echo "$USER_SETTINGS" | jq -r '.totalItems // 0')
              
              if [ "$SETTINGS_COUNT" = "0" ] || [ -z "$SETTINGS_COUNT" ]; then
                # Create new user settings with notification URL
                curl -sf -X POST "$HUB_URL/api/collections/user_settings/records" \
                  -H "Authorization: $ADMIN_TOKEN" \
                  -H "Content-Type: application/json" \
                  -d "{\"user\":\"$ADMIN_ID\",\"settings\":{\"notifications\":{\"email\":[],\"webhook\":[\"$NOTIFICATION_URL\"]}}}" >/dev/null 2>&1
                  
                if [ $? -eq 0 ]; then
                  echo "Beszel notification settings configured"
                else
                  echo "WARNING: Failed to create notification settings. You may need to configure them manually in the UI." >&2
                fi
              else
                # Update existing settings
                SETTINGS_ID=$(echo "$USER_SETTINGS" | jq -r '.items[0].id')
                curl -sf -X PATCH "$HUB_URL/api/collections/user_settings/records/$SETTINGS_ID" \
                  -H "Authorization: $ADMIN_TOKEN" \
                  -H "Content-Type: application/json" \
                  -d "{\"settings\":{\"notifications\":{\"email\":[],\"webhook\":[\"$NOTIFICATION_URL\"]}}}" >/dev/null 2>&1
                  
                if [ $? -eq 0 ]; then
                  echo "Beszel notification settings updated"
                else
                  echo "WARNING: Failed to update notification settings." >&2
                fi
              fi
            fi
          fi
        else
          echo "Gotify is not enabled, skipping notification setup"
        fi
        
        # Save init state
        echo '{"initialized": true, "timestamp": "'$(date -Iseconds)'"}' > "$STATE_FILE"
        chown beszel-hub:beszel-hub "$STATE_FILE"
        
        echo "Beszel initialization complete"
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
