{
  lib,
  pkgs,
  pkgs-unstable,
  config,
  ...
}:
let
  cfg = config.media-server.cleanuparr;
  cleanuparrPkg = pkgs-unstable.callPackage ../../pkgs/cleanuparr { };
  port = 11011;
  baseUrl = "http://127.0.0.1:${toString port}";

  generalConfigFile = pkgs.writeText "cleanuparr-general.json" (
    builtins.toJSON {
      displaySupportBanner = false;
      dryRun = false;
      httpMaxRetries = 3;
      httpTimeout = 100;
      httpCertificateValidation = "Enabled";
      httpSendUserAgent = true;
      statusCheckEnabled = true;
      ignoredDownloads = [ ];
      connectivityCheckEnabled = false;
      connectivityCheckUrls = [ ];
      strikeInactivityWindowHours = 24;
      historyRetentionDays = 365;
      log = {
        level = "Information";
        rollingSizeMB = 10;
        retainedFileCount = 5;
        timeLimitHours = 24;
        archiveEnabled = true;
        archiveRetainedCount = 60;
        archiveTimeLimitHours = 720;
      };
      # The UI is reachable only through Caddy/Tailscale. Never bypass auth for
      # local addresses: that also trusts proxying peers and is unsafe behind
      # the reverse proxy. The API key auth scheme is used by this reconciler.
      auth = {
        disableAuthForLocalAddresses = false;
        trustForwardedHeaders = true;
        trustedNetworks = [ "127.0.0.1/32" ];
      };
    }
  );

  downloadClientFile = pkgs.writeText "cleanuparr-download-client.json" (
    builtins.toJSON {
      enabled = true;
      name = "Deluge";
      typeName = "Deluge";
      # Deluge Web UI is proxied to the root network namespace on loopback.
      host = "http://127.0.0.1:8112";
      username = "localclient";
      password = "deluge";
      apiKey = null;
      urlBase = null;
      externalUrl = null;
      # Deluge reports the same /media/data paths Cleanuparr sees natively.
      downloadDirectorySource = null;
      downloadDirectoryTarget = null;
    }
  );

  arrConfigsFile = pkgs.writeText "cleanuparr-arr-configs.json" (
    builtins.toJSON [
      {
        type = "sonarr";
        config.failedImportMaxStrikes = -1;
        instance = {
          enabled = true;
          name = "Sonarr";
          url = "http://127.0.0.1:8989";
          apiKey = config.media-server.apiKeys.sonarr;
          version = 3;
          externalUrl = null;
        };
      }
      {
        type = "radarr";
        config.failedImportMaxStrikes = -1;
        instance = {
          enabled = true;
          name = "Radarr";
          url = "http://127.0.0.1:7878";
          apiKey = config.media-server.apiKeys.radarr;
          version = 3;
          externalUrl = null;
        };
      }
      {
        type = "lidarr";
        config.failedImportMaxStrikes = -1;
        instance = {
          enabled = true;
          name = "Lidarr";
          url = "http://127.0.0.1:8686";
          apiKey = config.media-server.apiKeys.lidarr;
          version = 3;
          externalUrl = null;
        };
      }
    ]
  );

  downloadCleanerFile = pkgs.writeText "cleanuparr-download-cleaner.json" (
    builtins.toJSON {
      enabled = true;
      # Quartz (7-field) cron: hourly at 15 minutes past the hour.
      cronExpression = "0 15 * * * ?";
      useAdvancedScheduling = true;
      ignoredDownloads = [ ];
    }
  );

  seedingRulesFile = pkgs.writeText "cleanuparr-seeding-rules.json" (
    builtins.toJSON [
      {
        name = "unlinked-torrents";
        body = {
          name = "unlinked-torrents";
          categories = [ "cleanuparr-unlinked" ];
          trackerPatterns = [ ];
          tagsAny = [ ];
          tagsAll = [ ];
          privacyType = "Both";
          maxRatio = -1;
          minSeedTime = 0;
          maxSeedTime = 0;
          minSeeders = 0;
          maxInactiveDays = -1;
          deleteSourceFiles = true;
          action = "Delete";
        };
      }
      {
        name = "public-ratio";
        body = {
          name = "public-ratio";
          # Deluge exposes these as Label plugin labels. Private-trackers are
          # deliberately excluded: their ratio goals stay with the *arr apps.
          categories = [
            "radarr"
            "tv-sonarr"
            "lidarr"
            "cross-seed"
          ];
          trackerPatterns = [ ];
          tagsAny = [ ];
          tagsAll = [ ];
          privacyType = "Public";
          maxRatio = 1;
          minSeedTime = 24;
          maxSeedTime = -1;
          minSeeders = 0;
          maxInactiveDays = -1;
          deleteSourceFiles = true;
          action = "Delete";
        };
      }
    ]
  );

  unlinkedConfigFile = pkgs.writeText "cleanuparr-unlinked-config.json" (
    builtins.toJSON {
      enabled = true;
      targetCategory = "cleanuparr-unlinked";
      useTag = false;
      # Only links in the library count. Links inside the torrent tree (the
      # source copy and cross-seed's link) must not mask an orphaned download.
      ignoredRootDirs = [ "/media/data/torrents" ];
      categories = [
        "radarr"
        "tv-sonarr"
        "lidarr"
        "cross-seed"
      ];
    }
  );

  orphanedConfigFile = pkgs.writeText "cleanuparr-orphaned-config.json" (
    builtins.toJSON {
      enabled = true;
      scanDirectories = [
        "/media/data/torrents/complete"
        "/media/data/torrents/xseeds"
      ];
      orphanedDirectory = "/media/data/torrents/orphaned";
      excludePatterns = [ ];
      minFileAgeHours = 24;
      # Give a moved entry a week before permanent deletion. Entries that still
      # have a library hardlink lose only the torrent-side link here; the rest
      # of the space is reclaimed when Plex/*arr remove the library copy.
      purgeAfterHours = 168;
    }
  );
