{
  pkgs,
  config,
  lib,
  ...
}: let
  cfg = config.programs.droidux;
  udev = config.services.udev;
  fileContents = dir:
    builtins.concatStringsSep "\n" (builtins.map (name: builtins.readFile (dir + "/${name}")) (builtins.attrNames (builtins.readDir dir)));
in {
  options.programs.droidux = {
    enable = lib.mkEnableOption "Whether to install droidux and setup adb, udev";
    package = lib.mkOption {
      type = with lib.types; nullOr package;
      default = pkgs.callPackage ./pkg {};
      defaultText = lib.literalExpression "pkgs.droidux";
      description = lib.mdDoc "droidux package to use";
    };
  };
  config = lib.mkIf cfg.enable {
    services.udev = lib.mkIf udev.enable {
      extraRules = fileContents ./rules.d;
      extraHwdb = fileContents ./hwdb.d;
    };

    environment.systemPackages = [cfg.package pkgs.android-tools];
  };
}
