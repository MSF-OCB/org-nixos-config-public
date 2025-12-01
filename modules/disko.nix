{ config, lib, ... }:
{
  options.settings.disko = {
    enableDefaultConfig = lib.mkEnableOption "the generic disko module" // {
      default = true;
    };

    diskDevice = lib.mkOption {
      type = lib.types.str;
      # TODO remove the default
      default = "/dev/disk/by-id/TODO";
      example = ''
        /dev/disk/by-id/nvme-eui.128691286912869
      '';
      description = ''
        The path to the disk device.
      '';
    };
  };

  config = lib.mkIf config.settings.disko.enableDefaultConfig {
    disko.devices = {
      # Changing the name of the disk requires changing the partition labels!
      # See /dev/disk/by-partlabel/
      disk.main = {
        device = config.settings.disko.diskDevice;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            # Reserve some space for the grub MBR
            mbr = {
              priority = 1;
              size = "1M";
              type = "EF02";
            };
            ESP = {
              priority = 2;
              label = "efi";
              size = "2G";
              type = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b";
              content = {
                type = "filesystem";
                format = "vfat";
                extraArgs = [
                  "-F"
                  "32"
                  "-n"
                  "EFI"
                ];
                mountpoint = "/boot/efi";
                mountOptions = [
                  "defaults"
                  "relatime"
                  "umask=0077"
                  "noauto"
                  "x-systemd.automount"
                  "x-systemd.idle-timeout=5min"
                ];
              };
            };
            nixos_boot = {
              priority = 3;
              label = "nixos_boot";
              size = "2G";
              content = {
                type = "filesystem";
                format = "ext4";
                extraArgs = [
                  "-m"
                  "0"
                  "-L"
                  "nixos_boot"
                ];
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                  "relatime"
                  "noauto"
                ];
              };
            };
            nixos_lvm = {
              priority = 4;
              label = "nixos_lvm";
              size = "100%";
              # Linux LVM
              type = "E6D6D379-F507-44C2-A23C-238F2A3DF928";
              content = {
                type = "lvm_pv";
                vg = "LVMVolGroup";
              };
            };
          };
        };
      };
      lvm_vg."LVMVolGroup" = {
        type = "lvm_vg";
        lvs = {
          nixos_root = {
            size = "25G";
            content = {
              type = "filesystem";
              format = "ext4";
              extraArgs = [
                "-L"
                "nixos_root"
              ];
              mountpoint = "/";
              mountOptions = [
                "defaults"
                "noatime"
                "acl"
              ];
            };
          };
          nixos_data = {
            size = "100%FREE";
            content = {
              type = "luks";
              name = "decrypted";
              initrdUnlock = false;
              extraFormatArgs = [ "--type luks2" ];
              settings = {
                keyFile = "${config.settings.system.secrets.dest_directory}/keyfile";
                allowDiscards = true;
                bypassWorkqueues = true;
              };
              additionalKeyFiles = [
                # This file is generated at install time and added to the disk by disko.
                # It should never end up on the actual system, it is there only for recovery
                # purposes.
                "${config.settings.system.secrets.dest_directory}/rescue-keyfile"
              ];
              content = {
                type = "filesystem";
                format = "ext4";
                extraArgs = [
                  "-L"
                  "nixos_data"
                ];
                # We mount this partition using a systemd mount unit, so we don't
                # add it to fstab. Otherwise it will get mounted too early.
                #mountpoint = "/opt";
                mountOptions = [
                  "defaults"
                  "noatime"
                  "nosuid"
                  "nodev"
                  "noexec"
                ];
              };
            };
          };
        };
      };
    };
  };
}