in
{
  options.media-server.cleanuparr = {
    enable = lib.mkEnableOption "Cleanuparr torrent and media cleanup";
  };

  config = lib.mkIf cfg.enable {
    users.users.cleanuparr = {
      isSystemUser = true;
      # Primary group media, not cleanuparr: a FUSE request header carries only
      # the caller's primary gid, and hardlink/unlink through mergerfs needs it.
      group = "media";
      home = "/var/lib/cleanuparr";
      description = "Cleanuparr service user";
    };

    systemd.services.cleanuparr = {
      description = "Cleanuparr torrent and media cleanup";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        OnFailure = "notify-gotify@%n.service";
        RequiresMountsFor = [ "/media/data" ];
      };
      serviceConfig = {
        ExecStart = "${lib.getExe cleanuparrPkg}";
        User = "cleanuparr";
        Group = "media";
        StateDirectory = "cleanuparr";
        StateDirectoryMode = "0750";
        Environment = [
          "PORT=${toString port}"
          "BIND_ADDRESS=127.0.0.1"
          "CLEANUPARR_CONFIG_PATH=/var/lib/cleanuparr"
          "CLEANUPARR_LOGS_PATH=/var/lib/cleanuparr/logs"
        ];
        # Keep new files group-writable so other media services can unlink or
        # relink them.
        UMask = "0002";
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        LockPersonality = true;
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        KeyringMode = "private";
        ProtectHostname = true;
        ProtectProc = "invisible";
        # buildFHSEnv enters through bubblewrap, which reads
        # /proc/sys/kernel/overflowuid and overflowgid. ProcSubset=pid hides
        # /proc/sys entirely, so this service needs the full proc subset.
        ProcSubset = "all";
        # One bind mount for the whole media tree: under ProtectSystem=strict,
        # separate ReadWritePaths entries are different vfsmounts and link(2)
        # / rename(2) between them fails with EXDEV.
        ReadWritePaths = [ "/media/data" ];
        # No PrivateNetwork: Cleanuparr must reach Deluge on host loopback.
      };
    };

    # Functional settings live in Cleanuparr's DB and are only reachable
    # through its API. Reconcile them here so the config is declarative rather
    # than a one-time UI setup. Writes are idempotent and run on every boot.
    systemd.services.cleanuparr-init = {
      description = "Reconcile declarative Cleanuparr configuration";
      bindsTo = [ "cleanuparr.service" ];
      after = [
        "cleanuparr.service"
      ]
      ++ lib.optionals (config.media-server.deluge.enable or false) [
        "deluged.service"
        "delugeweb.service"
        "proxy-deluge-web.service"
      ];
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        OnFailure = "notify-gotify@%n.service";
        RequiresMountsFor = [ "/media/data" ];
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "10s";
        User = "cleanuparr";
        Group = "media";
        StateDirectory = "cleanuparr";
        StateDirectoryMode = "0750";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/media/data" ];
      };
      path = [
        pkgs.curl
        pkgs.jq
      ];
      script = ''
        set -uo pipefail

        BASE_URL="${baseUrl}"
        KEY_CACHE=/var/lib/cleanuparr/reconciler-api-key
        # Fixed bootstrap login, like the other *arr services. Tailscale is the
        # access control layer.
        ADMIN_USERNAME="admin"
        ADMIN_PASSWORD="administrator"
        HTTP_CODE=000
        RESPONSE_BODY=""
        API_KEY=""
        TOKEN=""

        fail() {
          echo "cleanuparr-init: $*" >&2
          exit 1
        }

        # All calls share these two globals. The trailing status line is split
        # off so JSON bodies stay available to jq.
        api() {
          local method="$1" path="$2" data="''${3-}" header="''${4-}"
          local -a args=(-sS -w '\n%{http_code}' -X "$method")
          local out
          [ -n "$header" ] && args+=(-H "$header")
          if [ -n "$data" ]; then
            args+=(-H 'Content-Type: application/json' --data-binary "$data")
          fi
          if ! out=$(curl "''${args[@]}" "$BASE_URL$path"); then
            HTTP_CODE=000
            RESPONSE_BODY=""
            return 1
          fi
          HTTP_CODE="''${out##*$'\n'}"
          RESPONSE_BODY="''${out%$'\n'*}"
          case "$HTTP_CODE" in
            2??) return 0 ;;
            *)
              printf 'cleanuparr-init: %s %s -> HTTP %s\n%s\n' \
                "$method" "$path" "$HTTP_CODE" "$RESPONSE_BODY" >&2
              return 1
              ;;
          esac
        }

        apiKeyApi() { api "$1" "$2" "''${3-}" "X-Api-Key: $API_KEY"; }
        bearerApi() { api "$1" "$2" "''${3-}" "Authorization: Bearer $TOKEN"; }

        # cleanuparr.service is Type=simple, so After= only means bwrap was
        # launched, not that the HTTP listener is up. Wait for health here.
        # NixOS prepends `set -e` to every unit script, so the probe curl must
        # tolerate a refused connection or it aborts before the loop can retry.
        for ((i = 1; i <= 60; i++)); do
          HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "$BASE_URL/health" 2>/dev/null || true)
          [ "$HTTP_CODE" = "200" ] && break
          sleep 2
        done
        [ "$HTTP_CODE" = "200" ] || fail "Cleanuparr did not become ready on $BASE_URL"

        # First boot: create the admin account and close the setup wizard.
        api GET /api/auth/status || fail "failed to read auth status"
        SETUP_COMPLETED=$(jq -r '.setupCompleted // false' <<<"$RESPONSE_BODY")
        if [ "$SETUP_COMPLETED" != "true" ]; then
          ACCOUNT_JSON=$(jq -n --arg username "$ADMIN_USERNAME" --arg password "$ADMIN_PASSWORD" \
            '{username: $username, password: $password}')
          if ! api POST /api/auth/setup/account "$ACCOUNT_JSON"; then
            [ "$HTTP_CODE" = "409" ] || fail "failed to create Cleanuparr account"
          fi
          if ! api POST /api/auth/setup/complete; then
            [ "$HTTP_CODE" = "409" ] || fail "failed to complete Cleanuparr setup"
          fi
        fi

        # A cached key keeps working after 2FA is enabled in the UI. Fall back
        # to a password login only when the cached key is absent or rejected.
        if [ -s "$KEY_CACHE" ]; then
          API_KEY=$(tr -d '\n' < "$KEY_CACHE")
          code=$(curl -s -o /dev/null -w '%{http_code}' \
            -H "X-Api-Key: $API_KEY" "$BASE_URL/api/configuration/general" 2>/dev/null || true)
          [ "$code" = "200" ] || API_KEY=""
        fi

        if [ -z "$API_KEY" ]; then
          LOGIN_JSON=$(jq -n --arg username "$ADMIN_USERNAME" --arg password "$ADMIN_PASSWORD" \
            '{username: $username, password: $password}')
          api POST /api/auth/login "$LOGIN_JSON" || fail "failed to log in to Cleanuparr"
          if [ "$(jq -r '.requiresTwoFactor // false' <<<"$RESPONSE_BODY")" = "true" ]; then
            fail "2FA is enabled and no cached API key is valid; reconcile manually once"
          fi
          TOKEN=$(jq -r '.tokens.accessToken // empty' <<<"$RESPONSE_BODY")
          [ -n "$TOKEN" ] || fail "login response contained no access token"
          bearerApi GET /api/account/api-key || fail "failed to retrieve API key"
          API_KEY=$(jq -r '.apiKey // empty' <<<"$RESPONSE_BODY")
          [ -n "$API_KEY" ] || fail "API key response was empty"
          (umask 077; printf '%s\n' "$API_KEY" > "$KEY_CACHE")
        fi

        apiKeyApi PUT /api/configuration/general "$(cat ${generalConfigFile})" || fail "failed to set general config"

        # Keep exactly one Deluge client and one instance per *arr app.
        apiKeyApi GET /api/configuration/download_client || fail "failed to list download clients"
        CLIENT_ID=$(jq -r '.clients[] | select(.name == "Deluge") | .id' <<<"$RESPONSE_BODY" | head -n1)
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          apiKeyApi DELETE "/api/configuration/download_client/$id" || fail "failed to delete stale download client $id"
        done < <(jq -r --arg keep "$CLIENT_ID" '.clients[] | select(.id != $keep) | .id' <<<"$RESPONSE_BODY")
        DOWNLOAD_CLIENT_JSON="$(cat ${downloadClientFile})"
        if [ -n "$CLIENT_ID" ]; then
          apiKeyApi PUT "/api/configuration/download_client/$CLIENT_ID" "$DOWNLOAD_CLIENT_JSON" || fail "failed to update Deluge client"
        else
          apiKeyApi POST /api/configuration/download_client "$DOWNLOAD_CLIENT_JSON" || fail "failed to create Deluge client"
          CLIENT_ID=$(jq -r '.id // empty' <<<"$RESPONSE_BODY")
        fi
        [ -n "$CLIENT_ID" ] || fail "no Deluge client id after reconciliation"

        ARR_COUNT=$(jq 'length' ${arrConfigsFile})
        for ((i = 0; i < ARR_COUNT; i++)); do
          type=$(jq -r ".[$i].type" ${arrConfigsFile})
          name=$(jq -r ".[$i].instance.name" ${arrConfigsFile})
          config_json=$(jq -c ".[$i].config" ${arrConfigsFile})
          instance_json=$(jq -c ".[$i].instance" ${arrConfigsFile})
          apiKeyApi PUT "/api/configuration/$type" "$config_json" || fail "failed to update $type config"
          apiKeyApi GET "/api/configuration/$type" || fail "failed to read $type instances"
          keep_id=$(jq -r --arg name "$name" '.instances[] | select(.name == $name) | .id' <<<"$RESPONSE_BODY" | head -n1)
          while IFS= read -r id; do
            [ -n "$id" ] || continue
            apiKeyApi DELETE "/api/configuration/$type/instances/$id" || fail "failed to delete stale $type instance $id"
          done < <(jq -r --arg keep "$keep_id" '.instances[] | select(.id != $keep) | .id' <<<"$RESPONSE_BODY")
          if [ -n "$keep_id" ]; then
            apiKeyApi PUT "/api/configuration/$type/instances/$keep_id" "$instance_json" || fail "failed to update $name instance"
          else
            apiKeyApi POST "/api/configuration/$type/instances" "$instance_json" || fail "failed to create $name instance"
          fi
        done

        apiKeyApi PUT /api/configuration/download_cleaner "$(cat ${downloadCleanerFile})" || fail "failed to update download cleaner"

        apiKeyApi GET "/api/seeding-rules/$CLIENT_ID" || fail "failed to list seeding rules"
        RULES="$RESPONSE_BODY"
        declare -A keep_rules=()
        RULE_COUNT=$(jq 'length' ${seedingRulesFile})
        for ((i = 0; i < RULE_COUNT; i++)); do
          name=$(jq -r ".[$i].name" ${seedingRulesFile})
          body=$(jq -c ".[$i].body" ${seedingRulesFile})
          id=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .id' <<<"$RULES" | head -n1)
          if [ -n "$id" ]; then
            keep_rules["$id"]=1
            apiKeyApi PUT "/api/seeding-rules/$id" "$body" || fail "failed to update seeding rule $name"
          else
            apiKeyApi POST "/api/seeding-rules/$CLIENT_ID" "$body" || fail "failed to create seeding rule $name"
          fi
        done
        while IFS=$'\t' read -r id name; do
          [ -n "$id" ] || continue
          if [ -z "''${keep_rules[$id]:-}" ]; then
            apiKeyApi DELETE "/api/seeding-rules/$id" || fail "failed to delete stale seeding rule $id"
          fi
        done < <(jq -r '.[] | [.id, .name] | @tsv' <<<"$RULES")

        apiKeyApi PUT "/api/unlinked-config/$CLIENT_ID" "$(cat ${unlinkedConfigFile})" || fail "failed to update unlinked config"
        apiKeyApi PUT "/api/orphaned-files-config/$CLIENT_ID" "$(cat ${orphanedConfigFile})" || fail "failed to update orphaned-files config"

        echo "cleanuparr-init: configuration reconciled for Deluge client $CLIENT_ID"
      '';
    };
  };
}
