{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.media-server.headless;
in
{
  options.media-server.headless = {
    authorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "SSH public keys authorized for root and media-server users";
      example = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL4JPTmz5x0W4C+l7Jd5F0... user@laptop"
      ];
    };
  };

  config = {
    environment.systemPackages = [ pkgs.kitty.terminfo ];

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
      startWhenNeeded = true;
    };

    services.logind = {
      settings = {
        Login = {
          HandleLidSwitch = "ignore";
          HandleLidSwitchExternalPower = "ignore";
          HandlePowerKey = "ignore";
          HandleSuspendKey = "ignore";
          HandleHibernateKey = "ignore";
        };
      };
    };

    systemd.sleep.settings.Sleep = {
      AllowSuspend = "no";
      AllowHibernation = "no";
      AllowHybridSleep = "no";
      AllowSuspendThenHibernate = "no";
    };

    powerManagement.cpuFreqGovernor = "performance";

    security.sudo.enable = false;

    services.getty.autologinUser = "media-server";

    services.tailscale.authKeyFile = "/etc/nixos/secrets/tailscale-auth";

    # Render /etc/passwd, /etc/group, /etc/shadow as immutable store symlinks
    # instead of mutable files. Prevents a disk-full write from truncating the
    # user database mid-write and bricking boot with "unknown user" failures.
    users.mutableUsers = false;

    # Immutable users wipe any undeclared password to `!`, so su/auth fails
    # unless a hash is declared here. Replace CHANGE_ME with `openssl passwd -6`.
    users.users.root.hashedPassword = "$6$l23IgwTooT7aGSGk$NJQ6lAHU1knD36IofTzFzVEHjFXdrdqr49ku3IyFioQ8XEAhFnk/nkwQ.CWLENAOtZc2b3oRxm8etUJ7e0vF31";
    users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys;

    users.users.media-server = {
      isNormalUser = true;
      shell = pkgs.zsh;
      group = "media-server";
      extraGroups = [
        "media"
        "systemd-journal"
      ];
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };

    users.groups.media-server = {
      gid = 992;
    };

    system.userActivationScripts.mediaServerZshrc = ''
      if [ ! -e /home/media-server/.zshrc ]; then
        touch /home/media-server/.zshrc
        chown media-server:media-server /home/media-server/.zshrc
        chmod 0644 /home/media-server/.zshrc
      fi
    '';

  };
}
