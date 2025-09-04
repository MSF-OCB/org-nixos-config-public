{ config, lib, ... }:

let
  cfg = config.settings.virtualbox;
in

{
  options.settings.virtualbox = {
    enable = lib.mkEnableOption "the VirtualBox guest services";
  };

  config = lib.mkIf cfg.enable {
    settings.hardwarePlatform = config.settings.hardwarePlatforms.virtualbox;
  };
}
