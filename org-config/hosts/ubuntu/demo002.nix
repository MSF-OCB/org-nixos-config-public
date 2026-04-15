{ ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  settings = {
    network.host_name = "demo002";
    reverse_tunnel.enable = true;
  };
  networking.hostName = "demo002";
}
