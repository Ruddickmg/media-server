{
  lib,
  pkgs,
  config,
  pkgs-unstable,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.media-server.autobrr;
  apiKeys = config.media-server.apiKeys;

  postStartScript = pkgs.writeShellScriptBin "autobrr-setup" ''
        set -euo pipefail

        API_URL="http://127.0.0.1:${toString cfg.port}/api"

        # --- read autobrr API key ---
        if [ ! -f "${cfg.apiKeyFile}" ]; then
          echo "autobrr-setup: API key file not found at ${cfg.apiKeyFile}, skipping"
          exit 0
        fi
        API_KEY=$(cat "${cfg.apiKeyFile}" 2>/dev/null || true)
        if [ -z "$API_KEY" ]; then
          echo "autobrr-setup: API key is empty, skipping"
          exit 0
        fi

        AUTHHeader="X-API-Token: $API_KEY"

        # --- wait for autobrr readiness ---
        echo "autobrr-setup: waiting for autobrr to be ready..."
        for i in $(seq 1 30); do
          if ${pkgs.curl}/bin/curl -sf "$API_URL/healthz/readiness" >/dev/null 2>&1; then
            echo "autobrr-setup: autobrr is ready"
            break
          fi
          if [ "$i" -eq 30 ]; then
            echo "autobrr-setup: autobrr not ready after 30 s, skipping"
            exit 0
          fi
          sleep 1
        done

        # --- helper: check if a named resource exists ---
        resource_exists() {
          local endpoint="$1" name="$2"
          ${pkgs.curl}/bin/curl -sf \
            -H "$AUTHHeader" \
            "$API_URL/$endpoint" 2>/dev/null \
            | ${pkgs.jq}/bin/jq -e ".[] | select(.name == \"$name\")" >/dev/null 2>&1
        }

        # --- Sonarr target ---
        if ! resource_exists "download_clients" "Sonarr"; then
          echo "autobrr-setup: creating Sonarr target..."
          ${pkgs.curl}/bin/curl -sf -X POST \
            -H "$AUTHHeader" \
            -H "Content-Type: application/json" \
            "$API_URL/download_clients" \
            -d '${
              builtins.toJSON {
                name = "Sonarr";
                type = "SONARR";
                enabled = true;
                host = "http://127.0.0.1:8989/sonarr";
                settings = {
                  apikey = apiKeys.sonarr;
                  basic = { };
                  external_download_client_id = 0;
                };
              }
            }' >/dev/null 2>&1 \
            && echo "autobrr-setup: created Sonarr target" \
            || echo "autobrr-setup: failed to create Sonarr target (non-fatal)"
        fi

        # --- Radarr target ---
        if ! resource_exists "download_clients" "Radarr"; then
          echo "autobrr-setup: creating Radarr target..."
          ${pkgs.curl}/bin/curl -sf -X POST \
            -H "$AUTHHeader" \
            -H "Content-Type: application/json" \
            "$API_URL/download_clients" \
            -d '${
              builtins.toJSON {
                name = "Radarr";
                type = "RADARR";
                enabled = true;
                host = "http://127.0.0.1:7878/radarr";
                settings = {
                  apikey = apiKeys.radarr;
                  basic = { };
                  external_download_client_id = 0;
                };
              }
            }' >/dev/null 2>&1 \
            && echo "autobrr-setup: created Radarr target" \
            || echo "autobrr-setup: failed to create Radarr target (non-fatal)"
        fi

        # --- Lidarr target ---
        if ! resource_exists "download_clients" "Lidarr"; then
          echo "autobrr-setup: creating Lidarr target..."
          ${pkgs.curl}/bin/curl -sf -X POST \
            -H "$AUTHHeader" \
            -H "Content-Type: application/json" \
            "$API_URL/download_clients" \
            -d '${
              builtins.toJSON {
                name = "Lidarr";
                type = "LIDARR";
                enabled = true;
                host = "http://127.0.0.1:8686/lidarr";
                settings = {
                  apikey = apiKeys.lidarr;
                  basic = { };
                  external_download_client_id = 0;
                };
              }
            }' >/dev/null 2>&1 \
            && echo "autobrr-setup: created Lidarr target" \
            || echo "autobrr-setup: failed to create Lidarr target (non-fatal)"
        fi

        # --- cross-seed announce filter ---
        if ! resource_exists "filters" "cross-seed"; then
          # Read cross-seed API key — auto-generated, stored in the cross-seed data dir.
          CROSS_SEED_KEY=""
          if [ -f "${cfg.crossSeedApiKeyFile}" ]; then
            CROSS_SEED_KEY=$(cat "${cfg.crossSeedApiKeyFile}" 2>/dev/null || true)
          fi
          if [ -n "$CROSS_SEED_KEY" ]; then
            echo "autobrr-setup: creating cross-seed announce filter..."
            CROSS_SEED_PAYLOAD=$(cat <<CSEED_EOF
    {
      "name": "cross-seed",
      "enabled": true,
      "priority": 1000,
      "indexers": [],
      "actions": [{"name": "test", "type": "TEST", "enabled": true}],
      "external": [{
        "name": "cross-seed",
        "type": "WEBHOOK",
        "enabled": true,
        "webhook_host": "http://127.0.0.1:2468/api/announce?apikey=$CROSS_SEED_KEY",
        "webhook_method": "POST",
        "webhook_data": "{\"name\":{{ toRawJson .TorrentName }},\"guid\":\"{{ .TorrentUrl }}\",\"link\":\"{{ .TorrentUrl }}\",\"tracker\":{{ toRawJson .IndexerName }}}",
        "webhook_expect_status": 200,
        "webhook_retry_max_retries": 100,
        "webhook_retry_interval_seconds": 900,
        "webhook_retry_statuses": [202]
      }]
    }
    CSEED_EOF
            )
            ${pkgs.curl}/bin/curl -sf -X POST \
              -H "$AUTHHeader" \
              -H "Content-Type: application/json" \
              "$API_URL/filters" \
              -d "$CROSS_SEED_PAYLOAD" >/dev/null 2>&1 \
              && echo "autobrr-setup: created cross-seed announce filter" \
              || echo "autobrr-setup: failed to create cross-seed filter (non-fatal)"
          else
            echo "autobrr-setup: cross-seed API key not found at ${cfg.crossSeedApiKeyFile}, skipping filter"
          fi
        fi

        # --- Gotify notification agent ---
        if [ -f "${cfg.gotifyTokenFile}" ]; then
          GOTIFY_TOKEN=$(cat "${cfg.gotifyTokenFile}" 2>/dev/null || true)
          if [ -n "$GOTIFY_TOKEN" ] && ! resource_exists "notification" "Gotify"; then
            echo "autobrr-setup: creating Gotify notification agent..."
            GOTIFY_PAYLOAD=$(cat <<GOTIFY_EOF
    {
      "enabled": true,
      "type": "GOTIFY",
      "name": "Gotify",
      "events": ["PUSH_APPROVED", "PUSH_ERROR"],
      "host": "http://127.0.0.1:6789",
      "token": "$GOTIFY_TOKEN"
    }
    GOTIFY_EOF
            )
            ${pkgs.curl}/bin/curl -sf -X POST \
              -H "$AUTHHeader" \
              -H "Content-Type: application/json" \
              "$API_URL/notification" \
              -d "$GOTIFY_PAYLOAD" >/dev/null 2>&1 \
              && echo "autobrr-setup: created Gotify notification agent" \
              || echo "autobrr-setup: failed to create Gotify agent (non-fatal)"
          fi
        fi

        echo "autobrr-setup: done"
  '';
