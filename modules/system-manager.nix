{ config, lib, ... }:
{
  options = {
    # Stub for NixOS config.lib (used by modules/lib.nix to expose ext_lib)
    lib = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
      internal = true;
    };

    # Stub for NixOS networking.hostName (from nixos/modules/tasks/network-interfaces.nix)
    networking.hostName = lib.mkOption {
      type = lib.types.strMatching "^$|^[[:alnum:]]([[:alnum:]_-]{0,61}[[:alnum:]])?$";
      default = "";
    };

    # Stub for NixOS services.openssh.ports (from nixos/modules/services/networking/ssh/sshd.nix)
    services.openssh.ports = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 22 ];
    };

    # From modules/network.nix
    settings.network.host_name = lib.mkOption {
      type = lib.types.host_name_type;
    };

    # Stubs for options set by org.nix but defined in other NixOS-only modules
    settings.crypto = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
    };

    settings.maintenance = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
    };

    settings.services.traefik = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
    };

    # Extend user submodule with openssh.authorizedKeys (normally from sshd.nix)
    users.users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.openssh.authorizedKeys = {
            keys = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            keyFiles = lib.mkOption {
              type = lib.types.listOf lib.types.path;
              default = [ ];
            };
          };
        }
      );
    };
  };

  config = {
    networking.hostName = lib.mkDefault config.settings.network.host_name;

    # system-manager defines boot as raw type with no default
    boot = { };

    # Override users.mutableUsers set by users.nix (false is for NixOS,
    # system-manager on Ubuntu should keep users mutable)
    users.mutableUsers = lib.mkForce true;

    nix.enable = true;
    environment.etc."nix/nix.conf".replaceExisting = true;

    programs.ssh.enable = true;
  };
}
