{
  time.timeZone = "Europe/Brussels";

  settings = {
    boot.mode = "uefi";
    reverse_tunnel.enable = true;
    crypto.encrypted_opt.enable = true;
    vmware.enable = true;
    docker.enable = true;
    services = {
      traefik = {
        enable = true;
      };
    };
    network = {
      host_name = "nixos-test";
      static_ifaces.ens192 = {
        address = "172.16.0.6";
        prefix_length = 16;
        gateway = "172.16.0.100";
        fallback = false;
      };
    };
  };
}
