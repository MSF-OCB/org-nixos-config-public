{ config, pkgs, ... }:
{
  time.timeZone = "Europe/Brussels";
  environment.systemPackages = [
    pkgs.nodejs_20
  ];
  settings = {
    hardwarePlatform = config.settings.hardwarePlatforms.nuc;
    disko.diskDevice = "/dev/disk/by-id/nvme-TS512GMTE510T_F145120155";
    network.host_name = "demo-nuc-001";
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
