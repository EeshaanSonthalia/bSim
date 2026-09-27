{
  description = "bSim OpenEXRCore development environment";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/5157396cfd0b4de9f1f83166c1f25e3ef45b180d";
  outputs = { nixpkgs, ... }:
    let pkgs = import nixpkgs { system = "aarch64-darwin"; };
    in {
      devShells.aarch64-darwin.default = pkgs.mkShellNoCC {
        packages = [ pkgs.openexr pkgs.pkg-config pkgs.ffmpeg pkgs.just ];
        BSIM_OPENEXR = "${pkgs.openexr}";
        BSIM_OPENEXR_DEV = "${pkgs.openexr.dev}";
        DEVELOPER_DIR = "/Library/Developer/CommandLineTools";
      };
    };
}
