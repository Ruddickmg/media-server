{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.media-server.profilarr;
  radarrEnabled = config.media-server.radarr.enable;
  sonarrEnabled = config.media-server.sonarr.enable;
  cleanupProfilarrNft = pkgs.writeShellScript "cleanup-profilarr-nft" ''
    set -o pipefail
    ${pkgs.nftables}/bin/nft -a list ruleset inet netavark 2>/dev/null | \
      ${pkgs.gawk}/bin/awk '
        /^chain / { chain = $2 }
        /tcp dport 6865/ && /handle/ {
          for (i = 1; i <= NF; i++)
            if ($i == "handle") print chain, $(i + 1)
        }
      ' | while read -r c h; do
        ${pkgs.nftables}/bin/nft delete rule inet netavark "$c" handle "$h" 2>/dev/null || true
      done
  '';
in
{
  options.media-server.profilarr = {
    enable = lib.mkEnableOption "Profilarr profile management for Radarr and Sonarr";
  };

  config = lib.mkIf cfg.enable {
    # Ensure the config directory exists before the container starts.
    systemd.tmpfiles.rules = [
      "d /var/lib/profilarr 0750 5686 5686 -"
    ];

    virtualisation.oci-containers.containers.profilarr = {
      autoStart = true;
      image = "ghcr.io/dictionarry-hub/profilarr:latest";
      environment = {
        PORT = "6865";
        AUTH = "off";
        DENO_DIR = "/tmp/deno";
        ORIGIN = "https://media-server.tailbac0df.ts.net";
      };
      volumes = [ "/var/lib/profilarr:/config" ];
      ports = [ "127.0.0.1:6865:6865" ];
      extraOptions = [
        "--user=5686:5686"
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges:true"
        "--read-only"
        "--tmpfs=/tmp:nosuid,size=64M"
      ];
    };

    systemd.services.podman-profilarr.serviceConfig = {
      # Netavark bug: leftover nftables DNAT rules for port 6865 accumulate on container
      # restart, breaking port forwarding. Remove any existing rules for port 6865 before
      # the container starts, so netavark creates a clean set. See
      # https://bugzilla.redhat.com/2322021
      ExecStartPre = [ "-${cleanupProfilarrNft}" ];
    };

    systemd.services.profilarr-init = {
      description = "Initialize Profilarr with Radarr and Sonarr instances";
      bindsTo = [ "podman-profilarr.service" ];
      after = [
        "podman-profilarr.service"
      ]
      ++ lib.optional radarrEnabled "radarr.service"
      ++ lib.optional sonarrEnabled "sonarr.service";
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        OnFailure = "notify-gotify@%n.service";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "10";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
      };
      path = [
        pkgs.curl
        pkgs.jq
      ];
      script = ''
        set -uo pipefail

        # Wait for Profilarr to be ready (cold-start downloads Deno deps, can take 60s+)
        for i in $(seq 1 60); do
          CURL_OUTPUT=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://127.0.0.1:6865 2>&1)
          CURL_EXIT=$?
          [ "$CURL_EXIT" -eq 0 ] && break
          echo "Profilarr check failed on attempt $i — curl exit code: $CURL_EXIT, output: $CURL_OUTPUT" >&2
          sleep 2
        done

        if ! curl -s -o /dev/null --connect-timeout 1 http://127.0.0.1:6865 >/dev/null 2>&1; then
          echo "WARNING: Profilarr did not become ready in time — proceeding anyway, downstream requests may fail" >&2
        fi

        # Fetch existing instances; if the API fails, log and exit cleanly
        INSTANCES=$(curl -s -w "\n%{http_code}" http://127.0.0.1:6865/api/v1/arr)
        HTTP_CODE=$(echo "$INSTANCES" | tail -n1)
        BODY=$(echo "$INSTANCES" | sed '$d')
        if [ "$HTTP_CODE" != "200" ]; then
          echo "WARNING: GET /api/v1/arr returned HTTP $HTTP_CODE" >&2
          echo "$BODY" >&2
          exit 0
        fi

        ${lib.optionalString radarrEnabled ''
          RADARR_ID=$(echo "$BODY" | jq -r '.[] | select(.type == "radarr") | .id' | head -n1)
          if [ -n "$RADARR_ID" ]; then
            echo "Updating existing Radarr instance (id=$RADARR_ID)" >&2
            CURL_RESULT=$(curl -s -w "\n%{http_code}" -X POST \
              -H "Origin: https://media-server.tailbac0df.ts.net" \
              -d "name=Radarr" \
              -d "url=http://127.0.0.1:7878" \
              -d "api_key=${config.media-server.apiKeys.radarr}" \
              -d "external_url=" \
              "http://127.0.0.1:6865/arr/''${RADARR_ID}/settings?/update" 2>&1)
            echo "POST update Radarr result: $(echo "$CURL_RESULT" | tail -n1), body: $(echo "$CURL_RESULT" | sed '$d')" >&2
          else
            echo "Creating new Radarr instance" >&2
            CURL_RESULT=$(curl -s -w "\n%{http_code}" -X POST \
              -H "Origin: https://media-server.tailbac0df.ts.net" \
              -d "name=Radarr" \
              -d "type=radarr" \
              -d "url=http://127.0.0.1:7878" \
              -d "api_key=${config.media-server.apiKeys.radarr}" \
              -d "external_url=" \
              "http://127.0.0.1:6865/arr/new" 2>&1)
            echo "POST create Radarr result: $(echo "$CURL_RESULT" | tail -n1), body: $(echo "$CURL_RESULT" | sed '$d')" >&2
          fi
        ''}

        ${lib.optionalString sonarrEnabled ''
          SONARR_ID=$(echo "$BODY" | jq -r '.[] | select(.type == "sonarr") | .id' | head -n1)
          if [ -n "$SONARR_ID" ]; then
            echo "Updating existing Sonarr instance (id=$SONARR_ID)" >&2
            CURL_RESULT=$(curl -s -w "\n%{http_code}" -X POST \
              -H "Origin: https://media-server.tailbac0df.ts.net" \
              -d "name=Sonarr" \
              -d "url=http://127.0.0.1:8989" \
              -d "api_key=${config.media-server.apiKeys.sonarr}" \
              -d "external_url=" \
              "http://127.0.0.1:6865/arr/''${SONARR_ID}/settings?/update" 2>&1)
            echo "POST update Sonarr result: $(echo "$CURL_RESULT" | tail -n1), body: $(echo "$CURL_RESULT" | sed '$d')" >&2
          else
            echo "Creating new Sonarr instance" >&2
            CURL_RESULT=$(curl -s -w "\n%{http_code}" -X POST \
              -H "Origin: https://media-server.tailbac0df.ts.net" \
              -d "name=Sonarr" \
              -d "type=sonarr" \
              -d "url=http://127.0.0.1:8989" \
              -d "api_key=${config.media-server.apiKeys.sonarr}" \
              -d "external_url=" \
              "http://127.0.0.1:6865/arr/new" 2>&1)
            echo "POST create Sonarr result: $(echo "$CURL_RESULT" | tail -n1), body: $(echo "$CURL_RESULT" | sed '$d')" >&2
          fi
        ''}
      '';
    };
  };
}
