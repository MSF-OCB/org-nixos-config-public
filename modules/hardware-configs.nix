{
  lib,
  modulesPath,
  config,
  options,
  ...
}:

let
  platform = config.settings.hardwarePlatform;
  platforms = config.settings.hardwarePlatforms;
in

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  options.settings = {
    hardwarePlatforms = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = {
        aws = "aws";
        azure = "azure";
        nuc = "nuc";
        laptop = "laptop";
        synology = "synology";
        thinkserver = "thinkserver";
        virtualbox = "virtualbox";
        vmware = "vmware";
        hetzner = "hetzner";

        none = "none";
      };
    };

    hardwarePlatform = lib.mkOption {
      type = lib.types.enum (lib.attrValues platforms);
    };
  };

  config = {
    hardware.enableRedistributableFirmware = true;

    boot =
      let
        platformDependent = {
          aws = {
            initrd.availableKernelModules = [ "nvme" ];
          };
          azure = {
            initrd.availableKernelModules = [ "sd_mod" ];
          };
          nuc = {
            initrd.availableKernelModules = [
              "ahci"
              "nvme"
              "sd_mod"
              "sdhci_pci"
              "xhci_pci"
            ];
          };
          laptop = {
            initrd.availableKernelModules = [
              "ahci"
              "ehci_pci"
              "nvme"
              "rtsx_pci_sdmmc"
              "sd_mod"
              "sr_mod"
              "usb_storage"
              "xhci_pci"
            ];
          };
          synology = {
            # https://github.com/NixOS/nixpkgs/issues/76980
            initrd.availableKernelModules = [
              "ata_piix"
              "sd_mod"
              "sr_mod"
              "uhci_hcd"
              "virtio_pci"
              "virtio_scsi"
            ];
          };
          thinkserver = {
            initrd.availableKernelModules = [
              "ahci"
              "megaraid_sas"
              "sd_mod"
              "xhci_pci"
            ];
          };
          virtualbox = {
            # https://github.com/NixOS/nixpkgs/issues/76980
            initrd.availableKernelModules = [
              "ahci"
              "ohci_pci"
              "sd_mod"
              "sr_mod"
              "virtio_pci"
              "virtio_scsi"
              "xhci_pci"
            ];
          };
          vmware = {
            initrd.availableKernelModules = [
              "ahci"
              "ata_piix"
              "floppy"
              "mptspi"
              "sd_mod"
              "sr_mod"
              "vmw_pvscsi"
            ];
          };
          hetzner = {
            initrd.availableKernelModules = [
              "nvme"
              "ahci"
              "xhci_pci"
              "usbhid"
              "usb_storage"
              "sd_mod"
              "sr_mod"
            ];
          };
        };

        platformIndependent = {
          # We always want to load dm-snapshot, otherwise the kernel gets stuck when it sees LVM snapshots
          initrd.kernelModules = [ "dm-snapshot" ];
        };
      in
      # Merge the platform-independent and the correct platform-dependent settings together
      lib.mkMerge (
        [ platformIndependent ]
        ++
          # Make sure that we throw an error in case a platform is missing from the
          # bootSettings attrset.
          lib.optional (platform != platforms.none) platformDependent.${platform}
      );

    # https://github.com/NixOS/nixpkgs/issues/91300
    virtualisation.hypervGuest.enable = lib.mkIf (platform == platforms.synology) (lib.mkForce false);
    services.qemuGuest.enable = lib.mkIf (platform == platforms.synology) true;

    virtualisation.vmware.guest = lib.mkIf (platform == platforms.vmware) {
      enable = true;
      headless = true;
    };

    virtualisation.virtualbox.guest = {
      enable = platform == platforms.virtualbox;
    }
    //
      # TODO: remove this once we're on 24.05 everywhere
      # We need to set this option on NixOS < 24.05. Starting from 24.05, X11
      # support for virtualbox was dropped altogether and the option was removed.
      lib.optionalAttrs (options.virtualisation.virtualbox.guest ? x11) {
        x11 = false;
      };

    networking.useDHCP = lib.mkDefault true;
    hardware.cpu.intel.updateMicrocode = lib.mkIf (lib.elem platform [
      platforms.nuc
      platforms.laptop
      platforms.thinkserver
    ]) config.hardware.enableRedistributableFirmware;
    hardware.cpu.amd.updateMicrocode = lib.mkIf (lib.elem platform
      [ ]
    ) config.hardware.enableRedistributableFirmware;
  };
}