in
{
  options.media-server.autobrr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable autobrr IRC announce-based release automation";
    };
    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/autobrr";
      description = "Data directory for autobrr";
    };
    port = mkOption {
      type = types.port;
      default = 7474;
      description = "Web UI listen port";
    };
    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Listen address";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open port in firewall for autobrr web UI";
    };
    apiKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing the autobrr API key";
    };
    crossSeedApiKeyFile = mkOption {
      type = types.path;
      default = "/var/lib/cross-seed/apiKey";
      description = "Path to cross-seed API key file (auto-generated by cross-seed)";
    };
    gotifyTokenFile = mkOption {
      type = types.path;
      default = "/etc/nixos/secrets/gotify-token";
      description = "Path to Gotify application token file";
    };
  };

  config = mkIf cfg.enable {
    users.users.autobrr = {
      group = "autobrr";
      description = "autobrr service user";
      isSystemUser = true;
      home = cfg.dataDir;
    };

    users.groups.autobrr = { };

    systemd.tmpfiles.settings."10-autobrr" = {
      "${cfg.dataDir}".d = {
        user = "autobrr";
        group = "autobrr";
        mode = "700";
      };
      # Ensure secret files are readable by the autobrr group.
      # Rules only apply to existing files — create them after first boot.
      "${cfg.apiKeyFile}".z = {
        mode = "0640";
        group = "autobrr";
      };
      "${cfg.crossSeedApiKeyFile}".z = {
        mode = "0640";
        group = "autobrr";
      };
      "${cfg.gotifyTokenFile}".z = {
        mode = "0640";
        group = "autobrr";
      };
    };

    systemd.services.autobrr = {
      description = "autobrr - IRC announce-based release automation";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        AUTOBRR__HOST = cfg.listenAddress;
        AUTOBRR__PORT = toString cfg.port;
        AUTOBRR__BASE_URL = "/autobrr/";
        AUTOBRR__BASE_URL_MODE_LEGACY = "false";
        AUTOBRR__LOG_LEVEL = "INFO";
        AUTOBRR__LOG_PATH = "stdout";
      };

      preStart = ''
        # Create session secret if it doesn't exist
        if [ ! -f "${cfg.dataDir}/session.secret" ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "${cfg.dataDir}/session.secret"
          chown autobrr:autobrr "${cfg.dataDir}/session.secret"
          chmod 600 "${cfg.dataDir}/session.secret"
        fi
      '';

      path = with pkgs; [
        curl
        jq
      ];

      postStart = "${postStartScript}/bin/autobrr-setup";

      serviceConfig = {
        Type = "simple";
        User = "autobrr";
        Group = "autobrr";
        ExecStart = "${pkgs-unstable.autobrr}/bin/autobrr --config=${cfg.dataDir}";
        Restart = "on-failure";
        RestartSec = "10s";
        StateDirectory = "autobrr";
        StateDirectoryMode = "0750";
        ReadWritePaths = [ cfg.dataDir ];

        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        PrivateDevices = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectSystem = "strict";
        MemoryDenyWriteExecute = true;
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
      };

      unitConfig = {
        StartLimitBurst = 10;
        OnFailure = "notify-gotify@%n.service";
      };
    };

    environment.systemPackages = [
      pkgs-unstable.autobrr
      postStartScript
    ];

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
    };
  };
}
