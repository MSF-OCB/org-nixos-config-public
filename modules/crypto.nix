{ config, lib, pkgs, utils, ... }:

with lib;

let
  cfg = config.settings.crypto;

  cryptoOpts =
    let
      outerConfig = config;
    in
    { name, config, ... }: {
      options = {
        enable = mkEnableOption "the encrypted device";

        name = mkOption {
          type = types.strMatching "^[[:lower:]][-_[:lower:]]+[[:lower:]]$";
        };

        device = mkOption {
          type = types.str;
          example = "/dev/LVMVolGroup/nixos_data";
          description = "The device to mount.";
        };

        device_units = mkOption {
          type = with types; listOf str;
          default = [ ];
          example = [ "dev-disk-by\\x2did-dm\\x2dname\\x2dLVMVolGroup\\x2dnixos_data.device" ];
          description = "Device units to wait for or be triggered by.";
        };

        key_file = mkOption {
          type = types.str;
          default = outerConfig.settings.crypto.defaultKeyFile;
          # We currently do not have multiple key files on any server and
          # we first need to migrate to properly secured key files.
          readOnly = true;
        };

        mount_point = mkOption {
          type = types.strMatching "^(/[-_[:lower:]]*)+$";
          description = ''
            The mount point on which to mount the partition contained
            in this encrypted volume.
            Currently we assume that every encrypted volume, contains
            a single partition, but this assumption could be generalised.
          '';
        };

        filesystem_type = mkOption {
          type = types.str;
          default = "ext4";
        };

        mount_options = mkOption {
          type = types.str;
          default = "";
          example = "acl,noatime,nosuid,nodev";
        };
      };

      config = {
        name = mkDefault name;
      };
    };
