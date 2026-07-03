{ lib, ... }:
{
  systemd.services.nixos-auto-update = {
    description = "Pull latest NixOS config from Git and rebuild";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/etc/nixos";
      User = "root";
    };
    script = ''
      set -euo pipefail
      if ! git diff --quiet; then
        echo "Uncommitted changes in /etc/nixos - skipping auto-update"
        exit 0
      fi
      git fetch origin
      if ! git diff --quiet HEAD origin/main; then
        git merge --ff-only origin/main
        nixos-rebuild switch --flake /etc/nixos
      fi
    '';
  };

  systemd.timers.nixos-auto-update = {
    description = "Daily NixOS auto-update check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
