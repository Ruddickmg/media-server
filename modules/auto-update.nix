{ lib, pkgs, ... }:
{
  systemd.services.nixos-auto-update = {
    description = "Pull latest NixOS config from Git and rebuild";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.gitMinimal
      pkgs.nixos-rebuild
      pkgs.curl
    ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/etc/nixos";
      User = "root";
    };
    script = ''
      set -euo pipefail
      git fetch origin
      if ! git diff --quiet HEAD origin/main; then
        git merge --ff-only origin/main
        nixos-rebuild switch --flake /etc/nixos
        curl -sf -X POST "http://127.0.0.1:6789/message?token=$(cat /etc/nixos/secrets/gotify-token 2>/dev/null || echo "")" \
          -F "title=NixOS Build Succeeded" \
          -F "message=System configuration updated successfully" \
          -F "priority=3" >/dev/null 2>&1 || true
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
