{ modulesPath, config, lib, ... }:

{
  imports = [
    "${modulesPath}/virtualisation/amazon-image.nix"
  ];

  ec2.hvm = true;
  settings = {
    system.isMbr = true;
    hardwarePlatform = config.settings.hardwarePlatforms.aws;
    boot.mode = "none";
    disko.enableDefaultConfig = false;
    # For our AWS servers, we do not need to run the upgrade service during
    # the day.
    # Upgrading during the day can cause the nixos_rebuild_config service to
    # refuse to activate the new config due to an upgraded kernel.
    maintenance.nixos_upgrade.startAt = [ "Tue 03:00" ];
  };
  services.timesyncd.servers = config.networking.timeServers;

  networking.dhcpcd = {
    denyInterfaces = lib.mkForce [ "veth*" "docker*" ];
    allowInterfaces = lib.mkForce [ "en*" "eth*" ];
  };
}
