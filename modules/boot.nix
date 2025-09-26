{ config, lib, ... }:

let
  cfg = config.settings.boot;
in

with lib;

{
  options = {
    settings.boot = {
      mode = mkOption {
        type = types.enum (attrValues cfg.modes);
        description = "Boot in either legacy or UEFI mode.";
      };

      separate_partition = mkOption {
        type = types.bool;
        default = true;
        description = "Whether /boot is a separate partition.";
      };

      modes = mkOption {
        type = with types; attrsOf str;
        default = { legacy = "legacy"; uefi = "uefi"; none = "none"; };
        readOnly = true;
      };
    };
  };

  config = {
    boot = {
      initrd.systemd.enable = true;

      tmp = {
        cleanOnBoot = true;
        useTmpfs = true;
      };

      loader =
        let
          inherit (cfg) mode;
        in
        mkIf (mode != cfg.modes.none) (mkMerge [
          (mkIf (mode == cfg.modes.legacy) {
            grub = {
              enable = true;
              configurationLimit = 15;
            };
          })
          (mkIf (mode == cfg.modes.uefi) {
            systemd-boot = {
              enable = true;
              editor = false;
              configurationLimit = 15;
            };
            efi = {
              # Keep this to false, otherwise sd-boot sets itself as the first
              # UEFI boot entry, but we want to boot from USB when a USB drive
              # is plugged in.
              canTouchEfiVariables = false;
              efiSysMountPoint = config.fileSystems."/boot/efi".mountPoint;
            };
          })
        ]);

      kernelParams = [
        # Overwrite free'd memory
        #"page_poison=1"

        # Disable legacy virtual syscalls, this can cause issues with older Docker images
        #"vsyscall=none"

        # Disable hibernation (allows replacing the running kernel)
        "nohibernate"
      ];

      kernel.sysctl = {
        # Reboot after 10 min following a kernel panic
        "kernel.panic" = "10";

        # Disable bpf() JIT (to eliminate spray attacks)
        #"net.core.bpf_jit_enable" = mkDefault false;

        # ... or at least apply some hardening to it
        "net.core.bpf_jit_harden" = true;

        # Raise ASLR entropy
        "vm.mmap_rnd_bits" = 32;
      };
    };
  };
}
