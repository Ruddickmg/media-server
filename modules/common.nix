{
  lib,
  pkgs,
  herdr,
  config,
  ...
}:
let
  inherit (builtins) substring hashString;
  inherit (config.networking) hostName;
  key = prefix: substring 0 32 (hashString "sha256" "${hostName}-${prefix}");
in
{
  options.media-server = {
    gotifyTokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos/secrets/gotify-token";
      description = "Path to file containing Gotify app token for system notifications";
    };

    gotifyAppName = lib.mkOption {
      type = lib.types.str;
      default = "Media Server";
      description = "Name of the Gotify app to create or use for system notifications";
    };

    apiKeys = {
      sonarr = lib.mkOption {
        type = lib.types.str;
        default = key "sonarr";
        description = "API key for Sonarr";
      };
      radarr = lib.mkOption {
        type = lib.types.str;
        default = key "radarr";
        description = "API key for Radarr";
      };
      lidarr = lib.mkOption {
        type = lib.types.str;
        default = key "lidarr";
        description = "API key for Lidarr";
      };
      prowlarr = lib.mkOption {
        type = lib.types.str;
        default = key "prowlarr";
        description = "API key for Prowlarr";
      };
      seerr = lib.mkOption {
        type = lib.types.str;
        default = key "seerr";
        description = "API key for Seerr";
      };
    };
  };

  config = {
    users.groups.media = { };
    users.groups.gotify-readers = { };

    systemd.services."notify-gotify@" = {
      description = "Gotify notification for failed service %i";
      serviceConfig = {
        Type = "oneshot";
        SupplementaryGroups = [ "gotify-readers" ];
        Environment = [ "INSTANCE=%i" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        CapabilityBoundingSet = [ "" ];
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
      };
      script = ''
        TOKEN=$(cat ${config.media-server.gotifyTokenFile} 2>/dev/null || echo "")
        [ -z "$TOKEN" ] && exit 0
        ${pkgs.curl}/bin/curl -sf -X POST "http://127.0.0.1:6789/message?token=$TOKEN" \
          -F "title=Service Failed: $INSTANCE" \
          -F "message=Systemd service $INSTANCE has failed" \
          -F "priority=5" >/dev/null 2>&1 || true
      '';
    };

    systemd.services.gotify-provision = {
      description = "Provision Gotify app and save token for system notifications";
      after = [ "gotify.service" ];
      wants = [ "gotify.service" ];
      before = [
        "declarr.service"
        "nixos-auto-update.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ReadWritePaths = [
          "/etc/nixos/secrets"
        ];
      };
      path = [
        pkgs.curl
        pkgs.jq
      ];
      script = ''
        set -uo pipefail

        GOTIFY_URL="http://127.0.0.1:6789"
        TOKEN_FILE="${config.media-server.gotifyTokenFile}"

        # Wait for Gotify to be ready
        for i in $(seq 1 30); do
          if curl -sf --connect-timeout 1 "$GOTIFY_URL/health" >/dev/null 2>&1; then
            echo "Gotify is ready"
            break
          fi
          sleep 1
        done

        if ! curl -sf --connect-timeout 1 "$GOTIFY_URL/health" >/dev/null 2>&1; then
          echo "ERROR: Gotify did not become ready in time" >&2
          exit 1
        fi

        # Check if the app already exists using Basic Auth (admin:admin)
        APP_DATA=$(curl -sf -u "admin:admin" "$GOTIFY_URL/application" 2>/dev/null | \
          jq -r '.[] | select(.name == "${config.media-server.gotifyAppName}")')

        if [ -n "$APP_DATA" ]; then
          echo "App exists, extracting token..."
          TOKEN=$(jq -r '.token' <<<"$APP_DATA")
        else
          echo "Creating Gotify app '${config.media-server.gotifyAppName}'..."
          TOKEN=$(curl -sf -X POST -u "admin:admin" \
            -H "Content-Type: application/json" \
            "$GOTIFY_URL/application" \
            -d '{"name":"${config.media-server.gotifyAppName}","description":"NixOS media server notifications"}' 2>/dev/null | \
            jq -r '.token')
        fi

        if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
          echo "ERROR: Failed to get or create Gotify app token" >&2
          exit 1
        fi

        # Atomic write: temp file then mv
        mkdir -p "$(dirname "$TOKEN_FILE")"
        printf '%s' "$TOKEN" > "$TOKEN_FILE.tmp"
        chown root:gotify-readers "$TOKEN_FILE.tmp"
        chmod 640 "$TOKEN_FILE.tmp"
        mv -f "$TOKEN_FILE.tmp" "$TOKEN_FILE"

        echo "Token saved to $TOKEN_FILE (permissions: $(stat -c '%a' "$TOKEN_FILE"), owner: $(stat -c '%U:%G' "$TOKEN_FILE"))"
      '';
    };

    systemd.tmpfiles.rules = [
      "d /media 2775 root media"
      "d /media/downloads 2775 root media"
      "d /media/downloads/incomplete 2775 root media"
      "d /media/downloads/completed 2775 root media"
      "d /media/movies 2775 root media"
      "d /media/tv 2775 root media"
      "d /media/music 2775 root media"
    ];

    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;
      shellAliases = {
        ls = "eza";
        l = "eza";
        la = "eza -a";
        ll = "eza -la";
        cat = "bat";
        metrics = "btop";
      };
    };

    programs.zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    programs.starship = {
      enable = true;
      settings.add_newline = false;
      line_break = {
        disabled = true;
      };
    };

    programs.zsh.interactiveShellInit = ''
      eval "$(starship init zsh)"
    '';

    environment.systemPackages = with pkgs; [
      unzip
      unrar
      p7zip
      git
      ripgrep
      jq
      vim
      yazi
      zoxide
      starship
      eza
      bat
      btop
      herdr.packages.${pkgs.system}.default
    ];
  };
}
