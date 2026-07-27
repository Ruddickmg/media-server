{
  lib,
  pkgs,
  herdr,
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
    };

    administrators = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "ruddickmg@gmail.com" ];
      description = "Tailscale login emails of administrators granted access to admin-only paths";
    };
  };

  config = {
    users.groups.media = { };

    systemd.tmpfiles.rules = [
      "d /media 2775 root media"
      "d /media/downloads 2775 root media"
      "d /media/downloads/incomplete 2775 root media"
      "d /media/downloads/completed 2775 root media"
      "d /media/downloads/xseeds 2775 root media"
      "d /media/movies 2775 root media"
      "d /media/tv 2775 root media"
      "d /media/music 2775 root media"
    ];

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
      yazi
      zoxide
      starship
      eza
      bat
      btop
      herdr.packages.${pkgs.system}.default
    ];
  };
}
