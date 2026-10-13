{
  description = "Runtime environment for sync_archive_forks.sh";
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
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
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
      # sync_archive_forks.sh re-execs itself inside this shell.
      devShells.default = pkgs.mkShell {
        name = "sync-archive-forks";
        packages = with pkgs; [
          cargo-xwin
          cargo-zigbuild
          gh
          git
          jq
          llvmPackages.clang-unwrapped
          llvmPackages.lld
          llvmPackages.llvm
          pkg-config
          rust
          # RUSTC_WRAPPER: caches rustc (and cc-rs C) outputs across repos/runs.
          sccache
          zig
          # alsa-sys (filmcraft, deckcraft) finds libasound via pkg-config.
          alsa-lib.dev
        ];
      };
    });
}
