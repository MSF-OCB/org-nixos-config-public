{ config, ... }:
{
  time.timeZone = "Europe/Brussels";
  settings = {
    hardwarePlatform = config.settings.hardwarePlatforms.nuc;
    disko.diskDevice = "/dev/disk/by-id/ata-DEMSR-A28M41BC1DC-27_YCA11806020070096";
    network.host_name = "demo-nuc-004";
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
