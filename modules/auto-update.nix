{ lib, pkgs, ... }:
{
  systemd.services.nixos-auto-update = {
    description = "Pull latest NixOS config from Git and rebuild";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.gitMinimal pkgs.nixos-rebuild ];
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
      fi
    '';
  };

  systemd.timers.nixos-auto-update = {
    description = "NixOS auto-update check every 15 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0,15,30,45";
      Persistent = true;
    };
  };
}
