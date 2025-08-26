{ config, ... }:
{
  time.timeZone = "Europe/Brussels";
  settings = {
    hardwarePlatform = config.settings.hardwarePlatforms.nuc;
    network.host_name = "demo-host";
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
      zabbixAgent.enable = true;
    };
  };
}
