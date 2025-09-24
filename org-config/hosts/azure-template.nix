{
  imports = [
    ../../modules/azure.nix
  ];

  time.timeZone = "Europe/Brussels";
  settings = {
    network.host_name = "azure-template";
    docker.enable = true;
    reverse_tunnel.enable = true;
    services = {
      traefik.enable = true;
    };
  };
}
