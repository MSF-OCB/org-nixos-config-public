{ config, lib, ... }:

let
  cfg = config.settings.network;

  ifaceOpts =
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };

        iface = lib.mkOption {
          type = lib.types.str;
          description = ''
            Interface name, defaults to the name of this entry in the attribute set.
          '';
        };

        fallback = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Select this static config only as a fallback in case DHCP fails.
            No DHCP request will be send out when this option is set to false!
          '';
        };

        address = lib.mkOption {
          type = lib.types.str;
        };

        prefix_length = lib.mkOption {
          type = lib.types.ints.between 0 32;
        };

        gateway = lib.mkOption {
          type = lib.types.str;
        };

        nameservers = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = ''
            DNS servers which will be configured only when this static configuration is selected.
          '';
        };
      };

      config = {
        iface = lib.mkDefault name;
      };
    };
in
{
  options = {
    settings.network = {
      host_name = lib.mkOption {
        type = lib.types.host_name_type;
      };

      static_ifaces = lib.mkOption {
        type = with lib.types; attrsOf (submodule ifaceOpts);
        default = { };
      };

      nameservers = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Globally defined DNS servers, in addition to those obtained by DHCP.";
      };

      dhcpcd.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };
  };

  config = {
    networking = {
      hostName = lib.mkForce cfg.host_name;
      # All non-manually configured interfaces are configured by DHCP.
      useDHCP = true;
      dhcpcd = lib.mkIf cfg.dhcpcd.enable (
        lib.mkMerge [
          {
            persistent = true;
            # Per the manpage, interfaces matching these but also
            # matching a pattern in denyInterfaces, are still denied
            allowInterfaces = [
              "en*"
              "wl*"
            ];
            # See: https://wiki.archlinux.org/index.php/Dhcpcd#dhcpcd_and_systemd_network_interfaces
            # We also ignore veth interfaces and the docker bridge, these are managed by Docker
            denyInterfaces = [
              "eth*"
              "wlan*"
              "veth*"
              "docker*"
            ];
            extraConfig =
              let
                format_name_servers = lib.concatStringsSep " ";
                mkConfig =
                  _: conf:
                  if conf.fallback then
                    ''
                      profile static_${conf.iface}
                      static ip_address=${conf.address}/${toString conf.prefix_length}
                      static routers=${conf.gateway}
                      static domain_name_servers=${format_name_servers conf.nameservers}

                      # fallback to static profile on ${conf.iface}
                      interface ${conf.iface}
                      fallback static_${conf.iface}
                    ''
                  else
                    ''
                      interface ${conf.iface}
                      static ip_address=${conf.address}/${toString conf.prefix_length}
                      static routers=${conf.gateway}
                      static domain_name_servers=${format_name_servers conf.nameservers}
                    '';
                mkConfigs = lib.compose [
                  (lib.concatStringsSep "\n\n")
                  (lib.mapAttrsToList mkConfig)
                  lib.filterEnabled
                ];
              in
              mkConfigs cfg.static_ifaces;
          }
          (
            if (config.system.nixos.release != "24.11") then
              {
                # We use the hostname to retrieve the correct nixos config from /org_config,
                # and to retrieve secrets etc. If we allow DHCP to set the hostname, then any
                # changes in the assigned hostname will break updates for the server.
                setHostname = false;
              }
            else
              { }
          )
        ]
      );
      inherit (cfg) nameservers;
    };
  };
}
