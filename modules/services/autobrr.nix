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
  autobrrApiKeyFile = pkgs.writeText "autobrr-api-key" apiKeys.autobrr;

  postStartScript = pkgs.writeShellScriptBin "autobrr-setup" ''
            set -euo pipefail

            DATA_DIR="${cfg.dataDir}"
            # autobrr serves its API under AUTOBRR__BASE_URL (set below), not at
            # the root path — non-legacy baseUrl mode mounts the API at
            # baseUrl + "api". This must stay in sync with AUTOBRR__BASE_URL.
            API_URL="http://127.0.0.1:${toString cfg.port}/autobrr/api"
            DB="$DATA_DIR/autobrr.db"

            # --- Step 1: ensure API key exists in the database ---
            if [ -f "$DB" ]; then
              KEY=$(cat "${cfg.apiKeyFile}" 2>/dev/null || cat "${autobrrApiKeyFile}" 2>/dev/null || true)
              if [ -n "$KEY" ]; then
                ${pkgs.sqlite}/bin/sqlite3 "$DB" \
                  "INSERT OR IGNORE INTO api_key (name, key, scopes) VALUES ('nixos', '$KEY', '{}');" \
                  2>/dev/null || true
                # Also write to the apiKeyFile for reference
                if [ ! -f "${cfg.apiKeyFile}" ]; then
                  ${pkgs.coreutils}/bin/install -m 600 "${autobrrApiKeyFile}" "${cfg.apiKeyFile}" 2>/dev/null || true
                fi
              fi
            fi

            # --- Step 2: read autobrr API key ---
            API_KEY=$(cat "${cfg.apiKeyFile}" 2>/dev/null || cat "${autobrrApiKeyFile}" 2>/dev/null || true)
            if [ -z "$API_KEY" ]; then
              echo "autobrr-setup: API key not found, skipping"
              exit 0
            fi

            AUTHHeader="X-API-Token: $API_KEY"

            # --- Step 3: wait for autobrr readiness ---
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

            # --- per-\*arr push filters with Lists ---
            # autobrr evaluates only the highest-priority matching filter for a
            # release, so a single catch-all filter is not viable without pushing
            # every announce to every \*arr. Instead each \*arr gets its own filter
            # whose allowed titles are auto-maintained by an autobrr "List": a
            # SONARR/RADARR/LIDARR list queries the \*arr's API for monitored
            # titles and writes them into the linked filter's Shows (or
            # Artists/Albums for Lidarr) fields. Lists refresh on save and every
            # 6 hours (autobrr built-in cron), so a release routes to exactly one
            # \*arr and anything not monitored is ignored. Filters are created
            # first because a list requires at least one linked filter; the list
            # creation then triggers the first title sync.
            ARRS_CLIENTS=$(${pkgs.curl}/bin/curl -sf -H "$AUTHHeader" "$API_URL/download_clients" 2>/dev/null || true)
            get_client_id() {
              printf '%s' "$ARRS_CLIENTS" \
                | ${pkgs.jq}/bin/jq -r ".[] | select(.name == \"$1\") | .id" 2>/dev/null || true
            }
            get_filter_id() {
              ${pkgs.curl}/bin/curl -sf -H "$AUTHHeader" "$API_URL/filters" 2>/dev/null \
                | ${pkgs.jq}/bin/jq -r ".[] | select(.name == \"$1\") | .id" 2>/dev/null || true
            }
            SONARR_ID=$(get_client_id "Sonarr")
            RADARR_ID=$(get_client_id "Radarr")
            LIDARR_ID=$(get_client_id "Lidarr")

            if [ -n "$SONARR_ID" ] && [ -n "$RADARR_ID" ] && [ -n "$LIDARR_ID" ]; then
              # Remove filters created by earlier configs that have since been
              # superseded (the old cross-seed announce forwarder and the interim
              # catch-all "arrs" filter).
              for STALE in "cross-seed" "arrs"; do
                STALE_ID=$(get_filter_id "$STALE")
                if [ -n "$STALE_ID" ]; then
                  ${pkgs.curl}/bin/curl -sf -X DELETE \
                    -H "$AUTHHeader" \
                    "$API_URL/filters/$STALE_ID" >/dev/null 2>&1 \
                    && echo "autobrr-setup: removed superseded '$STALE' filter" || true
                fi
              done

              # --- Sonarr filter + list ---
              SONARR_FILTER_ID=$(get_filter_id "Sonarr")
              if [ -z "$SONARR_FILTER_ID" ]; then
                echo "autobrr-setup: creating Sonarr filter..."
                # The filter table defines resolutions/codecs/sources/containers
                # as NOT NULL TEXT[] columns. Empty arrays make the API insert
                # '{}' (satisfying NOT NULL) — empty means "match any", which
                # is what the arr-driven filters want.
                SONARR_PAYLOAD=$(cat <<SONARR_FILTER_EOF
        {
          "name": "Sonarr",
          "enabled": true,
          "priority": 1000,
          "min_size": "25MB",
          "max_size": "1TB",
          "indexers": [],
          "resolutions": [],
          "codecs": [],
          "sources": [],
          "containers": [],
          "actions": [
            {"name": "Sonarr", "type": "SONARR", "enabled": true, "client_id": $SONARR_ID}
          ]
        }
    SONARR_FILTER_EOF
                )
                ${pkgs.curl}/bin/curl -sf -X POST \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/filters" \
                  -d "$SONARR_PAYLOAD" >/dev/null 2>&1 || true
                SONARR_FILTER_ID=$(get_filter_id "Sonarr")
                echo "autobrr-setup: Sonarr filter id=$SONARR_FILTER_ID"
              fi

              if [ -n "$SONARR_FILTER_ID" ] && ! resource_exists "lists" "Sonarr"; then
                echo "autobrr-setup: creating Sonarr list..."
                # The list table defines headers/tags_included/tags_excluded as
                # NOT NULL TEXT[] columns, same as the filter arrays above.
                SONARR_LIST_PAYLOAD=$(cat <<SONARR_LIST_EOF
        {
          "name": "Sonarr",
          "type": "SONARR",
          "enabled": true,
          "client_id": $SONARR_ID,
          "headers": [],
          "tags_included": [],
          "tags_excluded": [],
          "filters": [{"id": $SONARR_FILTER_ID, "name": "Sonarr"}],
          "match_release": false,
          "include_unmonitored": false,
          "include_alternate_titles": true
        }
    SONARR_LIST_EOF
                )
                ${pkgs.curl}/bin/curl -sf -X POST \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/lists" \
                  -d "$SONARR_LIST_PAYLOAD" >/dev/null 2>&1 \
                  && echo "autobrr-setup: created Sonarr list (title sync triggered)" \
                  || echo "autobrr-setup: failed to create Sonarr list (non-fatal, retried on next boot)"
              fi

              # --- Radarr filter + list ---
              RADARR_FILTER_ID=$(get_filter_id "Radarr")
              if [ -z "$RADARR_FILTER_ID" ]; then
                echo "autobrr-setup: creating Radarr filter..."
                RADARR_PAYLOAD=$(cat <<RADARR_FILTER_EOF
        {
          "name": "Radarr",
          "enabled": true,
          "priority": 1001,
          "min_size": "25MB",
          "max_size": "1TB",
          "indexers": [],
          "resolutions": [],
          "codecs": [],
          "sources": [],
          "containers": [],
          "actions": [
            {"name": "Radarr", "type": "RADARR", "enabled": true, "client_id": $RADARR_ID}
          ]
        }
    RADARR_FILTER_EOF
                )
                ${pkgs.curl}/bin/curl -sf -X POST \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/filters" \
                  -d "$RADARR_PAYLOAD" >/dev/null 2>&1 || true
                RADARR_FILTER_ID=$(get_filter_id "Radarr")
                echo "autobrr-setup: Radarr filter id=$RADARR_FILTER_ID"
              fi

              if [ -n "$RADARR_FILTER_ID" ] && ! resource_exists "lists" "Radarr"; then
                echo "autobrr-setup: creating Radarr list..."
                RADARR_LIST_PAYLOAD=$(cat <<RADARR_LIST_EOF
        {
          "name": "Radarr",
          "type": "RADARR",
          "enabled": true,
          "client_id": $RADARR_ID,
          "headers": [],
          "tags_included": [],
          "tags_excluded": [],
          "filters": [{"id": $RADARR_FILTER_ID, "name": "Radarr"}],
          "match_release": false,
          "include_unmonitored": false,
          "include_alternate_titles": true
        }
    RADARR_LIST_EOF
                )
                ${pkgs.curl}/bin/curl -sf -X POST \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/lists" \
                  -d "$RADARR_LIST_PAYLOAD" >/dev/null 2>&1 \
                  && echo "autobrr-setup: created Radarr list (title sync triggered)" \
                  || echo "autobrr-setup: failed to create Radarr list (non-fatal, retried on next boot)"
              fi

              # --- Lidarr filter + list ---
              LIDARR_FILTER_ID=$(get_filter_id "Lidarr")
              if [ -z "$LIDARR_FILTER_ID" ]; then
                echo "autobrr-setup: creating Lidarr filter..."
                LIDARR_PAYLOAD=$(cat <<LIDARR_FILTER_EOF
        {
          "name": "Lidarr",
          "enabled": true,
          "priority": 1002,
          "min_size": "25MB",
          "max_size": "1TB",
          "indexers": [],
          "resolutions": [],
          "codecs": [],
          "sources": [],
          "containers": [],
          "actions": [
            {"name": "Lidarr", "type": "LIDARR", "enabled": true, "client_id": $LIDARR_ID}
          ]
        }
    LIDARR_FILTER_EOF
                )
                ${pkgs.curl}/bin/curl -sf -X POST \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/filters" \
                  -d "$LIDARR_PAYLOAD" >/dev/null 2>&1 || true
                LIDARR_FILTER_ID=$(get_filter_id "Lidarr")
                echo "autobrr-setup: Lidarr filter id=$LIDARR_FILTER_ID"
              fi

              if [ -n "$LIDARR_FILTER_ID" ] && ! resource_exists "lists" "Lidarr"; then
                echo "autobrr-setup: creating Lidarr list..."
                LIDARR_LIST_PAYLOAD=$(cat <<LIDARR_LIST_EOF
        {
          "name": "Lidarr",
          "type": "LIDARR",
          "enabled": true,
          "client_id": $LIDARR_ID,
          "headers": [],
          "tags_included": [],
          "tags_excluded": [],
          "filters": [{"id": $LIDARR_FILTER_ID, "name": "Lidarr"}],
          "match_release": false,
          "include_unmonitored": false
        }
    LIDARR_LIST_EOF
                )
                ${pkgs.curl}/bin/curl -sf -X POST \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/lists" \
                  -d "$LIDARR_LIST_PAYLOAD" >/dev/null 2>&1 \
                  && echo "autobrr-setup: created Lidarr list (title sync triggered)" \
                  || echo "autobrr-setup: failed to create Lidarr list (non-fatal, retried on next boot)"
              fi

              # Lists created on an earlier boot may have failed their first sync
              # if the \*arr wasn't reachable yet; refresh now so every filter gets
              # its monitored-titles list populated.
              ${pkgs.curl}/bin/curl -sf -X POST \
                -H "$AUTHHeader" \
                "$API_URL/lists/refresh" >/dev/null 2>&1 \
                && echo "autobrr-setup: refreshed lists" \
                || echo "autobrr-setup: list refresh failed (non-fatal)"
            else
              echo "autobrr-setup: download clients not found, skipping \*arr filters"
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
      default = "/var/lib/autobrr/apiKey";
      description = "Path to file containing the autobrr API key";
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
        sqlite
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
