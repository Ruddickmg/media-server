{
  description = "NixOS media server - Plex + *arr suite + Deluge";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
    in {
      nixosConfigurations.media-server = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/media-server/default.nix
        ];
      };
    };
}
