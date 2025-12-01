{ config, lib, ... }:

let
  cfg = config.settings.syno_vm;
in

{
  options.settings.syno_vm = {
    enable = lib.mkEnableOption "the QEMU guest services for Synology VMs";
  };

  config = lib.mkIf cfg.enable {
    settings.hardwarePlatform = config.settings.hardwarePlatforms.synology;
  };
}
