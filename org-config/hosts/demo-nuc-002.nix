{ config, pkgs, ... }:
{
  time.timeZone = "Europe/Brussels";
  settings = {
    hardwarePlatform = config.settings.hardwarePlatforms.nuc;
    disko.diskDevice = "/dev/disk/by-id/ata-DGM28-A28D81BCBQC-27_20180203AA0016207243";
    network.host_name = "demo-nuc-002";
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
    autoDecrypt.enable = true;
  };
}
