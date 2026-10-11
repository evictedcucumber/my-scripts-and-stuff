{
  description = "DevShell for My Scripts";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = {
    nixpkgs,
    flake-utils,
    rust-overlay,
    ...
  }:
    flake-utils.lib.eachSystem flake-utils.lib.allSystems (system: let
      pkgs = import nixpkgs {
        inherit system;

        config.allowUnfree = true;
        overlays = [rust-overlay.overlays.default];
      };

      # Stable Rust with the std libs sync_archive_forks.sh cross-builds for.
      rust = pkgs.rust-bin.stable.latest.default.override {
        targets = [
          "x86_64-unknown-linux-gnu"
          "x86_64-pc-windows-msvc"
        ];
      };
    in {
      devShells.default = pkgs.mkShell {
        name = "scripts";
        packages = with pkgs; [
          cargo-xwin
          cargo-zigbuild
          gh
          git
          jq
          lefthook
          p7zip
          llvmPackages.clang-unwrapped
          llvmPackages.lld
          llvmPackages.llvm
          powershell
          rust
          shellcheck
          zig
        ];
        shellHook = ''
          lefthook install
        '';
      };
    });
}
