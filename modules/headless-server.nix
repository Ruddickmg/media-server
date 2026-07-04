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
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
      startWhenNeeded = true;
    };

    services.logind = {
      lidSwitch = "ignore";
      lidSwitchExternalPower = "ignore";
      settings = {
        Login = {
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
      group = "media-server";
      extraGroups = [
        "media"
        "systemd-journal"
      ];
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };

    users.groups.media-server = { };
  };
}
