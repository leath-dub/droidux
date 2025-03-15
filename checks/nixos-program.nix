{
  imports = [../module.nix];
  programs.droidux = {
    enable = true;
  };

  boot.isContainer = true;
  system.stateVersion = "24.11";
}
