{ ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  settings = {
    network.host_name = "demo003";
    reverse_tunnel.enable = true;
  };
  networking.hostName = "demo003";
}
