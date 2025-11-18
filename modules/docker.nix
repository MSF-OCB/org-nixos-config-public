{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.settings.docker;
in

{
  options = {
    settings.docker = {
      enable = lib.mkEnableOption "the Docker service";
      swarm.enable = lib.mkEnableOption "swarm mode";

      data_dir = lib.mkOption {
        type = lib.types.str;
        default = "/opt/.docker/docker";
        readOnly = true;
      };
    };
  };

  config = lib.mkIf cfg.enable {

    environment = {
      systemPackages = [ pkgs.docker-compose ];

      # For containers running java, allows to bind mount /etc/timezone
      etc = lib.mkIf (config.time.timeZone != null) {
        timezone.text = config.time.timeZone;
      };
    };

    boot.kernel.sysctl = {
      "vm.overcommit_memory" = 1;
      "net.core.somaxconn" = 65535;
      "fs.inotify.max_user_instances" = 8192;
    };

    virtualisation.docker = {
      inherit (cfg) enable;
      enableOnBoot = true;
      liveRestore = !cfg.swarm.enable;
      # Docker internal IP addressing
      # Ranges used: 172.28.0.0/16, 172.29.0.0/16
      #
      # Docker bridge
      # 172.28.0.1/18
      #   -> 2^14 - 2 (16382) hosts 172.28.0.1 -> 172.28.127.254
      #
      # Custom networks (448 networks in total)
      # 172.28.64.0/18 in /24 blocks
      #   -> 2^6 (64) networks 172.28.64.0/24 -> 172.28.127.0/24
      # 172.28.128.0/17 in /24 blocks
      #   -> 2^7 (128) networks 172.28.128.0/24 -> 172.28.255.0/24
      # 172.29.0.0/16 in /24 blocks
      #   -> 2^8 (256) networks 172.29.0.0/24 -> 172.29.255.0/24
      #
      # plus an option to put all containers under the same slice, so we can apply resource management
      #
      extraOptions = lib.concatStringsSep " " [
        ''--data-root "${cfg.data_dir}"''
        ''--bip "172.28.0.1/18"''
        ''--default-address-pool "base=172.28.64.0/18,size=24"''
        ''--default-address-pool "base=172.28.128.0/17,size=24"''
        ''--default-address-pool "base=172.29.0.0/16,size=24"''
        ''--cgroup-parent "applications.slice"''
      ];
    };

    systemd = {
      slices."applications".sliceConfig = {
        ManagedOOMMemoryPressure = "kill";
        ManagedOOMMemoryPressureLimit = "60%";
        MemoryMax = "90%";
        MemoryHigh = "70%";
        CPUWeight = 80;
      };

      slices."applications-background_tasks".sliceConfig = {
        # only the first CPU (zero-indexed), not zero CPUs
        AllowedCPUs = 0;
        IOWeight = 80;
      };

      services.docker = {
        unitConfig = {
          RequiresMountsFor = [ cfg.data_dir ];
        };
        wants = [ "pre-application-setup.target" ];
        after = [ "pre-application-setup.target" ];
        serviceConfig.LimitNOFILE = lib.mkForce "1048576";
      };
    };
  };
}
