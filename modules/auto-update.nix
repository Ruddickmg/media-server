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
    ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/etc/nixos";
      User = "root";
      SupplementaryGroups = [ "gotify-readers" ];
      NoNewPrivileges = true;
      PrivateTmp = true;
      RemoveIPC = true;
      KeyringMode = "private";
    };
    script = ''
      set -euo pipefail
      TOKEN=$(cat ${config.media-server.gotifyTokenFile} 2>/dev/null || echo "")
      git fetch origin
      if ! git diff --quiet HEAD origin/main; then
        git merge --ff-only origin/main
        if nixos-rebuild switch --flake /etc/nixos; then
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
