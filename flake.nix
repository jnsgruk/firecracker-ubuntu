{
  description = "embr - simple automation for booting Ubuntu microVMs with firecracker";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nix-formatter-pack.url = "github:Gerschtli/nix-formatter-pack";
    nix-formatter-pack.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self
    , nixpkgs
    , nix-formatter-pack
    , ...
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        # "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      pkgsForSystem = system: (import nixpkgs {
        inherit system;
        overlays = [ self.overlay ];
      });
    in
    {
      overlay = final: _prev: {
        embr-unwrapped = (final.writeScriptBin "embr" (builtins.readFile ./embr)).overrideAttrs (old: {
          buildCommand = "${old.buildCommand}\n patchShebangs $out";
        });

        extract-vmlinux-unwrapped = (final.writeScriptBin "extract-vmlinux" (builtins.readFile ./util/extract-vmlinux)).overrideAttrs (old: {
          buildCommand = "${old.buildCommand}\n patchShebangs $out";
        });

        embr = final.symlinkJoin {
          name = "embr";
          paths = (with final; [
            embr-unwrapped
            extract-vmlinux-unwrapped
          ])
          ++ (with final; [
            curl
            dnsmasq
            e2fsprogs
            firecracker
            iptables
            jq
            killall
            openssh
            openssl
            yq-go
            # The following are dependencies of the extract-vmlinuz script
            binutils
            bzip2
            gzip
            lzip
            lzop
            lz4
            zstd
            unzip
            xz
          ]);
          buildInputs = [ final.makeWrapper ];
          postBuild = "wrapProgram $out/bin/embr --prefix PATH : $out/bin";
        };
      };

      packages = forAllSystems (system: {
        inherit (pkgsForSystem system) embr;
      });

      defaultPackage = forAllSystems (system: (pkgsForSystem system).embr);

      formatter = forAllSystems (system:
        nix-formatter-pack.lib.mkFormatter {
          pkgs = nixpkgs.legacyPackages.${system};
          config.tools = {
            deadnix.enable = true;
            nixpkgs-fmt.enable = true;
            statix.enable = true;
          };
        }
      );
    };
}
