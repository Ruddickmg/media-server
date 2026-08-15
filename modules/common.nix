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
    # the set of declared groups changes; that drift left the persistent @media
    # tree's files on stale numeric gids (the hardlink breakage). Pinning freezes
    # the numbering so it can never renumber again.
    users.groups.media = {
      gid = 993;
    };
    users.groups.dhcpcd = {
      gid = 995;
    };

    systemd.tmpfiles.rules = [
      "d /media 2775 root media"
      "d /media/downloads 2775 root media"
      "d /media/downloads/incomplete 2775 root media"
      "d /media/downloads/completed 2775 root media"
      "d /media/downloads/xseeds 2775 root media"
      "d /media/movies 2775 root media"
      "d /media/tv 2775 root media"
      "d /media/music 2775 root media"

      # Repair the /media tree group after the gid-shift incident: files on the
      # @media subvolume are gid 998 (beszel-agent, empty group) instead of media
      # (993). The *arr services run as gid media; with fs.protected_hardlinks=1,
      # cross-group hardlinks fail, so Radarr silently copies instead of linking.
      # Z (recursive, age-ignoring) forces group media on existing files; mode
      # and uid are left untouched.
      "Z /media/downloads - - media -"
      "Z /media/movies - - media -"
      "Z /media/tv - - media -"
      "Z /media/music - - media -"
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

      # delete-media: delete a media file (or a whole movie/show folder) and
      # every hard link to it. The *arr library dirs, /media/downloads/completed,
      # and /media/downloads/xseeds all live on the @media btrfs subvolume, so
      # rm from the library silently leaves the download-folder and cross-seed
      # copies behind and no space is freed. The script gathers all paths via
      # find -samefile, lists them, asks for confirmation, deletes them, then
      # prunes now-empty folders (never the well-known /media roots, which
      # tmpfiles only recreates on boot).
      (pkgs.writeShellScriptBin "delete-media" ''
        #!/usr/bin/env bash
        set -euo pipefail

        usage() {
          echo "usage: $0 <path under /media>" >&2
          exit 1
        }

        [ "$#" -eq 1 ] || usage
        target="$(realpath -m "$1")"

        # Safety guard: the hard-link topology only spans the @media subvolume,
        # so every reference to a target lives under /media. Refuse anything
        # else rather than -samefile-scanning an arbitrary path.
        case "$target" in
          /media) usage ;;
          /media/*) ;;
          *) echo "error: path must be under /media" >&2; exit 1 ;;
        esac

        [ -e "$target" ] || { echo "error: not found: $target" >&2; exit 1; }

        # Directories cannot be hard-linked on btrfs; only the files within a
        # movie/show folder share inodes with the download dirs. For a directory
        # target, treat every regular file under it as a deletion candidate and
        # let the empty-folder pass below prune the shell afterwards.
        if [ -d "$target" ]; then
          readarray -t files < <(find "$target" -type f)
        else
          files=("$target")
        fi
        [ "''${#files[@]}" -gt 0 ] || { echo "error: no files under $target" >&2; exit 1; }

        # Gather every hard link to each unique inode across /media. The *arr
        # library dirs, /media/downloads/completed, and /media/downloads/xseeds
        # all share the @media subvolume, so a single -xdev -samefile pass finds
        # all references.
        declare -A seen
        links=()
        for f in "''${files[@]}"; do
          key="$(stat -c '%d:%i' "$f")"
          [ -n "''${seen[$key]:-}" ] && continue
          seen[$key]=1
          while IFS= read -r l; do
            links+=("$l")
          done < <(find /media -xdev -samefile "$f")
        done

        freed=$(du -sk "$target" | cut -f1)

        echo "Will delete ''${#links[@]} hard link(s), freeing $((freed / 1024)) MiB:"
        printf '  %s\n' "''${links[@]}"
        read -r -p "Proceed? [y/N] " ans
        case "$ans" in
          y|Y|yes|YES) ;;
          *) echo "aborted" >&2; exit 1 ;;
        esac

        rm -f -- "''${links[@]}"

        # Prune empty folders left behind by the deletion (movie/show shells,
        # emptied download dirs). Never remove the well-known /media roots:
        # tmpfiles only recreates them on boot and the cross-seed daemon expects
        # /media/downloads/xseeds to exist.
        while IFS= read -r d; do
          case "$d" in
            /media|/media/downloads|/media/downloads/incomplete|/media/downloads/completed|/media/downloads/xseeds|/media/movies|/media/tv|/media/music)
              continue ;;
          esac
          rmdir "$d" 2>/dev/null || true
        done < <(find /media -depth -type d -empty)

        echo "deleted ''${#links[@]} hard link(s), freed $((freed / 1024)) MiB"
      '')
    ];
  };
}
