{ config, lib, ... }:

let
  cfg = config.settings.vmware;
in

{
  options.settings.vmware = {
    enable = lib.mkEnableOption "the VMWare guest services";

    inDMZ = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config = lib.mkIf cfg.enable {
    settings = {
      hardwarePlatform = config.settings.hardwarePlatforms.vmware;

      # For our VMWare servers, we do not need to run the upgrade service during
      # the day.
      # Upgrading during the day can cause the nixos_rebuild_config service to
      # refuse to activate the new config due to an upgraded kernel.
      maintenance.nixos_upgrade.startAt = [ "Tue 03:00" ];
    };

    services.timesyncd.servers = lib.mkIf (!cfg.inDMZ) [ "172.16.0.101" ];

    networking.nameservers =
      if cfg.inDMZ then
        [
          "192.168.50.25"
          "192.168.50.26"
        ]
      else
        [
          "172.16.0.101"
          "172.16.0.102"
        ];
  };
}
