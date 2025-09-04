{ modulesPath, config, lib, ... }:
{
  imports = [
    "${modulesPath}/virtualisation/azure-common.nix"
    "${modulesPath}/virtualisation/azure-image.nix"
  ];

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
  };
  settings = {
    hardwarePlatform = config.settings.hardwarePlatforms.azure;
    boot.mode = config.settings.boot.modes.none;
    system.isMbr = false;
    disko.enableDefaultConfig = false;
    # For our Azure servers, we do not need to run the upgrade service during
    # the day.
    # Upgrading during the day can cause the nixos_rebuild_config service to
    # refuse to activate the new config due to an upgraded kernel.
    maintenance.nixos_upgrade.startAt = [ "Tue 03:00" ];
    network = {
      dhcpcd.enable = false;
    };
  };

  #same as default list but without update_hostname.
  services.cloud-init.settings.cloud_init_modules = [
    "migrator"
    "seed_random"
    "bootcmd"
    "write-files"
    "growpart"
    "resizefs"
    "resolv_conf"
    "ca-certs"
    "rsyslog"
    "users-groups"
  ];

  # same as default list but without "ssh".
  services.cloud-init.settings.cloud_config_modules = [
    "disk_setup"
    "mounts"
    "ssh-import-id"
    "set-passwords"
    "timezone"
    "disable-ec2-metadata"
    "runcmd"
  ];


  # azure-common.nix sets the root partition device without an option to configure
  # the value. So we have to override it here.
  # 'filesystems.<name>.label' and 'filesystems.<name>.device' are mutually exclusive. Need to set only one.
  fileSystems."/".device = lib.mkForce "/dev/disk/by-partlabel/${config.disko.devices.disk.main.content.partitions.nixos-root.label}";
  fileSystems."/".label = lib.mkForce null;

  disko.devices.disk.main = {
    device = config.settings.disko.diskDevice;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          label = "ESP";
          size = "2G";
          type = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b";
          content = {
            type = "filesystem";
            format = "vfat";
            extraArgs = [
              "-F"
              "32"
              "-n"
              "ESP"
            ];
            mountpoint = "/boot";
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
        nixos-root = {
          size = "25G";
          label = "primary";
          content = {
            type = "filesystem";
            format = "ext4";
            extraArgs = [
              "-L"
              "nixos-root"
            ];
            mountpoint = "/";
            mountOptions = [
              "defaults"
              "noatime"
              "acl"
            ];
          };
        };
      };
    };
  };
}
