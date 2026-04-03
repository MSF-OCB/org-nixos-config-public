{ ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  settings = {
    network.host_name = "demo001";
    reverse_tunnel.enable = true;
    maintenance = {
      enable = true;
      nixos_upgrade.enable = true;
    };
  };
  networking.hostName = "demo001";
}
