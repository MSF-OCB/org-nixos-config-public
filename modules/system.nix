{ config, lib, pkgs, flakeInputs, ... }:

let
  cfg = config.settings.system;
  tnl_cfg = config.settings.reverse_tunnel;
  tmux_term = "tmux-256color";
in

{
  options.settings.system = {
    isMbr = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Does the machine boot from a disk with an MBR layout.
      '';
    };

    isISO = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    private_key_source = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/org-nix/id_tunnel";
      description = ''
        The location of the private key file used to establish the reverse tunnels.
      '';
    };

    private_key_directory = lib.mkOption {
      type = lib.types.str;
      default = "/run/tunnel";
      readOnly = true;
    };

    # It is crucial that this option has type str and not path,
    # to avoid the private key being copied into the nix store.
    private_key = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.private_key_directory}/id_tunnel";
      readOnly = true;
      description = ''
        Location to load the private key file for the reverse tunnels from.
      '';
    };

    # It is crucial that this option has type str and not path,
    # to avoid the private key being copied into the nix store.
    github_private_key = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.private_key_directory}/id_github";
      description = ''
        Location to load the private key file for GitHub from.
      '';
    };

    org = {
      config_dir_name = lib.mkOption {
        type = lib.types.str;
        default = "org-config";
        readOnly = true;
        description = ''
          WARNING: when changing this value, you need to change the corresponding
                   values in install.sh and modules/default.nix as well!
        '';
      };

      env_var_prefix = lib.mkOption {
        type = lib.types.str;
      };

      github_org = lib.mkOption {
        type = lib.types.str;
      };

      repo_to_url = lib.mkOption {
        type = with lib.types; functionTo str;
        default = repo: ''git+ssh://git@github.com/${cfg.org.github_org}/${repo}.git'';
      };

      iso = {
        menu_label = lib.mkOption {
          type = lib.types.str;
          default = "NixOS Rescue System";
        };

        file_label = lib.mkOption {
          type = lib.types.str;
          default = "nixos-rescue";
        };
      };
    };

    users_json_path = lib.mkOption {
      type = lib.types.path;
    };

    keys_json_path = lib.mkOption {
      type = lib.types.path;
    };

    tunnels_json_dir_path = lib.mkOption {
      type = with lib.types; nullOr path;
    };

    secrets = {
      serverName = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
      };

      src_directory = lib.mkOption {
        type = lib.types.path;
        description = ''
          The directory containing the generated and encrypted secrets.
        '';
      };

      src_file = lib.mkOption {
        type = lib.types.path;
        default = cfg.secrets.src_directory + "/generated-secrets.yml";
        description = ''
          The file containing the generated and encrypted secrets.
        '';
      };

      dest_directory = lib.mkOption {
        type = lib.types.str;
        description = ''
          The directory containing the decrypted secrets available to this server.
        '';
      };

      old_dest_directories = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
      };

      allow_groups = lib.mkOption {
        type = with lib.types; listOf str;
        description = ''
          Groups which have access to the secrets through ACLs.
        '';
        default = [ ];
      };
    };

    app_configs = {
      src_directory = lib.mkOption {
        type = lib.types.path;
        description = ''
          The directory containing the generated app configs.
        '';
      };

      src_file = lib.mkOption {
        type = lib.types.path;
        default = cfg.app_configs.src_directory + "/generated-app-configs.yml";
        description = ''
          The file containing the generated app configs.
        '';
      };

      dest_directory = lib.mkOption {
        type = lib.types.str;
        description = ''
          The directory containing the app configs available to this server.
        '';
      };

      allow_groups = lib.mkOption {
        type = with lib.types; listOf str;
        description = ''
          Groups which have access to the app configs through ACLs.
        '';
        default = [ ];
      };
    };

    opt = {
      allow_groups = lib.mkOption {
        type = with lib.types; listOf str;
      };
    };
    secrets = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };
  };

  imports = [
    ({ config, lib, ... }: {
      config = lib.mkIf config.settings.system.isMbr {
        fileSystems = {
          "/" = {
            device = lib.mkForce "/dev/disk/by-label/nixos_root";
            fsType = "ext4";
            options = [
              "x-initrd.mount"
              "defaults"
              "noatime"
              "acl"
            ];
          };
          "/boot" = lib.mkIf config.settings.boot.separate_partition {
            device = "/dev/disk/by-label/nixos_boot";
            fsType = "ext4";
            options = [
              "defaults"
              "noatime"
              "nosuid"
              "nodev"
              "noexec"
              "x-systemd.automount"
              "x-systemd.idle-timeout=5min"
            ];
          };
        };
        boot.loader.grub.device = lib.mkDefault config.settings.disko.diskDevice;
      };
    })
  ];

  config = {

    assertions = [
      {
        assertion = lib.hasAttr config.networking.hostName tnl_cfg.tunnels;
        message =
          "This host's host name is not present in the tunnel config " +
          "(${toString cfg.tunnels_json_dir_path}).";
      }
      {
        assertion = config.time.timeZone != null;
        message =
          "The time zone is not set for ${config.networking.hostName}, please set config.time.timeZone.";
      }
      {
        assertion = config.settings.system.isMbr -> !config.settings.disko.enableDefaultConfig;
        message = ''
          Disko cannot be enabled on MBR systems
        '';
      }
    ];

    settings.disko.enableDefaultConfig = lib.mkIf config.settings.system.isMbr false;

    # Use the schedutil frequency scaling governor.
    # mkForce has a priority of 50, while the default priority is 100.
    # We use 75 here to override the setting in hardware-configuration.nix files
    # that were generated with old versions of nixos-generate-config that did
    # not yet use lib.mkDefault, but we also still want to allow the usage of mkForce.
    powerManagement.cpuFreqGovernor = lib.mkOverride 75 "schedutil";

    security = {
      sudo = {
        enable = true;
        wheelNeedsPassword = false;
      };
      pam.services.su.forwardXAuth = lib.mkForce false;
    };

    environment = {
      shellAliases = {
        nix-env = ''printf "The nix-env command has been disabled. Please use nix run or nix shell instead." 2> /dev/null'';
        # Have bash resolve aliases with sudo (https://askubuntu.com/questions/22037/aliases-not-available-when-using-sudo)
        sudo = "sudo ";
        whereami = "curl ipinfo.io";
      };
      variables = {
        HOSTNAME = config.networking.hostName;
        HOSTNAME_HASH =
          let
            hash = builtins.hashString "sha256" config.networking.hostName;
          in
          lib.substring 0 12 hash;
        "${cfg.org.env_var_prefix}_SECRETS_DIRECTORY" = cfg.secrets.dest_directory;
        "${cfg.org.env_var_prefix}_CONFIGS_DIRECTORY" = cfg.app_configs.dest_directory;
      };
    };

    settings = {
      reverse_tunnel = {
        privateTunnelKey = {
          path = config.settings.system.private_key;
          group = config.users.groups.private-key-access.name;
        };
        relay = {
          tunnel.extraGroups = [
            config.settings.users.ssh-group
            config.settings.users.rev-tunnel-group
          ];
          # The fwd-tunnel-group is required to be able to proxy through the relay
          tunneller.extraGroups = [
            config.settings.users.ssh-group
            config.settings.users.fwd-tunnel-group
          ];
        };
      };
      services.traefik = {
        extraEnvironmentFiles = [
          (cfg.secrets.dest_directory + config.settings.services.traefik.acme.dnsProvider)
        ];
        docker.swarm = {
          inherit (config.settings.docker.swarm) enable;
        };
      };
    };

    users = {
      groups = {
        private-key-access = { };
      };
    };

    settings.system = lib.mkMerge [
      {
        # Admins have access to the secrets & configs
        secrets.allow_groups = [ "wheel" ];
        app_configs.allow_groups = [ "wheel" ];
        # Admins have access to /opt
        opt.allow_groups = [ "wheel" ];
      }
      (lib.mkIf (config.users.users ? docker) {
        # Users in the docker group need access to secrets and /opt
        secrets.allow_groups = [ "docker" ];
        app_configs.allow_groups = [ "docker" ];
        opt.allow_groups = [ "docker" ];
      })
    ];

    system.nixos.version = lib.concatStringsSep "." [
      config.system.nixos.release
      "nixpkgs"
      (lib.substring 0 8 config.nixpkgs.pkgs.lastModifiedDate or "unknown")
      (config.nixpkgs.pkgs.shortRev or "dirty")
      "msfocb"
      (lib.substring 0 8 flakeInputs.self.lastModifiedDate or "unknown")
      (flakeInputs.self.shortRev or "dirty")
    ];

    systemd = {
      # Given that our systems are headless, emergency mode is useless.
      # We prefer the system to attempt to continue booting so
      # that we can hopefully still access it remotely.
      enableEmergencyMode = false;

      oomd = {
        # OOMD is enabled by default, except in WSL, where OOMD is not currently
        # available, because of the absence of cgroup memory pressure info
        enableRootSlice = true;
        enableSystemSlice = true;
        enableUserSlices = true;
      };

      slices = {
        system.sliceConfig = {
          ManagedOOMPreference = "omit";
        };
        user.sliceConfig = {
          ManagedOOMMemoryPressure = "kill";
          ManagedOOMMemoryPressureLimit = "60%";
          MemoryMax = "90%";
          MemoryHigh = "70%";
          CPUWeight = 80;
        };
      };

      # For more detail, see:
      #   https://0pointer.de/blog/projects/watchdog.html
      watchdog = {
        # systemd will send a signal to the hardware watchdog at half
        # the interval defined here, so every 10s.
        # If the hardware watchdog does not get a signal for 20s,
        # it will forcefully reboot the system.
        runtimeTime = "20s";
        # Forcefully reboot if the final stage of the reboot
        # hangs without progress for more than 30s.
        # For more info, see:
        #   https://utcc.utoronto.ca/~cks/space/blog/linux/SystemdShutdownWatchdog
        rebootTime = "30s";
      };

      sleep.extraConfig = ''
        AllowSuspend=no
        AllowHibernation=no
      '';

      services =
        let
          legacy_key_path = "/etc/nixos/local/id_tunnel";
        in
        {
          set_opt_permissions = {
            # See https://web.archive.org/web/20121022035645/http://vanemery.com/Linux/ACL/POSIX_ACL_on_Linux.html
            enable = true;
            description = "Set the ACLs on /opt.";
            unitConfig = {
              RequiresMountsFor = [ "/opt" ];
            };
            after = [ "local-fs.target" ];
            wants = [ "local-fs.target" ];
            serviceConfig = {
              User = "root";
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script =
              let
                containerd = "containerd";
                # The X permission has no effect for default ACLs, it gets converted
                # into a regular x.
                # For all users except the file owner, the effective permissions are
                # still subject to masking, and the default mask does not
                # contain x for files.
                # Therefore, in practice, only the file owner gains execute permissions
                # on all files, and we do not need to worry too much.
                # We could probably detect this situation and revoke the x permission
                # from the ACLs on files, but this currently does not seem worth it,
                # given the additional complexity that this would introduce in this
                # script.
                acl = lib.concatStringsSep "," (
                  [
                    "u::rwX"
                    "user:root:rwX"
                    "d:u::rwx"
                    "d:g::r-x"
                    "d:o::---"
                    "d:user:root:rwx"
                  ] ++
                  lib.concatMap (group: [ "group:${group}:rwX" "d:group:${group}:rwx" ])
                    cfg.opt.allow_groups
                );
                # For /opt we use setfacl --set, so we need to define the full ACL
                opt_acl = lib.concatStringsSep "," [ "g::r-X" "o::---" acl ];
              in
              ''
                # Ensure that /opt actually exists
                if [ ! -d "/opt" ]; then
                  echo "/opt does not exist, exiting."
                  exit 0
                fi

                # Root owns /opt, and we apply the ACL defined above
                ${pkgs.coreutils}/bin/chown root:root      "/opt/"
                ${pkgs.coreutils}/bin/chmod u=rwX,g=rwX,o= "/opt/"
                ${pkgs.acl}/bin/setfacl \
                  --set "${opt_acl}" \
                  "/opt/"

                # Special cases
                if [ -d "/opt/${containerd}" ]; then
                  ${pkgs.acl}/bin/setfacl --remove-all --remove-default "/opt/${containerd}"
                  ${pkgs.coreutils}/bin/chown root:root     "/opt/${containerd}"
                  ${pkgs.coreutils}/bin/chmod u=rwX,g=X,o=X "/opt/${containerd}"
                fi

                if [ -d "/opt/.docker" ]; then
                  ${pkgs.acl}/bin/setfacl --remove-all --remove-default "/opt/.docker"
                  ${pkgs.coreutils}/bin/chown root:root       "/opt/.docker"
                  ${pkgs.coreutils}/bin/chmod u=rwX,g=rX,o=rX "/opt/.docker"
                fi

                if [ -d "/opt/.home" ]; then
                  ${pkgs.acl}/bin/setfacl --remove-all --remove-default "/opt/.home"
                  ${pkgs.coreutils}/bin/chown root:root       "/opt/.home"
                  ${pkgs.coreutils}/bin/chmod u=rwX,g=rX,o=rX "/opt/.home"
                fi

                # We iterate over all directories that are not hidden,
                # except containerd and lost+found.
                # Prefix directories with a dot to exclude them.
                # For each dir we set ownership to root:root and
                # recursively apply the ACL defined above.
                for dir in $(ls /opt/); do
                  if [ -d "/opt/''${dir}" ] && \
                     [ ! "${containerd}" = "''${dir}" ] && \
                     [ ! "lost+found"    = "''${dir}" ]; then
                    ${pkgs.coreutils}/bin/chown root:root      "/opt/''${dir}"
                    ${pkgs.coreutils}/bin/chmod u=rwX,g=rwX,o= "/opt/''${dir}"
                    ${pkgs.acl}/bin/setfacl \
                      --recursive \
                      --no-mask \
                      --modify "${acl}" \
                      "/opt/''${dir}"
                  fi
                done
              '';
          };
          tunnel-key-permissions = {
            enable = !cfg.isISO;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            unitConfig = {
              RequiresMountsFor = [ "/run" "/var/lib" ];
            };
            script =
              let
                base_files = [ cfg.private_key_source legacy_key_path ];
                files = lib.concatStringsSep " " (lib.unique (lib.concatMap (f: [ f "${f}.pub" ]) base_files));
              in
              ''
                for file in ${files}; do
                  if [ -f ''${file} ]; then
                    ${pkgs.coreutils}/bin/chown root:root ''${file}
                    ${pkgs.coreutils}/bin/chmod 0400 ''${file}
                  fi
                done
              '';
          };
          move-legacy-tunnel-key = {
            enable = !cfg.isISO;
            wants = [ "tunnel-key-permissions.service" ];
            after = [ "tunnel-key-permissions.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            unitConfig = {
              RequiresMountsFor = [ "/run" "/var/lib" ];
            };
            script = ''
              if [ ! -f "${cfg.private_key_source}" ] && [ -f "${legacy_key_path}" ]; then
                echo -n "Moving the private key into the new location..."
                mkdir --parent "$(dirname "${cfg.private_key_source}")"
                cp "${legacy_key_path}" "${cfg.private_key_source}"
                # TODO: enable this line
                #rm --recursive --force /etc/nixos/
                echo " done"
              fi
            '';
          };
          copy-tunnel-key = {
            wants = [ "move-legacy-tunnel-key.service" ];
            after = [ "move-legacy-tunnel-key.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            unitConfig = {
              RequiresMountsFor = [ "/run" "/var/lib" ];
            };
            script =
              let
                install = { source, dest, perms }: ''
                  ${pkgs.coreutils}/bin/install \
                    -o ${config.users.users.root.name} \
                    -g ${config.users.groups.private-key-access.name} \
                    -m ${perms} \
                    "${source}" \
                    "${dest}"
                '';
              in
              ''
                if [ -f "${cfg.private_key_source}" ]; then
                  ${install {source=cfg.private_key_source; dest=cfg.private_key; perms="440"; }}
                  ${install {source=cfg.private_key_source; dest=cfg.github_private_key; perms="400"; }}
                else
                  echo "No private key found, ignoring!"
                fi
              '';
          };
          decrypt-secrets = {
            inherit (cfg.secrets) enable;
            wants = [ "tunnel-key-ready.target" ];
            after = [ "tunnel-key-ready.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            unitConfig = {
              RequiresMountsFor = [ "/run" "/var/lib" ];
            };
            script =
              let
                # We make an ACL with default permissions and add an extra rule
                # for each group defined as having access
                acl = lib.concatStringsSep "," (
                  [ "u::rwX,g::r-X,o::---" ] ++ map (group: "group:${group}:rX") cfg.secrets.allow_groups
                );
                mkRemoveOldDir = dir: ''
                  # Delete the old secrets dir which is not used anymore
                  # We maintain it as a link for now for backwards compatibility,
                  # so we test first whether it is still a directory
                  if [ ! -L "${dir}" ]; then
                    ${pkgs.coreutils}/bin/rm --one-file-system \
                                             --recursive \
                                             --force \
                                             "${dir}"
                  fi
                '';
              in
              ''
                echo "decrypting the server secrets..."
                ${lib.concatMapStringsSep "\n" mkRemoveOldDir cfg.secrets.old_dest_directories}
                if [ -e "${cfg.secrets.dest_directory}" ]; then
                  ${pkgs.coreutils}/bin/rm --one-file-system \
                                           --recursive \
                                           --force \
                                           "${cfg.secrets.dest_directory}"
                fi
                ${pkgs.coreutils}/bin/mkdir --parent "${cfg.secrets.dest_directory}"

                ${pkgs.ocb-nixostools}/bin/decrypt_server_secrets \
                  --server_name "${config.settings.system.secrets.serverName}" \
                  --secrets_path "${cfg.secrets.src_file}" \
                  --output_path "${cfg.secrets.dest_directory}" \
                  --private_key_file "${cfg.private_key}"

                # The directory is owned by root
                ${pkgs.coreutils}/bin/chown --recursive root:root "${cfg.secrets.dest_directory}"
                ${pkgs.coreutils}/bin/chmod --recursive u=rwX,g=,o= "${cfg.secrets.dest_directory}"
                # Use an ACL to give access to members of the wheel and docker groups
                ${pkgs.acl}/bin/setfacl \
                  --recursive \
                  --set "${acl}" \
                  "${cfg.secrets.dest_directory}"
                echo "decrypted the server secrets"
              '';
          };
          extract-app-configs = {
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script =
              let
                # We make an ACL with default permissions and add an extra rule
                # for each group defined as having access
                acl = lib.concatStringsSep "," (
                  [ "u::rwX,g::r-X,o::---" ] ++ map (group: "group:${group}:rX") cfg.app_configs.allow_groups
                );
              in
              ''
                echo "extracting the server configs..."
                if [ -e "${cfg.app_configs.dest_directory}" ]; then
                  ${pkgs.coreutils}/bin/rm --one-file-system \
                                          --recursive \
                                          --force \
                                          "${cfg.app_configs.dest_directory}"
                fi
                ${pkgs.coreutils}/bin/mkdir --parent "${cfg.app_configs.dest_directory}"

                ${pkgs.ocb-nixostools}/bin/extract_server_app_configs \
                  --server_name "${config.networking.hostName}" \
                  --configs_path "${cfg.app_configs.src_file}" \
                  --output_path "${cfg.app_configs.dest_directory}"

                # The directory is owned by root
                ${pkgs.coreutils}/bin/chown --recursive root:root "${cfg.app_configs.dest_directory}"
                ${pkgs.coreutils}/bin/chmod --recursive u=rwX,g=,o= "${cfg.app_configs.dest_directory}"
                # Use an ACL to give access to members of the wheel and docker groups
                ${pkgs.acl}/bin/setfacl \
                  --recursive \
                  --set "${acl}" \
                  "${cfg.app_configs.dest_directory}"
                echo "extracted the server configs"
              '';
          };
        };
      targets = {
        tunnel-key-ready.wants = [ "copy-tunnel-key.service" ];
        crypto-mounts-ready = { };
        pre-application-setup.wants = [
          "secrets-ready.target"
          "extract-app-configs.service"
          "local-fs.target"
          "set_opt_permissions.service"
          "crypto-mounts-ready.target"
        ];
        secrets-ready.wants = [ "decrypt-secrets.service" ];
        multi-user.wants = [ "pre-application-setup.target" ];
      };
      user.services.cleanup_nixenv = {
        enable = true;
        description = "Clean up nix-env";
        unitConfig = {
          ConditionUser = "!@system";
          ConditionGroup = config.settings.users.shell-user-group;
        };
        serviceConfig.Type = "oneshot";
        script = ''
          ${pkgs.nix}/bin/nix-env -e '.*'
        '';
        wantedBy = [ "default.target" ];
      };
    };

    # No fonts needed on a headless system
    fonts.fontconfig.enable = lib.mkForce false;

    programs = {
      bash.completion.enable = true;

      ssh = {
        startAgent = false;
        # We do not have GUIs
        setXAuthLocation = false;
        hostKeyAlgorithms = [ "ssh-ed25519" "ssh-rsa" ];
        knownHosts.github = {
          hostNames = [ "github.com" "ssh.github.com" ];
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
        };
        extraConfig = ''
          # Some internet providers block port 22,
          # so we connect to GitHub using port 443
          Host github.com
            HostName ssh.github.com
            User git
            Port 443
            UserKnownHostsFile /dev/null
            IdentityFile ${cfg.private_key_source}
        '';
      };

      tmux = {
        enable = true;
        newSession = true;
        clock24 = true;
        historyLimit = 10000;
        escapeTime = 250;
        terminal = tmux_term;
        extraConfig = ''
          set -g mouse on
          set-option -g focus-events on
          set-option -g default-terminal "${tmux_term}"
          set-option -sa terminal-overrides ',xterm:RGB'
        '';
      };

      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      # We use nix-index instead
      command-not-found.enable = false;
    };

    services = {
      fstrim.enable = true;
      # Avoid pulling in unneeded dependencies
      udisks2.enable = false;

      timesyncd = {
        enable = lib.mkDefault true;
        servers = lib.mkDefault [
          "0.nixos.pool.ntp.org"
          "1.nixos.pool.ntp.org"
          "2.nixos.pool.ntp.org"
          "3.nixos.pool.ntp.org"
          "time.windows.com"
          "time.google.com"
        ];
      };

      htpdate = {
        enable = true;
        servers = [ "www.kernel.org" "www.google.com" "www.cloudflare.com" ];
      };

      journald = {
        rateLimitBurst = 1000;
        rateLimitInterval = "5s";
        extraConfig = ''
          Storage=persistent
        '';
      };

      # See man logind.conf
      logind = {
        extraConfig = ''
          HandlePowerKey=poweroff
          PowerKeyIgnoreInhibited=yes
        '';
      };

      avahi = {
        enable = true;
        nssmdns4 = true;
        extraServiceFiles = {
          ssh = "${pkgs.avahi}/etc/avahi/services/ssh.service";
        };
        publish = {
          enable = true;
          domain = true;
          addresses = true;
          workstation = true;
        };
      };
    };

    nix = {
      nixPath = [
        "nixpkgs=flake:nixpkgs"
      ];
      registry.nixpkgs = {
        from = { type = "indirect"; id = "nixpkgs"; };
        flake = pkgs.nixpkgsFlake;
      };
      # man nix.conf
      settings = {
        auto-optimise-store = true;
        trusted-users = [ "root" "@wheel" ];
        builders-use-substitutes = true;
        experimental-features = [ "nix-command" "flakes" ];
        # Fall back to building from source if we cannot substitute
        fallback = true;
        # Disable the global flake registry
        flake-registry = "";
      };
    };

    hardware = {
      enableRedistributableFirmware = true;
      cpu.intel.updateMicrocode = true;
      cpu.amd.updateMicrocode = true;
    };

    documentation = {
      man.enable = true;
      doc.enable = false;
      dev.enable = false;
      info.enable = false;
    };

    # This value determines the NixOS release with which your system is to be
    # compatible, in order to avoid breaking some software such as database
    # servers. You should change this only after NixOS release notes say you
    # should.
    system.stateVersion = "18.03"; # Did you read the comment?

    # This is a separate piece of configuration that is only used when we build
    # a QEMU virtual machine image that can be used for testing and debugging.
    # It has no influence on the normal production builds.
    virtualisation.vmVariant = {
      services.timesyncd.enable = lib.mkVMOverride false;
      boot.kernelParams = [ "console=ttyS0" ];
      virtualisation = {
        cores = 2;
        memorySize = 4 * 1024;
        diskSize = 20 * 1024;
        writableStoreUseTmpfs = false;
        # Set to true to get a GUI
        graphics = false;
        qemu = {
          options = [
            "-machine accel=kvm"
          ];
          guestAgent.enable = true;
        };
      };
      services.getty.autologinUser = lib.mkVMOverride "root";
      users.mutableUsers = lib.mkForce false;
      networking.dhcpcd = {
        denyInterfaces = lib.mkForce [ ];
        allowInterfaces = lib.mkForce [ ];
      };
      documentation = {
        man.enable = lib.mkForce false;
        dev.enable = false;
        info.enable = false;
        doc.enable = false;
        nixos.enable = false;
      };

      # TODO: do we want to have an actual encrypted device to make sure
      # that decrypting and mounting works?
      # Can we create a LUKS volume in memory for instance? Or in a file?
      settings.crypto.encrypted_opt.enable = lib.mkVMOverride false;

      settings = {
        # Change the server name so that there are no matching secrets.
        system.secrets.serverName = lib.mkVMOverride "test-vm";
        # Make sure to turn off tunneling.
        # We could turn this on in a VM test if we configure another relay.
        # Careful if you want to turn this on because if you do this without
        # changing the relay servers, you will get your IP blocked.
        reverse_tunnel.enable = lib.mkVMOverride false;
      };
    };
  };
}
