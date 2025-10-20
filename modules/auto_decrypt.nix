{ config
, lib
, pkgs
, ...
}:

let
  cfg = config.settings.autoDecrypt;
in
{
  options.settings.autoDecrypt = {
    enable = lib.mkEnableOption "auto decryption of LUKS partitions";
  };

  config = lib.mkIf cfg.enable {
    security = {
      # enable basic tpm2 support for clevis
      # TODO: make this configurable
      tpm2 = {
        enable = true;
        pkcs11.enable = true;
        tctiEnvironment.enable = true;
      };
    };

    environment = {
      systemPackages = [ pkgs.clevis ];
    };

    boot.initrd = {
      # Disk
      availableKernelModules = [
        "usb_storage"
        "usbhid"
        "e1000e"
      ];
      luks.devices."luks-134b5ed3-55be-4f74-8186-1c139923b6b3".device =
        "/dev/disk/by-uuid/134b5ed3-55be-4f74-8186-1c139923b6b3";
      clevis = {
        enable = true;
        useTang = true;
        # XXX use secret to deploy secret file
        devices."luks-134b5ed3-55be-4f74-8186-1c139923b6b3".secretFile = "/root/enc.key";
      };

      # Network
      systemd.enable = true;
      systemd.network = {
        enable = true;
        networks = {
          # XXX always use dhcp for now, make configurable later
          # or switch to systemd-networkd and reuse configuration from stage 2
          "00-wired.network" = {
            networkConfig = {
              DHCP = "yes";
            };
            matchConfig = {
              Name = [
                "en*"
                "eth*"
              ];
            };
          };
        };
      };
      network = {
        enable = true;
        ssh = {
          enable = true;
          hostKeys = [ "/etc/ssh/initrd/ssh_host_ed25519_key" ];
          authorizedKeys = config.users.users.jfroche.openssh.authorizedKeys.keys;
        };
      };
    };
  };
}
