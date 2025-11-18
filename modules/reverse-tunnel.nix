{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.settings.reverse_tunnel;

  addCheckDesc =
    desc: elemType: check:
    lib.types.addCheck elemType check
    // {
      description = "${elemType.description} (with check: ${desc})";
    };
  isNonEmpty = s: (builtins.match "[ \t\n]*" s) == null;
  nonEmptyStr = addCheckDesc "non-empty" lib.types.str isNonEmpty;

  reverseTunnelOpts =
    { name, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
        };
        prefix = lib.mkOption {
          type = lib.types.ints.between 0 5;
          description = ''
            Numerical prefix to be added to the main port.
          '';
        };
        forwarded_port = lib.mkOption {
          type = lib.types.port;
          description = ''
            The local port from this server to forward.
          '';
        };
      };

      config = {
        name = lib.mkDefault name;
      };
    };

  tunnelOpts =
    { name, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.host_name_type;
        };

        remote_forward_port = lib.mkOption {
          type = with lib.types; either (ints.between 0 0) (ints.between 2000 9999);
          description = "The port used for this server on the relay servers.";
        };

        connectTimeout = lib.mkOption {
          type = lib.types.ints.positive;
          default = 360;
        };

        # We allow the empty string to allow bootstrapping
        # an installation where the key has not yet been generated
        public_key = lib.mkOption {
          type = lib.types.either lib.types.empty_str_type lib.types.pub_key_type;
        };

        generate_secrets = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Setting used by the python scripts generating the secrets.
            Setting this option to false makes sure that no secrets get generated for this host.
          '';
        };

        copy_key_to_users = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = ''
            A list of users to which this public key will be copied for SSH authentication.
          '';
        };

        reverse_tunnels = lib.mkOption {
          type = with lib.types; attrsOf (submodule reverseTunnelOpts);
          default = { };
        };
      };

      config = {
        name = lib.mkDefault name;
      };
    };

  relayServerOpts =
    { name, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
        };

        addresses = lib.mkOption {
          type = with lib.types; listOf nonEmptyStr;
        };

        public_key = lib.mkOption {
          type = lib.types.pub_key_type;
        };

        ports = lib.mkOption {
          type = with lib.types; listOf port;
          default = [
            22
            80
            443
          ];
        };
      };

      config = {
        name = lib.mkDefault name;
      };
    };
