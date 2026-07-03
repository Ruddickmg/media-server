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
      description = "SSH public keys to authorize for root login";
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
      extraConfig = ''
        HandlePowerKey=ignore
        HandleSuspendKey=ignore
        HandleHibernateKey=ignore
      '';
    };

    systemd.sleep.settings.Sleep = {
      AllowSuspend = "no";
      AllowHibernation = "no";
      AllowHybridSleep = "no";
      AllowSuspendThenHibernate = "no";
    };

    powerManagement.cpuFreqGovernor = "performance";

    security.sudo.extraRules = [
      {
        groups = [ "wheel" ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys;
  };
}
