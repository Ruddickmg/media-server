{
  description = "NixOS media server - Plex + *arr suite + Deluge";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    declarr = {
      url = "github:upidapi/declarr";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Pinned to the upstream flake rather than nixpkgs: the nixpkgs packages in
    # this repo only ship tuios 0.7.0, which predates the remote-host / [hosts]
    # feature (added in 0.8.0) used to attach to sessions on this machine.
    # nixpkgs is deliberately NOT followed: tuios v0.10.0 builds with
    # GOTOOLCHAIN=local and requires Go >= 1.26.6, while this repo's nixpkgs
    # provides Go 1.26.5. The upstream flake's own locked nixpkgs has 1.26.7.
    tuios = {
      url = "github:Gaurav-Gosain/tuios/v0.10.0";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      disko,
      declarr,
      tuios,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs-unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      home-manager-config = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "hm-backup";
        users.media-server = {
          home.stateVersion = "24.05";
          home.packages = [
            pkgs.fzf
            pkgs.util-linux # Provides 'lsblk' for the mount plugin
            pkgs.udisks2 # Provides 'udisksctl' for the mount plugin
          ];
          programs.btop = {
            enable = true;
            settings = {
              color_theme = "gruvbox_material_dark";
              theme_background = false;
            };
          };
          programs.yazi = {
            enable = true;
            shellWrapperName = "yy";
            plugins = {
              mount = pkgs.fetchFromGitHub {
                owner = "PHONE1X";
                repo = "lsblk-mount.yazi";
                rev = "73e863ff4f0102e0ef6950f14163f0a4963f1cb4";
                hash = "sha256-HjIDBe2lG9w+tRalfdYIwOK2kRuVPFDPq37HqEdM7UQ=";
              };
            };
            keymap = {
              manager.prepend_keymap = [
                {
                  on = "M";
                  run = "plugin mount";
                  block = true; # Required for interactive FZF execution over SSH!
                  desc = "Mount partitions";
                }
              ];
            };
            settings = {
              mgr = {
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
        };
      };
    in
    {
      nixosConfigurations.media-server = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit pkgs-unstable declarr tuios; };
        modules = [
          { nixpkgs.hostPlatform = system; }
          disko.nixosModules.disko
          declarr.nixosModules.default
          home-manager.nixosModules.home-manager
          {
            home-manager = home-manager-config;
          }
          ./hosts/media-server/disko.nix
          ./hosts/media-server/default.nix
        ];
      };

      nixosConfigurations.media-server-ci = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit pkgs-unstable declarr tuios; };
        modules = [
          { nixpkgs.hostPlatform = system; }
          disko.nixosModules.disko
          declarr.nixosModules.default
          home-manager.nixosModules.home-manager
          {
            home-manager = home-manager-config;
          }
          ./hosts/media-server/disko.nix
          ./hosts/media-server/default.nix

        ];
      };
    };
}
