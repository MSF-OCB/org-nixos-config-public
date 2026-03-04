{ config, lib, ... }:

let
  cfg = config.settings.hetzner;
in
{
  options.settings.hetzner = {
    enable = lib.mkEnableOption "Settings for Hetzner servers";
    static_ip = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };
  config = lib.mkIf cfg.enable {
    networking.nameservers = lib.mkIf cfg.static_ip [
      "185.12.64.1"
      "185.12.64.2"
      "1.1.1.1"
      "8.8.8.8"
    ];
    settings = {
      hardwarePlatform = config.settings.hardwarePlatforms.hetzner;
      system.isMbr = false;
      boot.mode = "uefi";
    };
  };
}
