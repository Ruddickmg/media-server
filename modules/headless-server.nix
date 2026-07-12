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

    services.getty.autologinUser = "media-server";

    services.tailscale.authKeyFile = "/etc/nixos/secrets/tailscale-auth";

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

    users.groups.media-server = { };

    system.userActivationScripts.zshrc = "touch /home/media-server/.zshrc";
  };
}