in
{

  options = {
    settings.reverse_tunnel = {
      enable = lib.mkEnableOption "the reverse tunnel services";

      privateTunnelKey = {
        path = lib.mkOption {
          type = lib.types.str;
        };

        group = lib.mkOption {
          type = lib.types.str;
        };
      };

      tunnels = lib.mkOption {
        type = with lib.types; attrsOf (submodule tunnelOpts);
        default = { };
      };

      relay_servers = lib.mkOption {
        type = with lib.types; attrsOf (submodule relayServerOpts);
        default = { };
      };

      relay = {
        enable = lib.mkEnableOption "the relay server functionality";

        tunnel.extraGroups = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };

        tunneller = {
          extraGroups = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
          keys = lib.mkOption {
            type = lib.types.listOf (
              lib.types.submodule (
                { config, ... }:
                {
                  options = {
                    username = lib.mkOption {
                      type = lib.types.str;
                    };
                    publicKey = lib.mkOption {
                      type = lib.types.pub_key_type;
                    };
                    keyOptions = lib.mkOption {
                      type = lib.types.listOf (lib.types.strMatching "[a-zA-Z=@.,\"-]*");
                      default = [ ];
                    };
                    finalKey = lib.mkOption {
                      type = lib.types.str;
                      default =
                        if config.keyOptions == [ ] then
                          "${config.publicKey} ${config.username}"
                        else
                          "${lib.concatStringsSep "," config.keyOptions} ${config.publicKey} ${config.username}";
                    };
                  };
                  config = {
                    keyOptions = [
                      "restrict"
                      "port-forwarding"
                    ];
                  };
                }
              )
            );
          };
        };
      };
    };
  };

  config =
    let
      includeTunnel = tunnel: lib.stringNotEmpty tunnel.public_key && tunnel.remote_forward_port > 0;
      add_port_prefix = prefix: base_port: 10000 * prefix + base_port;
      extract_prefix = reverse_tunnel: reverse_tunnel.prefix;
      get_prefixes = lib.mapAttrsToList (_: extract_prefix);
    in
    lib.mkMerge [
      {
        # This is very important, it ensures that the remote hosts can
        # set up their reverse tunnels without any issues with host keys
        programs.ssh.knownHosts = lib.mapAttrs (_: conf: {
          hostNames = conf.addresses;
          publicKey = conf.public_key;
        }) cfg.relay_servers;
      }
      (lib.mkIf (cfg.enable || cfg.relay.enable) {
        assertions =
          let
            # Functions to detect duplicate prefixes in our tunnel config
            toDuplicatePrefixes = lib.compose [
              lib.findDuplicates
              get_prefixes
              (lib.getAttr "reverse_tunnels")
            ];
            pretty_print_prefixes =
              host: prefixes:
              let
                sorted_prefixes = lib.concatMapStringsSep ", " toString (lib.naturalSort prefixes);
              in
              "${host}: ${sorted_prefixes}";

            mkDuplicatePrefixes = lib.compose [
              # Pretty-print the results
              (lib.mapAttrsToList pretty_print_prefixes)
              # lib.Filter out the entries with duplicate prefixes
              (lib.filterAttrs (_: prefixes: lib.length prefixes != 0))
              # map tunnels configs to their duplicate prefixes
              (lib.mapAttrs (_: toDuplicatePrefixes))
            ];
            duplicate_prefixes = mkDuplicatePrefixes cfg.tunnels;

            # Use the update_duplicates_set function to calculate
            # a set marking duplicate ports, lib.filter out the duplicates,
            # and return the result as a list of port numbers.
            mkDuplicatePorts = lib.compose [
              lib.findDuplicates
              (lib.filter (port: port != 0)) # Ignore entries with port set to zero
              (map (lib.getAttr "remote_forward_port"))
              # select the port attribute
              lib.attrValues # convert to a list of the tunnel definitions
            ];
            duplicate_ports = mkDuplicatePorts cfg.tunnels;
          in
          [
            {
              assertion = lib.length duplicate_prefixes == 0;
              message = "Duplicate prefixes defined! Details: " + lib.concatStringsSep "; " duplicate_prefixes;
            }
            {
              assertion = lib.length duplicate_ports == 0;
              message =
                "Duplicate tunnel ports defined! " + "Duplicates: " + lib.concatStringsSep ", " duplicate_ports;
            }
          ];

        users = {
          users = {
            tunnel = {
              group = config.users.groups.tunnel.name;
              isNormalUser = false;
              isSystemUser = true;
              home = "/run/tunnel";
              createHome = true;
              shell = pkgs.shadow;
            };
          };
          groups = {
            tunnel = { };
          };
        };
      })

      # Config for servers that want to connect to a relay
      (lib.mkIf cfg.enable (
        let
          # Load the config of the host currently being built from the settings
          # Assertions are only checked after the config has been evaluated,
          # so we cannot be sure that the host is present at this point.
          current_host_tunnel = cfg.tunnels.${config.networking.hostName} or null;
        in
        {
          warnings = lib.optional (!includeTunnel current_host_tunnel) ''
            The current machine has reverse tunnelling enabled, but it has no public key configured.
          '';

          assertions = [
            {
              assertion = lib.hasAttr config.networking.hostName cfg.tunnels;
              message = ''
                Tunnelling is enabled for this server but its hostname is not included in settings.reverse_tunnel.tunnels
              '';
            }
            {
              assertion = lib.length (lib.attrNames cfg.relay_servers) != 0;
              message = ''
                The current machine has reverse tunnelling enabled, but it has no relays configured.
              '';
            }
          ];

          users.users.tunnel.extraGroups = [
            config.users.groups.${cfg.privateTunnelKey.group}.name
          ];

          systemd.services =
            let
              make_tunnel_service = tunnel: relay: {
                enable = true;
                description = "AutoSSH reverse tunnel service to ensure resilient ssh access";
                wants = [
                  "network.target"
                  "tunnel-key-ready.target"
                ];
                after = [
                  "network.target"
                  "tunnel-key-ready.target"
                ];
                wantedBy = [ "multi-user.target" ];
                environment = {
                  AUTOSSH_GATETIME = "0";
                  AUTOSSH_PORT = "0";
                  AUTOSSH_MAXSTART = "10";
                };
                serviceConfig = {
                  User = "tunnel";
                  Type = "simple";
                  Restart = "always";
                  RestartSec = "10min";
                };
                script =
                  let
                    mkRevTunLine =
                      port: rev_tnl:
                      lib.concatStrings [
                        "-R "
                        (toString (add_port_prefix rev_tnl.prefix port))
                        ":localhost:"
                        (toString rev_tnl.forwarded_port)
                      ];
                    mkRevTunLines =
                      port:
                      lib.compose [
                        (lib.concatStringsSep " \\\n      ")
                        (lib.mapAttrsToList (_: mkRevTunLine port))
                      ];
                    rev_tun_lines = mkRevTunLines tunnel.remote_forward_port tunnel.reverse_tunnels;
                  in
                  /* bash */ ''
                    for host in ${lib.concatStringsSep " " relay.addresses}; do
                      for port in ${lib.concatMapStringsSep " " toString relay.ports}; do
                        echo "Attempting to connect to ''$host on port ''${port}"
                        (
                          # Don't exit when the command failed in this subshell,
                          # we want to continue the loop so that we try the other
                          # address/port combinations
                          set +e
                          ${lib.getExe pkgs.autossh} \
                              -T -N \
                              -o "ExitOnForwardFailure=yes" \
                              -o "ServerAliveInterval=10" \
                              -o "ServerAliveCountMax=5" \
                              -o "ConnectTimeout=${toString tunnel.connectTimeout}" \
                              -o "UpdateHostKeys=no" \
                              -o "StrictHostKeyChecking=yes" \
                              -o "UserKnownHostsFile=/dev/null" \
                              -o "IdentitiesOnly=yes" \
                              -o "Compression=yes" \
                              -o "ControlMaster=no" \
                              ${rev_tun_lines} \
                              -i ${cfg.privateTunnelKey.path} \
                              -p ''${port} \
                              -l tunnel \
                              ''${host} then
                          # We make sure that the subshell always exits cleanly so
                          # that even if the autossh command failed, we'll continue
                          # with the loop
                          exit 0
                        )
                      done
                    done
                  '';
              };

              make_tunnel_services =
                tunnel: relay_servers:
                lib.optionalAttrs (includeTunnel current_host_tunnel) (
                  lib.mapAttrs' (
                    _: relay:
                    lib.nameValuePair "autossh-reverse-tunnel-${relay.name}" (make_tunnel_service tunnel relay)
                  ) relay_servers
                );

            in
            lib.optionalAttrs (current_host_tunnel != null) (
              make_tunnel_services current_host_tunnel cfg.relay_servers
            );
        }
      ))

      # Config for relays
      (lib.mkIf cfg.relay.enable {
        assertions = [
          {
            assertion = lib.hasAttr config.networking.hostName cfg.relay_servers;
            message =
              "This host is set as a relay, "
              + "but its host name could not be found in the list of relays! "
              + "Defined relays: "
              + lib.concatStringsSep ", " (lib.attrNames cfg.relay_servers);
          }
        ];

        users = {
          users = {
            tunnel =
              let
                prefixes = tunnel: get_prefixes tunnel.reverse_tunnels;
                mkLimitation =
                  base_port: prefix:
                  ''restrict,port-forwarding,permitlisten="${toString (add_port_prefix prefix base_port)}"'';
                mkKeyConfig =
                  tunnel:
                  lib.concatStringsSep " " [
                    (lib.concatMapStringsSep "," (mkLimitation tunnel.remote_forward_port) (prefixes tunnel))
                    tunnel.public_key
                    "tunnel@${tunnel.name}"
                  ];
                mkKeyConfigs = lib.compose [
                  lib.naturalSort
                  (lib.mapAttrsToList (_: mkKeyConfig))
                  (lib.filterAttrs (_: includeTunnel))
                ];
              in
              {
                inherit (cfg.relay.tunnel) extraGroups;
                openssh.authorizedKeys.keys = mkKeyConfigs cfg.tunnels;
              };

            tunneller = {
              group = config.users.groups.tunneller.name;
              isNormalUser = false;
              isSystemUser = true;
              shell = pkgs.shadow;
              inherit (cfg.relay.tunneller) extraGroups;
              openssh.authorizedKeys.keys = map (key: key.finalKey) cfg.relay.tunneller.keys;
            };
          };

          groups = {
            tunneller = { };
          };
        };

        services.openssh = {
          enable = true;
          inherit (cfg.relay_servers.${config.networking.hostName}) ports;
        };

        systemd.services.port_monitor = {
          enable = true;
          serviceConfig = {
            User = "root";
            Type = "oneshot";
          };
          script = ''
            ${lib.getExe' pkgs.iproute2 "ss"} -Htpln6 | \
              ${lib.getExe' pkgs.coreutils "sort"} -n
          '';
          # Every 5 min
          startAt = "*:0/5:00";
        };
      })
    ];
}
