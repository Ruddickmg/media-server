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
in
{
  options.media-server.profilarr = {
    enable = lib.mkEnableOption "Profilarr profile management for Radarr and Sonarr";
  };

  config = lib.mkIf cfg.enable {
    # Ensure the config directory exists before the container starts.
    systemd.tmpfiles.rules = [
      "d /var/lib/profilarr 0755 root root -"
    ];

    virtualisation.oci-containers.containers.profilarr = {
      autoStart = true;
      image = "ghcr.io/dictionarry-hub/profilarr:latest";
      environment = {
        AUTH = "off";
        ORIGIN = "https://media-server.tailbac0df.ts.net:6868";
        PORT = "6865";
      };
      volumes = [ "/var/lib/profilarr:/config" ];
      ports = [ "127.0.0.1:6865:6865" ];
    };

    systemd.services.profilarr-init = {
      description = "Initialize Profilarr with Radarr and Sonarr instances";
      wants = [ "podman-profilarr.service" ];
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
        Restart = "no";
      };
      path = [
        pkgs.curl
        pkgs.jq
      ];
      script = ''
        set -uo pipefail

        # Wait for Profilarr to be ready
        for i in $(seq 1 30); do
          if curl -s -o /dev/null --connect-timeout 1 http://127.0.0.1:6865 >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done

        # Ensure Profilarr is actually reachable
        if ! curl -s -o /dev/null --connect-timeout 1 http://127.0.0.1:6865 >/dev/null 2>&1; then
          echo "Profilarr did not become ready in time" >&2
          exit 1
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
            curl -s -o /dev/null -X POST \
              -d "name=Radarr" \
              -d "url=http://127.0.0.1:7878" \
              -d "api_key=${config.media-server.apiKeys.radarr}" \
              -d "external_url=" \
              "http://127.0.0.1:6865/arr/''${RADARR_ID}/settings?/update" || echo "WARNING: Radarr update failed" >&2
          else
            echo "Creating new Radarr instance" >&2
            curl -s -o /dev/null -X POST \
              -d "name=Radarr" \
              -d "type=radarr" \
              -d "url=http://127.0.0.1:7878" \
              -d "api_key=${config.media-server.apiKeys.radarr}" \
              -d "external_url=" \
              "http://127.0.0.1:6865/arr/new" || echo "WARNING: Radarr creation failed" >&2
          fi
        ''}

        ${lib.optionalString sonarrEnabled ''
          SONARR_ID=$(echo "$BODY" | jq -r '.[] | select(.type == "sonarr") | .id' | head -n1)
          if [ -n "$SONARR_ID" ]; then
            echo "Updating existing Sonarr instance (id=$SONARR_ID)" >&2
            curl -s -o /dev/null -X POST \
              -d "name=Sonarr" \
              -d "url=http://127.0.0.1:8989" \
              -d "api_key=${config.media-server.apiKeys.sonarr}" \
              -d "external_url=" \
              "http://127.0.0.1:6865/arr/''${SONARR_ID}/settings?/update" || echo "WARNING: Sonarr update failed" >&2
          else
            echo "Creating new Sonarr instance" >&2
            curl -s -o /dev/null -X POST \
              -d "name=Sonarr" \
              -d "type=sonarr" \
              -d "url=http://127.0.0.1:8989" \
              -d "api_key=${config.media-server.apiKeys.sonarr}" \
              -d "external_url=" \
              "http://127.0.0.1:6865/arr/new" || echo "WARNING: Sonarr creation failed" >&2
          fi
        ''}
      '';
    };
  };
}
