{ pkgs, ... }:
{
  systemd.services.nixos-auto-reboot = {
    description = "Reboot if kernel/initrd changed since last boot";
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail

      booted_kernel="$(${pkgs.coreutils}/bin/readlink -f /run/booted-system/kernel)"
      built_kernel="$(${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system/kernel)"
      booted_initrd="$(${pkgs.coreutils}/bin/readlink -f /run/booted-system/initrd)"
      built_initrd="$(${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system/initrd)"
      booted_modules="$(${pkgs.coreutils}/bin/readlink -f /run/booted-system/kernel-modules)"
      built_modules="$(${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system/kernel-modules)"

      if [ "$booted_kernel" != "$built_kernel" ] || [ "$booted_initrd" != "$built_initrd" ] || [ "$booted_modules" != "$built_modules" ]; then
        ${pkgs.systemd}/bin/shutdown -r +1 "Rebooting to apply kernel/initrd update"
      fi
    '';
  };

  systemd.timers.nixos-auto-reboot = {
    description = "Daily reboot check at 4am HST";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00 Pacific/Honolulu";
      Persistent = true;
    };
  };
}
