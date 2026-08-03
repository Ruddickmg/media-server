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

            # --- Step 4: \*arr -> autobrr webhook notifications ---
            # autobrr's lists only refresh on boot and on a built-in 6 h cron,
            # so a series/movie/artist added after the last refresh stayed
            # invisible to autobrr until the next run — the missed-episode
            # failure mode. Each \*arr therefore gets a Webhook notification
            # that POSTs to autobrr's list-trigger endpoint the moment media is
            # added or removed, refreshing the arr lists within seconds. The
            # token travels in an X-API-Token header (the endpoint sits behind
            # the same auth as the rest of the API). forceSave skips the
            # connection test so a briefly-unavailable autobrr doesn't block
            # creation; retries for a bit in case an \*arr is still starting.
            ARR_WEBHOOK_URL="$API_URL/webhook/lists/trigger/arr"

            SONARR_WEBHOOK_PAYLOAD=$(cat <<WEBHOOK_SONARR_EOF
        {
          "name": "autobrr",
          "implementation": "Webhook",
          "configContract": "WebhookSettings",
          "tags": [],
          "onSeriesAdd": true,
          "onSeriesDelete": true,
          "fields": [
            {"name": "url", "value": "$ARR_WEBHOOK_URL"},
            {"name": "method", "value": 1},
            {"name": "username", "value": ""},
            {"name": "password", "value": ""},
            {"name": "headers", "value": [{"key": "X-API-Token", "value": "$API_KEY"}]}
          ]
        }
    WEBHOOK_SONARR_EOF
            )
            RADARR_WEBHOOK_PAYLOAD=$(cat <<WEBHOOK_RADARR_EOF
        {
          "name": "autobrr",
          "implementation": "Webhook",
          "configContract": "WebhookSettings",
          "tags": [],
          "onMovieAdded": true,
          "onMovieDelete": true,
          "fields": [
            {"name": "url", "value": "$ARR_WEBHOOK_URL"},
            {"name": "method", "value": 1},
            {"name": "username", "value": ""},
            {"name": "password", "value": ""},
            {"name": "headers", "value": [{"key": "X-API-Token", "value": "$API_KEY"}]}
          ]
        }
    WEBHOOK_RADARR_EOF
            )
            LIDARR_WEBHOOK_PAYLOAD=$(cat <<WEBHOOK_LIDARR_EOF
        {
          "name": "autobrr",
          "implementation": "Webhook",
          "configContract": "WebhookSettings",
          "tags": [],
          "onArtistAdd": true,
          "onArtistDelete": true,
          "fields": [
            {"name": "url", "value": "$ARR_WEBHOOK_URL"},
            {"name": "method", "value": 1},
            {"name": "username", "value": ""},
            {"name": "password", "value": ""},
            {"name": "headers", "value": [{"key": "X-API-Token", "value": "$API_KEY"}]}
          ]
        }
    WEBHOOK_LIDARR_EOF
            )

            create_arr_webhook() {
              local arr_name="$1" api_base="$2" api_key="$3" payload="$4"
              if ${pkgs.curl}/bin/curl -sf -H "X-Api-Key: $api_key" "$api_base/notification" 2>/dev/null \
                  | ${pkgs.jq}/bin/jq -e ".[] | select(.name == \"autobrr\")" >/dev/null 2>&1; then
                echo "autobrr-setup: $arr_name webhook notification already exists"
                return 0
              fi
              echo "autobrr-setup: creating $arr_name webhook notification..."
              if ${pkgs.curl}/bin/curl -sf -X POST \
                  -H "X-Api-Key: $api_key" \
                  -H "Content-Type: application/json" \
                  "$api_base/notification?forceSave=true" \
                  -d "$payload" >/dev/null 2>&1; then
                echo "autobrr-setup: created $arr_name webhook notification"
                return 0
              fi
              echo "autobrr-setup: failed to create $arr_name webhook notification (non-fatal)"
              return 1
            }

            for _ in 1 2 3 4 5 6; do
              ALL_WEBHOOKS=1
              create_arr_webhook "Sonarr" "http://127.0.0.1:8989/sonarr/api/v3" "${apiKeys.sonarr}" "$SONARR_WEBHOOK_PAYLOAD" || ALL_WEBHOOKS=0
              create_arr_webhook "Radarr" "http://127.0.0.1:7878/radarr/api/v3" "${apiKeys.radarr}" "$RADARR_WEBHOOK_PAYLOAD" || ALL_WEBHOOKS=0
              create_arr_webhook "Lidarr" "http://127.0.0.1:8686/lidarr/api/v1" "${apiKeys.lidarr}" "$LIDARR_WEBHOOK_PAYLOAD" || ALL_WEBHOOKS=0
              if [ "$ALL_WEBHOOKS" = "1" ]; then
                break
              fi
              sleep 5
            done

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

            # --- per-\*arr push filters, lists and fallbacks ---
            # Each \*arr gets a title filter (priority 1000-1002) whose allowed
            # titles are auto-maintained by an autobrr "List": a SONARR/RADARR/
            # LIDARR list queries the \*arr API for monitored titles and writes
            # them into the linked filter's Shows/Match-releases fields. Lists
            # refresh on save, on the built-in 6 h cron, and on every boot.
            #
            # Title-based routing alone missed releases: a title added after the
            # last refresh, or announced under a name that differs from the list
            # entry, matched no filter and was dropped. Three layers fix this:
            #   1. \*arr -> autobrr webhooks (created above) refresh the arr
            #      lists within seconds of media being added or removed.
            #   2. match_release: true (below) writes monitored titles to the
            #      filter's substring-matching "Match releases" field instead of
            #      the exact-title "Shows" field.
            #   3. low-priority fallback filters (created at the end of this
            #      block) catch anything still unmatched: category-based routing
            #      (TV* -> Sonarr, Movie* -> Radarr, audio -> Lidarr) and finally
            #      a catch-all that offers the release to every \*arr, which
            #      rejects what it does not want.
            # autobrr evaluates filters by priority, stops once a \*arr approves,
            # and never re-tries an action client it already rejected for the
            # same release, so the fallbacks cannot double-push.
            #
            # The autobrr API only persists a filter's indexers and actions via
            # PUT /filters/{id}; POST /filters stores just the bare filter row.
            # Filters are therefore created bare with POST and the full payload
            # (indexers + actions) is reconciled with PUT on every boot.
            ARRS_CLIENTS=$(${pkgs.curl}/bin/curl -sf -H "$AUTHHeader" "$API_URL/download_clients" 2>/dev/null || true)
            # A filter's "indexers" field must list every enabled indexer to act
            # as the UI's "All" selection; an empty array links the filter to NO
            # indexer (IRC matching INNER JOINs filter_indexer, so zero rows mean
            # the filter never fires). Retry briefly in case autobrr is still
            # registering the IRC-backed indexers on first boot.
            ARRS_INDEXERS='[]'
            for _ in 1 2 3 4 5; do
              ARRS_INDEXERS=$(${pkgs.curl}/bin/curl -sf -H "$AUTHHeader" "$API_URL/indexers" 2>/dev/null \
                | ${pkgs.jq}/bin/jq -c '[.[] | select(.enabled == true) | {id, name}]' 2>/dev/null || true)
              if [ -z "$ARRS_INDEXERS" ]; then
                ARRS_INDEXERS='[]'
              fi
              if [ "$ARRS_INDEXERS" != "[]" ]; then
                break
              fi
              sleep 5
            done
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
                ${pkgs.curl}/bin/curl -sf -X POST \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/filters" \
                  -d '{"name":"Sonarr","enabled":true}' >/dev/null 2>&1 || true
                SONARR_FILTER_ID=$(get_filter_id "Sonarr")
              fi
              if [ -n "$SONARR_FILTER_ID" ] && [ "$ARRS_INDEXERS" != "[]" ]; then
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
          "indexers": $ARRS_INDEXERS,
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
                ${pkgs.curl}/bin/curl -sf -X PUT \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/filters/$SONARR_FILTER_ID" \
                  -d "$SONARR_PAYLOAD" >/dev/null 2>&1 \
                  && echo "autobrr-setup: reconciled Sonarr filter id=$SONARR_FILTER_ID" \
                  || echo "autobrr-setup: failed to reconcile Sonarr filter (non-fatal, retried next boot)"
              fi

              if [ -n "$SONARR_FILTER_ID" ]; then
                # The list table defines headers/tags_included/tags_excluded as
                # NOT NULL TEXT[] columns, same as the filter arrays above.
                # match_release: true writes titles into the filter's "Match
                # releases" (substring) field instead of "Shows" (exact title),
                # so release names that differ from the clean title still match.
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
          "match_release": true,
          "include_unmonitored": false,
          "include_alternate_titles": true
        }
    SONARR_LIST_EOF
                )
                # Create-or-update: lists created on earlier boots still carry the
                # old settings (e.g. match_release=false), so every boot PUTs the
                # full payload instead of only creating when missing.
                SONARR_LIST_ID=$(${pkgs.curl}/bin/curl -sf -H "$AUTHHeader" "$API_URL/lists" 2>/dev/null \
                  | ${pkgs.jq}/bin/jq -r '.[] | select(.name == "Sonarr") | .id' 2>/dev/null || true)
                if [ -z "$SONARR_LIST_ID" ]; then
                  echo "autobrr-setup: creating Sonarr list..."
                  ${pkgs.curl}/bin/curl -sf -X POST \
                    -H "$AUTHHeader" \
                    -H "Content-Type: application/json" \
                    "$API_URL/lists" \
                    -d "$SONARR_LIST_PAYLOAD" >/dev/null 2>&1 \
                    && echo "autobrr-setup: created Sonarr list (title sync triggered)" \
                    || echo "autobrr-setup: failed to create Sonarr list (non-fatal, retried on next boot)"
                else
                  echo "autobrr-setup: reconciling Sonarr list..."
                  ${pkgs.curl}/bin/curl -sf -X PUT \
                    -H "$AUTHHeader" \
                    -H "Content-Type: application/json" \
                    "$API_URL/lists/$SONARR_LIST_ID" \
                    -d "$SONARR_LIST_PAYLOAD" >/dev/null 2>&1 \
                    && echo "autobrr-setup: reconciled Sonarr list" \
                    || echo "autobrr-setup: failed to reconcile Sonarr list (non-fatal, retried on next boot)"
                fi
              fi

              # --- Radarr filter + list ---
              RADARR_FILTER_ID=$(get_filter_id "Radarr")
              if [ -z "$RADARR_FILTER_ID" ]; then
                echo "autobrr-setup: creating Radarr filter..."
                ${pkgs.curl}/bin/curl -sf -X POST \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/filters" \
                  -d '{"name":"Radarr","enabled":true}' >/dev/null 2>&1 || true
                RADARR_FILTER_ID=$(get_filter_id "Radarr")
              fi
              if [ -n "$RADARR_FILTER_ID" ] && [ "$ARRS_INDEXERS" != "[]" ]; then
                RADARR_PAYLOAD=$(cat <<RADARR_FILTER_EOF
        {
          "name": "Radarr",
          "enabled": true,
          "priority": 1001,
          "min_size": "25MB",
          "max_size": "1TB",
          "indexers": $ARRS_INDEXERS,
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
                ${pkgs.curl}/bin/curl -sf -X PUT \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/filters/$RADARR_FILTER_ID" \
                  -d "$RADARR_PAYLOAD" >/dev/null 2>&1 \
                  && echo "autobrr-setup: reconciled Radarr filter id=$RADARR_FILTER_ID" \
                  || echo "autobrr-setup: failed to reconcile Radarr filter (non-fatal, retried next boot)"
              fi

              if [ -n "$RADARR_FILTER_ID" ]; then
                # See the Sonarr list block: match_release: true writes titles to
                # the substring-matching "Match releases" filter field.
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
          "match_release": true,
          "include_unmonitored": false,
          "include_alternate_titles": true
        }
    RADARR_LIST_EOF
                )
                # Create-or-update so lists from earlier boots get the current
                # settings (match_release=true) applied.
                RADARR_LIST_ID=$(${pkgs.curl}/bin/curl -sf -H "$AUTHHeader" "$API_URL/lists" 2>/dev/null \
                  | ${pkgs.jq}/bin/jq -r '.[] | select(.name == "Radarr") | .id' 2>/dev/null || true)
                if [ -z "$RADARR_LIST_ID" ]; then
                  echo "autobrr-setup: creating Radarr list..."
                  ${pkgs.curl}/bin/curl -sf -X POST \
                    -H "$AUTHHeader" \
                    -H "Content-Type: application/json" \
                    "$API_URL/lists" \
                    -d "$RADARR_LIST_PAYLOAD" >/dev/null 2>&1 \
                    && echo "autobrr-setup: created Radarr list (title sync triggered)" \
                    || echo "autobrr-setup: failed to create Radarr list (non-fatal, retried on next boot)"
                else
                  echo "autobrr-setup: reconciling Radarr list..."
                  ${pkgs.curl}/bin/curl -sf -X PUT \
                    -H "$AUTHHeader" \
                    -H "Content-Type: application/json" \
                    "$API_URL/lists/$RADARR_LIST_ID" \
                    -d "$RADARR_LIST_PAYLOAD" >/dev/null 2>&1 \
                    && echo "autobrr-setup: reconciled Radarr list" \
                    || echo "autobrr-setup: failed to reconcile Radarr list (non-fatal, retried on next boot)"
                fi
              fi

              # --- Lidarr filter + list ---
              LIDARR_FILTER_ID=$(get_filter_id "Lidarr")
              if [ -z "$LIDARR_FILTER_ID" ]; then
                echo "autobrr-setup: creating Lidarr filter..."
                ${pkgs.curl}/bin/curl -sf -X POST \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/filters" \
                  -d '{"name":"Lidarr","enabled":true}' >/dev/null 2>&1 || true
                LIDARR_FILTER_ID=$(get_filter_id "Lidarr")
              fi
              if [ -n "$LIDARR_FILTER_ID" ] && [ "$ARRS_INDEXERS" != "[]" ]; then
                LIDARR_PAYLOAD=$(cat <<LIDARR_FILTER_EOF
        {
          "name": "Lidarr",
          "enabled": true,
          "priority": 1002,
          "min_size": "25MB",
          "max_size": "1TB",
          "indexers": $ARRS_INDEXERS,
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
                ${pkgs.curl}/bin/curl -sf -X PUT \
                  -H "$AUTHHeader" \
                  -H "Content-Type: application/json" \
                  "$API_URL/filters/$LIDARR_FILTER_ID" \
                  -d "$LIDARR_PAYLOAD" >/dev/null 2>&1 \
                  && echo "autobrr-setup: reconciled Lidarr filter id=$LIDARR_FILTER_ID" \
                  || echo "autobrr-setup: failed to reconcile Lidarr filter (non-fatal, retried next boot)"
              fi

              if [ -n "$LIDARR_FILTER_ID" ]; then
                # See the Sonarr list block: match_release: true writes titles to
                # the substring-matching "Match releases" filter field.
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
          "match_release": true,
          "include_unmonitored": false
        }
    LIDARR_LIST_EOF
                )
                # Create-or-update so lists from earlier boots get the current
                # settings (match_release=true) applied.
                LIDARR_LIST_ID=$(${pkgs.curl}/bin/curl -sf -H "$AUTHHeader" "$API_URL/lists" 2>/dev/null \
                  | ${pkgs.jq}/bin/jq -r '.[] | select(.name == "Lidarr") | .id' 2>/dev/null || true)
                if [ -z "$LIDARR_LIST_ID" ]; then
                  echo "autobrr-setup: creating Lidarr list..."
                  ${pkgs.curl}/bin/curl -sf -X POST \
                    -H "$AUTHHeader" \
                    -H "Content-Type: application/json" \
                    "$API_URL/lists" \
                    -d "$LIDARR_LIST_PAYLOAD" >/dev/null 2>&1 \
                    && echo "autobrr-setup: created Lidarr list (title sync triggered)" \
                    || echo "autobrr-setup: failed to create Lidarr list (non-fatal, retried on next boot)"
                else
                  echo "autobrr-setup: reconciling Lidarr list..."
                  ${pkgs.curl}/bin/curl -sf -X PUT \
                    -H "$AUTHHeader" \
                    -H "Content-Type: application/json" \
                    "$API_URL/lists/$LIDARR_LIST_ID" \
                    -d "$LIDARR_LIST_PAYLOAD" >/dev/null 2>&1 \
                    && echo "autobrr-setup: reconciled Lidarr list" \
                    || echo "autobrr-setup: failed to reconcile Lidarr list (non-fatal, retried on next boot)"
                fi
              fi

              # Lists created on an earlier boot may have failed their first sync
              # if the \*arr wasn't reachable yet; refresh now so every filter gets
              # its monitored-titles list populated.
              ${pkgs.curl}/bin/curl -sf -X POST \
                -H "$AUTHHeader" \
                "$API_URL/lists/refresh" >/dev/null 2>&1 \
                && echo "autobrr-setup: refreshed lists" \
                || echo "autobrr-setup: list refresh failed (non-fatal)"

              # --- layered fallback filters ---
              # A release can still miss every title filter (title added after
              # the last refresh, or announced under a name the list never saw).
              # Instead of dropping it, fall back by category and finally to a
              # catch-all that offers the release to every \*arr, which rejects
              # what it does not want. Priorities keep title matching first;
              # autobrr skips an action client already tried for the same
              # release, so a fallback never double-pushes to one \*arr.
              reconcile_filter() {
                local name="$1" priority="$2" categories="$3" actions_json="$4"
                local fid
                fid=$(get_filter_id "$name")
                if [ -z "$fid" ]; then
                  ${pkgs.curl}/bin/curl -sf -X POST \
                    -H "$AUTHHeader" \
                    -H "Content-Type: application/json" \
                    "$API_URL/filters" \
                    -d "{\"name\":\"$name\",\"enabled\":true}" >/dev/null 2>&1 || true
                  fid=$(get_filter_id "$name")
                fi
                if [ -n "$fid" ] && [ "$ARRS_INDEXERS" != "[]" ]; then
                  local payload
                  payload=$(cat <<FILTER_EOF
        {
          "name": "$name",
          "enabled": true,
          "priority": $priority,
          "min_size": "25MB",
          "max_size": "1TB",
          "indexers": $ARRS_INDEXERS,
          "match_categories": "$categories",
          "resolutions": [],
          "codecs": [],
          "sources": [],
          "containers": [],
          "actions": $actions_json
        }
    FILTER_EOF
                  )
                  ${pkgs.curl}/bin/curl -sf -X PUT \
                    -H "$AUTHHeader" \
                    -H "Content-Type: application/json" \
                    "$API_URL/filters/$fid" \
                    -d "$payload" >/dev/null 2>&1 \
                    && echo "autobrr-setup: reconciled $name filter id=$fid" \
                    || echo "autobrr-setup: failed to reconcile $name filter (non-fatal, retried next boot)"
                fi
              }

              SONARR_ACTION=$(printf '[{"name":"Sonarr","type":"SONARR","enabled":true,"client_id":%s}]' "$SONARR_ID")
              RADARR_ACTION=$(printf '[{"name":"Radarr","type":"RADARR","enabled":true,"client_id":%s}]' "$RADARR_ID")
              LIDARR_ACTION=$(printf '[{"name":"Lidarr","type":"LIDARR","enabled":true,"client_id":%s}]' "$LIDARR_ID")
              CATS_SONARR="${lib.concatStringsSep "," cfg.fallbackCategories.sonarr}"
              CATS_RADARR="${lib.concatStringsSep "," cfg.fallbackCategories.radarr}"
              CATS_LIDARR="${lib.concatStringsSep "," cfg.fallbackCategories.lidarr}"

              if [ -n "$CATS_SONARR" ]; then
                reconcile_filter "Sonarr Fallback" "800" "$CATS_SONARR" "$SONARR_ACTION"
              fi
              if [ -n "$CATS_RADARR" ]; then
                reconcile_filter "Radarr Fallback" "801" "$CATS_RADARR" "$RADARR_ACTION"
              fi
              if [ -n "$CATS_LIDARR" ]; then
                reconcile_filter "Lidarr Fallback" "802" "$CATS_LIDARR" "$LIDARR_ACTION"
              fi
              CATCHALL_ACTION=$(printf '[{"name":"Sonarr","type":"SONARR","enabled":true,"client_id":%s},{"name":"Radarr","type":"RADARR","enabled":true,"client_id":%s},{"name":"Lidarr","type":"LIDARR","enabled":true,"client_id":%s}]' "$SONARR_ID" "$RADARR_ID" "$LIDARR_ID")
              reconcile_filter "arrs Catch-all" "500" "" "$CATCHALL_ACTION"
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
    fallbackCategories = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = {
        sonarr = [ "TV*" ];
        radarr = [ "Movie*" ];
        lidarr = [ "Audio*" "Music*" "FLAC*" "MP3*" ];
      };
      description = "Category patterns (substring/wildcard, case-insensitive, OR within the list) used by the low-priority fallback filters. When a release's title matches no list-backed title filter, its announce category routes it to the matching *arr (e.g. TV* -> Sonarr). An empty list skips that *arr's fallback filter.";
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
