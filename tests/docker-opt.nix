{
  name = "docker-opt";

  # Config shared by all nodes.
  defaults = { pkgs, ... }: {
    networking = {
      # Use networkd, which also enables resolved, which makes network config easier
      useNetworkd = true;

      # Log blocked packets for easier debugging
      firewall = {
        logRefusedPackets = true;
        logRefusedConnections = true;
        logReversePathDrops = true;
      };
    };

    systemd.network.wait-online = {
      ignoredInterfaces = [
        # Ignore the management interface
        "eth0"
      ];
    };

    settings.crypto.defaultKeyFile = "${
      pkgs.writeTextFile {
        name = "keyfile";
        text = "5odbQOjY4mljTRW9yzHd5BXoVI5HbSJcWVvpmlQ1Lf4AvVPwngQOavEDJF5IMlbr2E7HKIWz4ySNG9zAhKfOs1PKquVwm1EuXSUS85pwl4V7YCXxYGU3nRW1OkEU9ZQL";
      }
    }";
  };

  nodes = {
    machine = { config, lib, pkgs, ... }: {
      imports = [
        ../modules/crypto.nix
        ../modules/docker.nix
      ];

      virtualisation = {
        fileSystems."/".autoFormat = true;
        emptyDiskImages = [
          512
        ];
        useBootLoader = true;
        useEFIBoot = true;
      };

      boot = {
        initrd.systemd.enable = true;
        loader.systemd-boot.enable = true;
      };

      systemd.services.format-opt = {
        requiredBy = [
          config.systemd.targets.multi-user.name
        ];
        before = [
          config.systemd.targets.multi-user.name
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${lib.getExe pkgs.cryptsetup} \
            --verbose \
            --batch-mode \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha512 \
            --use-urandom \
            luksFormat \
            --type luks2 \
            --key-file ${config.settings.crypto.defaultKeyFile} \
            /dev/vdb

          ${lib.getExe pkgs.cryptsetup} \
            open \
            --key-file ${config.settings.crypto.defaultKeyFile} \
            /dev/vdb \
            nixos_data_decrypted

          ${lib.getExe' pkgs.e2fsprogs "mkfs.ext4"} \
            -e remount-ro \
            -m 1 \
            -L nixos_data \
            /dev/mapper/nixos_data_decrypted

          ${lib.getExe pkgs.cryptsetup} close /dev/mapper/nixos_data_decrypted
        '';
      };

      specialisation.encrypted-opt.configuration = { lib, ... }: {
        systemd.services.format-opt.enable = lib.mkForce false;

        settings = {
          crypto.encrypted_opt = {
            enable = true;
            device = "/dev/vdb";
          };
          docker.enable = true;
        };
      };
    };
  };

  testScript = { ... }:
    # python
    ''
      start_all()
      machine.wait_for_unit("multi-user.target")

      with subtest("format the opt partition"):
          machine.wait_for_unit("format-opt.service")

      with subtest("modify the boot default"):
          machine.succeed("bootctl set-default nixos-generation-1-specialisation-encrypted-opt.conf")

      with subtest("reboot"):
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("multi-user.target")

      with subtest("opt was mounted"):
          machine.wait_for_unit("opt.mount")

      with subtest("docker was started"):
          machine.wait_for_unit("docker.service")
    '';
}
