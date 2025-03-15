{
  description = "Droidux - Let your Linux device inherit the hardware components of your android device.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = inputs @ {nixpkgs, ...}: let
    forAllSystems = nixpkgs.lib.genAttrs [
      "aarch64-linux"
      "x86_64-linux"
    ];
  in {
    packages = forAllSystems (system: {default = nixpkgs.legacyPackages.${system}.callPackage ./pkg {};});
    nixosModules.default = import ./module.nix;
    checks = forAllSystems (system: {
      nixosProgram =
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [./checks/nixos-program.nix];
        })
        .config
        .system
        .build
        .toplevel;
    });
  };
}
