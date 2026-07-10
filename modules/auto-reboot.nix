{ pkgs, ... }:
{
  systemd.services.nixos-auto-reboot = {
    description = "Reboot if kernel/initrd changed since last boot";
    serviceConfig = {
      Type = "oneshot";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
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
        "/run/booted-system"
        "/nix/var/nix/profiles/system"
      ];
    };
    script = ''
      set -euo pipefail

      booted="$(${pkgs.coreutils}/bin/readlink /run/booted-system/{initrd,kernel,kernel-modules})"
      built="$(${pkgs.coreutils}/bin/readlink /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules})"

      if [ "$booted" != "$built" ]; then
        ${pkgs.systemd}/bin/shutdown -r +1 "Rebooting to apply kernel/initrd update"
      fi
    '';
  };

  systemd.timers.nixos-auto-reboot = {
    description = "Daily reboot check at 4am HST";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
    };
  };
}
