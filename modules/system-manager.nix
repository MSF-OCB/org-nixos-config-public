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

    services.openssh.startWhenNeeded = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    networking.nftables.enable = lib.mkEnableOption "Mocked nftables";
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

    # Overriding the upstream module. System-manager do not support
    # setuid binaries for now. See
    # https://github.com/numtide/system-manager/issues/415
    users.users.tunnel = lib.mkIf config.settings.reverse_tunnel.enable {
      shell = lib.mkForce "/usr/sbin/nologin";
      extraGroups = [ "ssh-group" ];
    };
    users.users.tunneller = lib.mkIf config.settings.reverse_tunnel.relay.enable {
      shell = lib.mkForce "/usr/sbin/nologin";
    };
    # systemd-manager disables sshd and use its own
    # ssh-system-manager.service instead. There's no need for the
    # sshd socket.
    systemd.sockets.sshd.enable = false;
    systemd.services = lib.mapAttrs' (
      _: relay:
      lib.nameValuePair "autossh-reverse-tunnel-${relay.name}" {
        after = [ "ssh-system-manager.service" ];
      }
    ) config.settings.reverse_tunnel.relay_servers;
  };
}
