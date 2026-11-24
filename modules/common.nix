{
  lib,
  pkgs,
  pkgs-unstable,
  config,
  ...
}:
let
  inherit (builtins) substring hashString;
  inherit (config.networking) hostName;
  key = prefix: substring 0 32 (hashString "sha256" "${hostName}-${prefix}");
in
{
  options.media-server = {
    tailscaleHostname = lib.mkOption {
      type = lib.types.str;
      default = "media-server.tailbac0df.ts.net";
      description = "Tailscale hostname used for public-facing HTTPS URLs";
    };
    apiKeys = {
      sonarr = lib.mkOption {
        type = lib.types.str;
        default = key "sonarr";
        description = "API key for Sonarr";
      };
      radarr = lib.mkOption {
        type = lib.types.str;
        default = key "radarr";
        description = "API key for Radarr";
      };
      lidarr = lib.mkOption {
        type = lib.types.str;
        default = key "lidarr";
        description = "API key for Lidarr";
      };
      prowlarr = lib.mkOption {
        type = lib.types.str;
        default = key "prowlarr";
        description = "API key for Prowlarr";
      };
      seerr = lib.mkOption {
        type = lib.types.str;
        default = key "seerr";
        description = "API key for Seerr";
      };
      autobrr = lib.mkOption {
        type = lib.types.str;
        default = key "autobrr";
        description = "API key for autobrr";
      };
      cross-seed = lib.mkOption {
        type = lib.types.str;
        default = key "cross-seed";
        description = "API key for cross-seed";
      };
    };

    administrators = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "ruddickmg@gmail.com" ];
      description = "Tailscale login emails of administrators granted access to admin-only paths";
    };

  };

  config = {
    # Pin gids to their current server values. Auto-assigned gids shift whenever
    # the set of declared groups changes; that drift left the persistent media
    # tree's files on stale numeric gids (the hardlink breakage). Pinning freezes
    # the numbering so it can never renumber again.
    users.groups.media = {
      gid = 993;
    };
    users.groups.dhcpcd = {
      gid = 995;
    };

    # The /media/data skeleton is created by modules/storage.nix directly on the
    # raw SSD/HDD mounts. Creating it here (through the union) would race the
    # mergerfs mounts and could fall back to the root filesystem.

    services.udisks2.enable = true;

    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;
      shellAliases = {
        ls = "eza";
        l = "eza";
        la = "eza -a";
        ll = "eza -la";
        cat = "bat";
        metrics = "btop";
      };
    };

    programs.zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    programs.starship = {
      enable = true;
      settings = {
        add_newline = false;
        line_break = {
          disabled = true;
        };
      };
    };

    programs.zsh.interactiveShellInit = ''
      eval "$(starship init zsh)"
    '';

    environment.systemPackages = with pkgs; [
      unzip
      unrar
      p7zip
      git
      ripgrep
      jq
      vim
      zoxide
      starship
      eza
      bat
      btop
      # From nixpkgs-unstable: stable ships 0.7.0, which predates the
      # remote-host / [hosts] feature (added in 0.8.0) used to attach to
      # sessions on this machine.
      pkgs-unstable.tuios

    ];
  };
}
