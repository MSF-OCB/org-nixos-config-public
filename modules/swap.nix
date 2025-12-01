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
        type = lib.types.ints.between 0 30;
        default = 1;
        description = "Size of the swap partition in GiB.";
      };
    };
  };

  config = {

    zramSwap = lib.mkIf (!cfg.diskSwap.enable) {
      enable = true;
      algorithm = "zstd";
      memoryPercent = 40;
    };

    boot.kernelParams = lib.mkIf cfg.diskSwap.enable [
      "zswap.enabled=1"
      "zswap.shrinker_enabled=1"
      "zswap.max_pool_percent=30"
      "zswap.zpool=zsmalloc"
      "zswap.compressor=zstd"
    ];

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
