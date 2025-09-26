{ config, ... }:
{
  time.timeZone = "Europe/Brussels";
  settings = {
    hardwarePlatform = config.settings.hardwarePlatforms.nuc;
    disko.diskDevice = "/dev/disk/by-id/nvme-eui.000000000000000100a0752551f8451a";
    network.host_name = "demo-installer";
    boot.mode = "uefi";
    reverse_tunnel.enable = true;
    crypto.encrypted_opt.enable = true;
    docker.enable = true;
  };
}
