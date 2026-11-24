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
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      disko,
      declarr,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = pkgs-unstable.lib;
      pkgs-unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      tailscaleStable =
        let
          inherit (pkgs-unstable)
            fetchurl
            getent
            iproute2
            iptables
            makeWrapper
            procps
            shadow
            stdenv
            ;
          version = "1.104.7";
        in
        stdenv.mkDerivation {
          pname = "tailscale";
          inherit version;
          # Pinned official stable tarball and its published checksum.
          src = fetchurl {
            url = "https://pkgs.tailscale.com/stable/tailscale_${version}_amd64.tgz";
            hash = "sha256-5WaT/3SmTyWRt+gZwoBjWhAKrh3fsO8Fj80FK3zY0Ww=";
          };
          sourceRoot = "tailscale_${version}_amd64";

          nativeBuildInputs = [ makeWrapper ];
          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            mkdir -p "$out/bin" "$out/lib/systemd/system"
            install -D -m 0755 tailscale "$out/bin/tailscale"
            install -D -m 0755 tailscaled "$out/bin/tailscaled"

            # Match nixpkgs: tailscaled shells out to these tools at runtime.
            wrapProgram "$out/bin/tailscaled" \
              --prefix PATH : ${
                lib.makeBinPath [
                  getent
                  iproute2
                  iptables
                  shadow
                ]
              } \
              --suffix PATH : ${lib.makeBinPath [ procps ]}

            # The official unit expects a distro layout and
            # /etc/default/tailscaled. NixOS supplies PORT/FLAGS as service
            # Environment, so only the binary paths need rewriting.
            sed -e "s#/usr/sbin#$out/bin#g" -e "/^EnvironmentFile/d" \
              systemd/tailscaled.service \
              > "$out/lib/systemd/system/tailscaled.service"
            chmod 0444 "$out/lib/systemd/system/tailscaled.service"

            runHook postInstall
          '';

          meta = {
            homepage = "https://tailscale.com";
            description = "Node agent for Tailscale, a mesh VPN built on WireGuard";
            changelog = "https://tailscale.com/changelog#client";
            license = lib.licenses.bsd3;
            mainProgram = "tailscale";
          };
        };
      # Local version pins ahead of nixpkgs (see pkgs/*/default.nix for why).
      # Exposed as flake packages so CI can push just these to the binary
      # cache — same pkgs-unstable.callPackage the service modules use, so
      # the store paths match what the system closure builds.
      localPkgs = {
        beszel = pkgs-unstable.callPackage ./pkgs/beszel { };
        cleanuparr = pkgs-unstable.callPackage ./pkgs/cleanuparr { };
        cross-seed = pkgs-unstable.callPackage ./pkgs/cross-seed { };
        seerr = pkgs-unstable.callPackage ./pkgs/seerr { };
        unpackerr = pkgs-unstable.callPackage ./pkgs/unpackerr { };
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
              mgr.prepend_keymap = [
                {
                  on = "M";
                  run = "plugin mount";
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
      packages.${system} = localPkgs;

      nixosConfigurations.media-server = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit pkgs-unstable declarr tailscaleStable; };
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
        specialArgs = { inherit pkgs-unstable declarr tailscaleStable; };
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