in
{

  options.settings.crypto = {
    defaultKeyFile = lib.mkOption {
      type = lib.types.str;
    };

    mounts = mkOption {
      type = with types; attrsOf (submodule cryptoOpts);
      default = [ ];
    };

    encrypted_opt = {
      enable = mkEnableOption "the encrypted /opt partition";

      device = mkOption {
        type = types.str;
        default = "/dev/LVMVolGroup/nixos_data";
        description = "The device to mount on /opt.";
      };
    };
  };

  imports = [
    (mkRenamedOptionModule [ "settings" "crypto" "enable" ] [ "settings" "crypto" "encrypted_opt" "enable" ])
    (mkRenamedOptionModule [ "settings" "crypto" "device" ] [ "settings" "crypto" "encrypted_opt" "device" ])
  ];

  config =
    let
      decrypted_name = conf: "nixos_decrypted_${conf.name}";
      open_service_name = conf: "open_encrypted_${conf.name}";

      mkOpenService = conf: {
        inherit (conf) enable;
        description = "Open the encrypted ${conf.name} partition.";
        conflicts = [ "shutdown.target" ];
        before = [ "shutdown.target" ];
        after = conf.device_units ++ [ "secrets-ready.target" ];
        wants = [ "secrets-ready.target" ];
        wantedBy = conf.device_units;
        requires = conf.device_units;
        restartIfChanged = false;
        unitConfig = {
          ConditionPathExists = "!/dev/mapper/${decrypted_name conf}";
        };
        serviceConfig = {
          User = "root";
          Type = "oneshot";
          Restart = "on-failure";
          RemainAfterExit = true;
          ExecStop = ''
            ${pkgs.cryptsetup}/bin/cryptsetup close --deferred ${decrypted_name conf}
          '';
        };
        script = ''
          function test_passphrase() {
            ${pkgs.cryptsetup}/bin/cryptsetup luksOpen \
                                              --test-passphrase \
                                              ${conf.device} \
                                              --key-file "''${1}" \
                                              > /dev/null 2>&1
            echo "''${?}"
          }

          # Avoid a harmless warning
          mkdir --parents /run/cryptsetup

          # Add the new key if both the new and the old exist
          if [ -e "${conf.key_file}" ] && [ -e "/keyfile" ]; then
            new_key_test="$(test_passphrase ${conf.key_file})"
            if [ "''${new_key_test}" -ne 0 ]; then
              echo "Adding key ${conf.key_file} to ${conf.device}..."
              ${pkgs.cryptsetup}/bin/cryptsetup luksAddKey \
                                                ${conf.device} \
                                                --key-file /keyfile \
                                                ${conf.key_file}
            fi
          fi

          # Determine the key file to use to open the partition
          if [ -e "${conf.key_file}" ]; then
            keyfile="${conf.key_file}"
          elif [ -e "/keyfile" ]; then
            keyfile="/keyfile"
          else
            echo "Keyfile ('${conf.key_file}') not found!"
            exit 1
          fi

          echo "Unlocking ${conf.device} using key ''${keyfile}..."

          ${pkgs.cryptsetup}/bin/cryptsetup open \
                                            ${conf.device} \
                                            ${decrypted_name conf} \
                                            --key-file ''${keyfile}

          # We remove the old key from the partition if the new one has been added
          if [ -e "${conf.key_file}" ] && [ -e "/keyfile" ]; then
            new_key_test="$(test_passphrase ${conf.key_file})"
            old_key_test="$(test_passphrase /keyfile)"
            if [ "''${new_key_test}" -eq 0 ] && [ "''${old_key_test}" -eq 0 ]; then
              echo "Removing /keyfile from ${conf.device}..."
              ${pkgs.cryptsetup}/bin/cryptsetup luksRemoveKey \
                                                ${conf.device} \
                                                --key-file /keyfile
            fi
          fi

          # We wait to exit from this script until
          # the decrypted device has been created by udev
          dev="/dev/mapper/${decrypted_name conf}"
          echo "Making sure that ''${dev} exists before exiting..."
          for countdown in $( seq 60 -1 0 ); do
            if [ -b "''${dev}" ]; then
              exit 0
            fi
            echo "Waiting for ''${dev}... (''${countdown})"
            sleep 5
            udevadm settle --exit-if-exists="''${dev}"
          done
          echo "Device node could not be found, exiting..."
          exit 1
        '';
      };
      mkMount = conf: {
        inherit (conf) enable;
        #TODO generalise, should we specify the partitions separately?
        what = "/dev/mapper/${decrypted_name conf}";
        where = conf.mount_point;
        type = conf.filesystem_type;
        options = conf.mount_options;
        after = [ "${open_service_name conf}.service" "basic.target" ];
        requires = [ "${open_service_name conf}.service" ];
        # Don't Include Default Dependencies as this causes a cyclical dependency error,
        # Instead crypto-mount-targets will ensure all crypto mounts are loaded before,
        # starting the nfs-server
        unitConfig = {
          DefaultDependencies = "no";
        };
        wants = [ "basic.target" ];
        wantedBy = [
          "multi-user.target"
          "${open_service_name conf}.service"
        ];
      };

      mkOpenServices = mapAttrs' (_: conf: nameValuePair (open_service_name conf)
        (mkOpenService conf));
      mkMounts = mapAttrsToList (_: conf: mkMount conf);
    in
    {
      settings.crypto.mounts = {
        opt = mkIf cfg.encrypted_opt.enable {
          enable = true;
          inherit (cfg.encrypted_opt) device;
          mount_point = "/opt";
          mount_options = "acl,noatime,nosuid,nodev";
        };
      };
      systemd =
        let
          enabled = lib.filterEnabled cfg.mounts;
          extra_mount_units = optional cfg.encrypted_opt.enable {
            inherit (cfg.encrypted_opt) enable;
            what = "/opt/.home";
            where = "/home";
            type = "none";
            options = "bind";
            unitConfig = {
              DefaultDependencies = "no";
              RequiresMountsFor = [ "/opt" ];
            };
            wantedBy = [ "multi-user.target" ];
          };

          cryptoMounts = mkMounts enabled ++ extra_mount_units;
        in
        {
          services = mkOpenServices enabled;
          mounts = cryptoMounts;
          targets.crypto-mounts-ready =
            let
              mountUnits = map (conf: "${utils.escapeSystemdPath conf.where}.mount") cryptoMounts;
            in
            {
              wants = mountUnits;
              after = mountUnits;
            };
        };
    };
}
