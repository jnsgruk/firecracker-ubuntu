{
  description = "embr - simple automation for booting Ubuntu microVMs with firecracker";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};

        deps = with pkgs; [
          curl
          dnsmasq
          e2fsprogs
          firecracker
          iptables
          jq
          killall
          openssh
          openssl
          yq
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
        ];

        embr = (pkgs.writeScriptBin "embr" (builtins.readFile ./embr)).overrideAttrs (old: {
          buildCommand = "${old.buildCommand}\n patchShebangs $out";
        });

        extract-vmlinux =
          (pkgs.writeScriptBin "extract-vmlinux"
            (builtins.readFile ./util/extract-vmlinux))
          .overrideAttrs (
            old: {
              buildCommand = "${old.buildCommand}\n patchShebangs $out";
            }
          );
      in rec {
        defaultPackage = packages.embr;

        packages.embr = pkgs.symlinkJoin {
          name = "embr";
          paths = [embr extract-vmlinux] ++ deps;
          buildInputs = [pkgs.makeWrapper];
          postBuild = "wrapProgram $out/bin/embr --prefix PATH : $out/bin";
        };
      }
    );
}
