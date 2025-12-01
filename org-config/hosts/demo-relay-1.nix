{ config, pkgs, ... }:
{
  imports = [
    ../../modules/azure.nix
  ];

  time.timeZone = "Europe/Brussels";
  boot.kernelPackages = pkgs.linuxPackages_latest;
  settings = {
    network.host_name = "demo-relay-1";
    disko.diskDevice = "/dev/disk/by-id/scsi-360022480017cb9e6477c4bc84920b19c";
    reverse_tunnel.relay.enable = true;
    crypto.encrypted_opt.enable = true;
  };

  disko.devices = {
    # encrypted data disk
    disk.data = {
      device = "/dev/disk/by-id/scsi-360022480978f31128ae09f3375f42a71";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
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
}
