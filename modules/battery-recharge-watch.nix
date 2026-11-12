{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.batteryRechargeWatch;

  boolToInt = b: if b then "1" else "0";

  script = pkgs.writeShellScriptBin "battery-recharge-watch" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.kmod
        pkgs.util-linux
        pkgs.systemd
      ]
    }:$PATH
    ${builtins.readFile ./battery-recharge-watch.sh}
  '';
in
{
  options.services.batteryRechargeWatch = {
    enable = lib.mkEnableOption ''
      watch the battery and re-arm charging when the embedded controller stops
      charging while AC is still connected
    '';

    battery = lib.mkOption {
      type = lib.types.str;
      default = "BAT0";
      description = "Name of the battery under /sys/class/power_supply.";
    };

    ac = lib.mkOption {
      type = lib.types.str;
      default = "AC";
      description = "Name of the AC adapter under /sys/class/power_supply.";
    };

    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = "Seconds between battery samples.";
    };

    window = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = ''
        Seconds of history used to decide whether the pack is still gaining
        charge. Shorter means faster detection but more false positives from
        gauge noise.
      '';
    };

    minRisePermille = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        Charge must rise by this many thousandths of charge_full over `window`
        or the pack counts as stalled. 2 on a 4089 mAh pack is ~8 mAh, i.e. an
        average of ~160 mA over the window. This is the authoritative fault
        signal: it is independent of what current_now claims, because the EC
        has been seen reporting a healthy positive current while draining.
      '';
    };

    minRise = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2000;
      description = ''
        Minimum increase in charge_now (in uAh) that counts as charging having
        resumed while verifying a reset tier.
      '';
    };

    cooldown = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Base number of seconds to wait between reset attempts.";
    };

    maxCooldown = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Upper bound for the exponential reset backoff.";
    };

    maxAttempts = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        Maximum reset attempts per AC session. 0 means unlimited. Attempts are
        reset when the charger is unplugged and plugged back in.
      '';
    };

    resetDwell = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Seconds to wait after a tier's action before verifying.";
    };

    verifyWait = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
      description = "Seconds to watch for charge recovery after a reset tier.";
    };

    verifyPoll = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Seconds between samples while verifying a reset tier.";
    };

    sustainedSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Seconds of successful charging after which the failure backoff is
        cleared.
      '';
    };

    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Log what would happen without touching the hardware.";
    };

    leaveWorkingMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        If a Dell charge-mode change restarts charging, keep the working mode
        instead of restoring the original one.
      '';
    };

    enableAcRebind = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        First tier: unbind/rebind the ACPI AC adapter driver so the EC
        re-evaluates the adapter presence. Cheap and safe.
      '';
    };

    acDevice = lib.mkOption {
      type = lib.types.str;
      default = "ACPI0003:00";
      description = "Platform device name of the AC adapter.";
    };

    enableBatteryRebind = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Second tier: unbind/rebind the ACPI battery driver so the EC is asked
        for a fresh _BST/_BIF. Cheap and safe.
      '';
    };

    batteryDevice = lib.mkOption {
      type = lib.types.str;
      default = "PNP0C0A:00";
      description = "ACPI device name of the battery.";
    };

    enableUcsiReset = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Third tier: reset the USB-C PD state through UCSI. First unbind/rebind
        ucsi_acpi, which runs the UCSI PPM_RESET; if charging does not resume,
        reload the whole typec/ucsi stack. This is the closest software
        equivalent to replugging the charger.
      '';
    };

    ucsiDevice = lib.mkOption {
      type = lib.types.str;
      default = "USBC000:00";
      description = "Platform device name for the UCSI controller.";
    };

    ucsiDriver = lib.mkOption {
      type = lib.types.str;
      default = "ucsi_acpi";
      description = "Platform driver name for the UCSI controller.";
    };

    enableDellModes = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Fourth tier: toggle the Dell charge mode and temporarily force Custom
        thresholds through the SMM interface. Kept because it is harmless, but
        on the XPS 15 9530 these writes do not re-arm a stopped charger.
      '';
    };

    enableSuspendReset = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Fifth tier: suspend to RAM for a few seconds with rtcwake, which
        reinitializes the embedded controller and USB-C PD state. Requires
        suspend to be allowed by systemd (AllowSuspend=yes); an appliance that
        sets AllowSuspend=no must leave this off.
      '';
    };

    suspendSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Seconds to stay suspended during a suspend reset.";
    };

    suspendAfterFailures = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        Consecutive failed reset cycles before the suspend tier is attempted.
        0 means try it on the first fault.
      '';
    };

    enableEcReset = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Sixth tier: rebind the ACPI EC driver (PNP0C09:00). This re-runs the
        EC's ACPI initialisation and is the closest software equivalent to
        Dell's "drain flea power" reset. Opt-in because a failed rebind leaves
        the machine without battery or thermal monitoring until it reboots.
      '';
    };

    ecDevice = lib.mkOption {
      type = lib.types.str;
      default = "PNP0C09:00";
      description = "ACPI device name of the embedded controller.";
    };

    enableRebootReset = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Last resort: reboot to re-run the firmware's EC initialisation. Only
        fires below `rebootBelowCapacity` and at most once per
        `rebootCooldown` seconds, so it cannot become a reboot loop. Intended
        for headless appliances where uptime matters more than a restart.
      '';
    };

    rebootBelowCapacity = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Capacity percentage below which the reboot tier may fire.";
    };

    rebootCooldown = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1800;
      description = "Minimum seconds between reboot-tier attempts.";
    };

    notifyScript = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional executable called as `SCRIPT <title> <message>` when a fault
        is detected, when all tiers fail, and before a reboot-tier restart.
      '';
    };

    notifyGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Supplementary groups granted to the watchdog service so `notifyScript`
        can read a group-owned secret (for example the Gotify token).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.battery-recharge-watch = {
      description = "Re-arm battery charging when the EC stops charging on AC";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      unitConfig.ConditionPathExists = [
        "/sys/class/power_supply/${cfg.battery}"
        "/sys/class/power_supply/${cfg.ac}"
      ];

      environment = {
        BAT = "/sys/class/power_supply/${cfg.battery}";
        AC = "/sys/class/power_supply/${cfg.ac}";
        INTERVAL = toString cfg.interval;
        WINDOW = toString cfg.window;
        MIN_RISE_PERMILLE = toString cfg.minRisePermille;
        MIN_RISE = toString cfg.minRise;
        COOLDOWN = toString cfg.cooldown;
        MAX_COOLDOWN = toString cfg.maxCooldown;
        MAX_ATTEMPTS = toString cfg.maxAttempts;
        RESET_DWELL = toString cfg.resetDwell;
        VERIFY_WAIT = toString cfg.verifyWait;
        VERIFY_POLL = toString cfg.verifyPoll;
        SUSTAINED_SECONDS = toString cfg.sustainedSeconds;
        DRY_RUN = boolToInt cfg.dryRun;
        LEAVE_WORKING_MODE = boolToInt cfg.leaveWorkingMode;
        ENABLE_AC_REBIND = boolToInt cfg.enableAcRebind;
        AC_DEVICE = cfg.acDevice;
        ENABLE_BATTERY_REBIND = boolToInt cfg.enableBatteryRebind;
        BAT_DEVICE = cfg.batteryDevice;
        ENABLE_UCSI_RESET = boolToInt cfg.enableUcsiReset;
        UCSI_DEVICE = cfg.ucsiDevice;
        UCSI_DRIVER = cfg.ucsiDriver;
        ENABLE_DELL_MODES = boolToInt cfg.enableDellModes;
        ENABLE_SUSPEND_RESET = boolToInt cfg.enableSuspendReset;
        SUSPEND_SECONDS = toString cfg.suspendSeconds;
        SUSPEND_AFTER_FAILURES = toString cfg.suspendAfterFailures;
        ENABLE_EC_RESET = boolToInt cfg.enableEcReset;
        EC_DEVICE = cfg.ecDevice;
        ENABLE_REBOOT_RESET = boolToInt cfg.enableRebootReset;
        REBOOT_BELOW_CAPACITY = toString cfg.rebootBelowCapacity;
        REBOOT_COOLDOWN = toString cfg.rebootCooldown;
        NOTIFY_SCRIPT = if cfg.notifyScript == null then "" else cfg.notifyScript;
        STATE_DIR = "/var/lib/battery-recharge-watch";
        TAG = "battery-recharge-watch";
      };

      # The service must be able to write /sys and to load/unload modules, so
      # it runs as root; everything else is locked down. StateDirectory keeps
      # the restore/last-tier/reboot-history files writable.
      serviceConfig = {
        Type = "simple";
        ExecStart = "${script}/bin/battery-recharge-watch";
        Restart = "always";
        RestartSec = 5;
        TimeoutStopSec = 20;
        StateDirectory = "battery-recharge-watch";
        SupplementaryGroups = cfg.notifyGroups;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelLogs = true;
        RemoveIPC = true;
        KeyringMode = "private";
      };
    };
  };
}
