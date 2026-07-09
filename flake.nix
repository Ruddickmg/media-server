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
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      disko,
      declarr,
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
        specialArgs = { inherit pkgs-unstable declarr; };
        modules = [
          disko.nixosModules.disko
          declarr.nixosModules.default
          ./hosts/media-server/disko.nix
          ./hosts/media-server/default.nix
        ];
      };

      nixosConfigurations.media-server-ci = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-unstable declarr; };
        modules = [
          disko.nixosModules.disko
          declarr.nixosModules.default
          ./hosts/media-server/disko.nix
          ./hosts/media-server/default.nix

        ];
      };
    };
}
