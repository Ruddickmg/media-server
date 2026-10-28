{
  lib,
  pkgs,
  tuios,
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

    # Single source of truth for the hard-link topology. All four/five roots live
    # on the @media btrfs subvolume, so library files, download-folder copies,
    # and cross-seed links share inodes. delete-media and delete-media-watch both
    # derive their search scope and their empty-dir guard list from this, so the
    # two scripts can never drift.
    deleteMedia = {
      rootPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/media/downloads/completed"
          "/media/downloads/xseeds"
          "/media/movies"
          "/media/tv"
          "/media/music"
        ];
        description = "Root directories whose files participate in the hard-link topology";
      };
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

  programs.yazi = {
    enable = true;
    shellWrapperName = "yy";
    extraPackages = [ pkgs.fzf ];
    plugins = {
      piper = pkgs.yaziPlugins.piper;
      mount = pkgs.fetchFromGitHub {
        owner = "PHONE1X";
        repo = "lsblk-mount.yazi";
        rev = "master";
        hash = "sha256-HjIDBe2lG9w+tRalfdYIwOK2kRuVPFDPq37HqEdM7UQ=";
      };
      whoosh = {
        package = pkgs.fetchFromGitHub {
          owner = "WhoSowSee";
          repo = "whoosh.yazi";
          rev = "d6ede9895a0e14b1bb1d65cd0eb783f92f2fc522";
          hash = "sha256-LwugSeuG3+PmPW9KFvRThqx+g792CmUnw+vY6wSZJoo=";
        };
        setup = true;
        settings = {
          bookmarks = [
            {
              tag = "Nixos";
              path = "~/Nixos";
              key = "n";
            }
            {
              tag = "Projects";
              path = "/var/www";
              key = "p";
            }
            {
              tag = "Nvim";
              path = "~/.config/nvim";
              key = "v";
            }
            {
              tag = "Downloads";
              path = "~/Downloads";
              key = "o";
            }
            {
              tag = "Ubuntu";
              path = "/run/media/moon/4e47e3ee-f1ba-43ad-8805-bf04119ca88e/home/grant";
              key = "u";
            }
          ];
          jump_notify = false;
          path_truncate_enabled = true;
          path_max_depth = 3;
        };
      };
    };
    keymap = {
      mgr.prepend_keymap = [
        {
          on = "M";
          run = "plugin mount";
          desc = "Mount partitions";
        }
        {
          on = "[";
          run = "plugin whoosh jump_by_key";
          desc = "Jump bookmark by key";
        }
        {
          on = "}";
          run = "plugin whoosh jump_by_fzf";
          desc = "Fuzzy search bookmarks";
        }
        {
          on = [ "]" "a" ];
          run = "plugin whoosh save";
          desc = "Bookmark hovered file/dir";
        }
        {
          on = [ "]" "A" ];
          run = "plugin whoosh save_cwd";
          desc = "Bookmark current directory";
        }
        {
          on = [ "]" "t" ];
          run = "plugin whoosh save_temp";
          desc = "Temp bookmark hovered file/dir";
        }
        {
          on = [ "]" "T" ];
          run = "plugin whoosh save_cwd_temp";
          desc = "Temp bookmark current directory";
        }
        {
          on = [ "]" "f" ];
          run = "plugin whoosh jump_by_fzf";
          desc = "Jump bookmark by fzf";
        }
        {
          on = [ "]" "d" ];
          run = "plugin whoosh delete_by_key";
          desc = "Delete bookmark by key";
        }
        {
          on = [ "]" "D" ];
          run = "plugin whoosh delete_by_fzf";
          desc = "Delete bookmarks by fzf";
        }
        {
          on = [ "]" "C" ];
          run = "plugin whoosh delete_all";
          desc = "Delete all user bookmarks";
        }
        {
          on = [ "]" "r" ];
          run = "plugin whoosh rename_by_key";
          desc = "Rename bookmark by key";
        }
        {
          on = [ "]" "R" ];
          run = "plugin whoosh rename_by_fzf";
          desc = "Rename bookmark by fzf";
        }
      ];
    };
    settings = {
      opener.play = [
        {
          run = "vlc \"$@\"";
          desc = "Open in VLC";
          orphan = true;
          for = "linux";
        }
      ];
      manager = {
        ratio = [
          1
          4
          3
        ];
        sort_by = "natural";
        sort_sensitive = true;
        sort_reverse = false;
        sort_dir_first = true;
        linemode = "none";
        show_hidden = true;
        show_symlink = true;
      };
      plugin = {
        prepend_previewers = [
          {
            url = "*.tar*";
            run = ''piper --format=url -- tar tf "$1"'';
          }
          {
            url = "*/";
            run = ''piper -- eza -TL=3 --color=always --icons=always --group-directories-first --no-quotes "$1"'';
          }
          {
            url = "*.md";
            run = ''piper -- CLICOLOR_FORCE=1 glow -w=$w -s=dark "$1"'';
          }
        ];
        append_previewers = [
          {
            url = "*";
            run = ''piper -- hexyl --border=none --terminal-width=$w "$1"'';
          }
        ];
      };
      preview = {
        image_filter = "lanczos3";
        image_quality = 90;
        tab_size = 1;
        max_width = 1000;
        max_height = 1000;
        cache_dir = "";
        ueberzug_scale = 1;
        ueberzug_offset = [
          0
          0
          0
          0
        ];
      };

      tasks = {
        micro_workers = 5;
        macro_workers = 10;
        bizarre_retry = 5;
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
      tuios.packages.${pkgs.system}.default

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
        # /media/downloads/xseeds to exist. Guard list comes from
        # media-server.deleteMedia.rootPaths (shared with delete-media-watch).
        guard_roots=(${
          builtins.concatStringsSep " " (
            [
              "/media"
              "/media/downloads"
              "/media/downloads/incomplete"
            ]
            ++ config.media-server.deleteMedia.rootPaths
          )
        })
        while IFS= read -r d; do
          for g in "''${guard_roots[@]}"; do
            [ "$d" = "$g" ] && continue 2
          done
          rmdir "$d" 2>/dev/null || true
        done < <(find /media -depth -type d -empty)

        echo "deleted ''${#links[@]} hard link(s), freed $((freed / 1024)) MiB"
      '')
    ];
  };
}
