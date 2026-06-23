{
  description = "DevShell for My Scripts";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachSystem flake-utils.lib.allSystems (system: let
      pkgs = import nixpkgs {
        inherit system;

        config.allowUnfree = true;
      };
    in {
      devShells.default = pkgs.mkShell {
        name = "scripts";
        packages = with pkgs; [
          gh
          git
          jq
          p7zip
        ];
      };
    });
}
