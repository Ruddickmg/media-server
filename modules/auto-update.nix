{
  lib,
  pkgs,
  config,
  ...
}:
{
  systemd.services.nixos-auto-update = {
    description = "Pull latest NixOS config from Git and rebuild";
    after = [
      "network-online.target"
      "gotify-provision.service"
    ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.gitMinimal
      pkgs.nixos-rebuild
      pkgs.curl
      pkgs.gnutar
    ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/etc/nixos";
      User = "root";
      SupplementaryGroups = [ "gotify-readers" ];
    };
    script = ''
      set -euo pipefail
      TOKEN=$(cat ${config.media-server.gotifyTokenFile} 2>/dev/null || echo "")
      git fetch origin
      if ! git diff --quiet HEAD origin/main; then
        # Backup Deluge state before applying any configuration changes.
        # Only one backup file is kept; it is overwritten if older than 24 hours.
        BACKUP_DIR="/var/lib/deluge/backup"
        TODAY_FILE="$BACKUP_DIR/$(date +%F)-deluge-state.tar.gz"
        find "$BACKUP_DIR" -maxdepth 1 -type f -name '*-deluge-state.tar.gz' -mtime +0 -delete
        if [ ! -f "$TODAY_FILE" ]; then
          mkdir -p "$BACKUP_DIR"
          tar -czf "$TODAY_FILE" -C /var/lib/deluge/.config/deluge state/
        fi

        git merge --ff-only origin/main
        if nixos-rebuild switch --no-update-lock-file --flake /etc/nixos; then
          curl -sf -X POST "http://127.0.0.1:6789/message?token=$TOKEN" \
            -F "title=NixOS Build Succeeded" \
            -F "message=System configuration updated successfully" \
            -F "priority=3" >/dev/null 2>&1 || true
        else
          curl -sf -X POST "http://127.0.0.1:6789/message?token=$TOKEN" \
            -F "title=NixOS Build FAILED" \
            -F "message=nixos-rebuild switch failed" \
            -F "priority=5" >/dev/null 2>&1 || true
        fi
      fi
    '';
  };

  systemd.timers.nixos-auto-update = {
    description = "NixOS auto-update check every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      Persistent = true;
    };
  };
}
