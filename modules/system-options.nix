{ config, lib, ... }:

let
  cfg = config.settings.system;
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
        default = repo: "git+ssh://git@github.com/${cfg.org.github_org}/${repo}.git";
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
}
