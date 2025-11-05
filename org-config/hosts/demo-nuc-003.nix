{ config, ... }:
{
  time.timeZone = "Europe/Brussels";
  settings = {
    hardwarePlatform = config.settings.hardwarePlatforms.nuc;
    disko.diskDevice = "/dev/disk/by-id/nvme-TS512GMTE510T_F104970068";
    network.host_name = "demo-nuc-003";
    boot.mode = "uefi";
    reverse_tunnel.enable = true;
    crypto.encrypted_opt.enable = true;
    docker.enable = true;
    services = {
      traefik = {
        enable = true;
        content_type_nosniff_enable = false;
      };
      deployment_services = {
        update_demo_app_config.enable = true;
      };
    };
  };
}
