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
      self,
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
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "hm-backup";
              users.media-server = {
                home.stateVersion = "24.05";
                programs.btop = {
                  enable = true;
                  settings = {
                    color_theme = "gruvbox_material_dark";
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
        specialArgs = { inherit pkgs-unstable declarr tuios; };
        modules = [
          { nixpkgs.hostPlatform = system; }
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
                    color_theme = "gruvbox_material_dark";
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
