{ lib, config, pkgs, ... }:

let
  cfg = config.settings.maintenance;
in

{
  options.settings.maintenance = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    sync_config.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to pull the config from the upstream branch before running the upgrade service.
      '';
    };

    config_repo = {
      url = lib.mkOption {
        type = lib.types.str;
      };
      branch = lib.mkOption {
        type = lib.types.str;
      };
    };

    nixos_upgrade = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the nixos-upgrade timer";
      };

      startAt = lib.mkOption {
        type = with lib.types; listOf str;
        # By default, we run the upgrade service once at night and once during
        # the day, to catch the situation where the server is turned off during
        # the night or during the weekend (which can be anywhere from Thursday to Sunday).
        # When the service is being run during the day, we will be outside the
        # reboot window and the config will not be switched.
        default = [ "Tue 03:00" "Mon 16:00" ];
        description = ''
          When to run the nixos-upgrade service.
        '';
      };
    };

    docker_prune_timer.enable = lib.mkEnableOption "service to periodically run docker system prune";
  };

  config = lib.mkIf cfg.enable {
    system.autoUpgrade = {
      inherit (cfg.nixos_upgrade) enable;
      allowReboot = true;
      rebootWindow = { lower = "01:00"; upper = "05:00"; };
      flake =
        let
          repo = config.settings.maintenance.config_repo;
        in
        "${repo.url}?ref=${repo.branch}";
      flags = [
        "--refresh"
        "--no-update-lock-file"
        # We pull a remote repo into the nix store,
        # so we cannot write the lock file.
        "--no-write-lock-file"
      ] ++ lib.optionals (config.settings.boot.mode == config.settings.boot.modes.uefi) [
        # While we're moving from grub to systemd-boot on uefi machines, we need
        # to make sure to reinstall the bootloader to actually switch to the new
        # bootloader.
        # TODO: remove this once we have no more uefi machines using grub
        "--install-bootloader"
      ];
      # We override this below, since this option does not accept
      # a list of multiple timings.
      dates = "";
    };

    systemd.services = {
      nixos-upgrade = lib.mkIf cfg.nixos_upgrade.enable {
        wants = [ "tunnel-key-ready.target" ];
        # Set the SSH command for the GH authentication
        environment.GIT_SSH_COMMAND = lib.concatStringsSep " " [
          "${pkgs.openssh}/bin/ssh"
          "-F /etc/ssh/ssh_config"
          "-i ${config.settings.system.github_private_key}"
          "-o IdentitiesOnly=yes"
          "-o StrictHostKeyChecking=yes"
        ];
        serviceConfig = {
          TimeoutStartSec = "2 days";
        };
        startAt = lib.mkForce cfg.nixos_upgrade.startAt;
      };

      # Dummy service to pull in nixos-upgrade until all usages have been migrated
      nixos_rebuild_config = lib.mkIf cfg.nixos_upgrade.enable {
        serviceConfig = {
          Type = "oneshot";
          ExecStart = ''${lib.getBin pkgs.coreutils}/bin/true'';
        };
        requires = [ "nixos-upgrade.service" ];
      };

      docker_prune_timer = lib.mkIf cfg.docker_prune_timer.enable {
        inherit (cfg.docker_prune_timer) enable;
        description = "Automatically run docker system prune";
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          ${pkgs.docker}/bin/docker system prune --force
        '';
        startAt = "Wed 04:00";
      };
    };

    nix = {
      settings = {
        auto-optimise-store = true;
      };
      gc = {
        automatic = true;
        dates = "Wed 03:00";
        options = "--delete-older-than 30d";
      };
    };
  };
}
