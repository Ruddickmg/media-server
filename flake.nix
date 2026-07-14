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
    herdr = {
      url = "github:ogulcancelik/herdr/v0.7.3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      disko,
      declarr,
      herdr,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs-unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      nixosConfigurations.media-server = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-unstable declarr herdr; };
        modules = [
          disko.nixosModules.disko
          declarr.nixosModules.default
          home-manager.nixosModules.home-manager
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "hm-backup";
              users.media-server = {
                home.stateVersion = "24.05";
                programs.btop = {
                  enable = true;
                  settings = {
                    color_theme = "gruvbox_dark_v2";
                    theme_background = false;
                  };
                };
              };
            };
          }
          ./hosts/media-server/disko.nix
          ./hosts/media-server/default.nix
        ];
      };

      nixosConfigurations.media-server-ci = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-unstable declarr herdr; };
        modules = [
          disko.nixosModules.disko
          declarr.nixosModules.default
          home-manager.nixosModules.home-manager
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "hm-backup";
              users.media-server = {
                home.stateVersion = "24.05";
                programs.btop = {
                  enable = true;
                  settings = {
                    color_theme = "gruvbox_dark_v2";
                    theme_background = false;
                  };
                };
              };
            };
          }
          ./hosts/media-server/disko.nix
          ./hosts/media-server/default.nix

        ];
      };
    };
}
