{ config, lib, ... }:

let
  cfg = config.settings.system;
in

{
  options.settings.system = {
    diskSwap = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      size = lib.mkOption {
        type = lib.types.ints.between 0 10;
        default = 1;
        description = "Size of the swap partition in GiB.";
      };
    };
  };

  config = {
    zramSwap = {
      enable = true;
      algorithm = "zstd";
      memoryPercent = 40;
    };

    swapDevices = lib.mkIf cfg.diskSwap.enable [
      {
        device = "/swap.img";
        size = 1024 * cfg.diskSwap.size;
        priority = 0;
        randomEncryption.enable = true;
      }
    ];
  };
}
