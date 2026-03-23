{
  nixpkgs.hostPlatform = "x86_64-linux";
  settings.network.host_name = "demo001";
  environment.etc."nix/nix.conf".replaceExisting = true;
}
