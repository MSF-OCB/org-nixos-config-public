{
  lib,
  ...
}:

let
  tunnel = {
    publicKey = lib.trim (lib.readFile ./data/id_tunnel.pub);
    privateKey = ./data/id_tunnel;
  };

  client = {
    publicKey = lib.trim (lib.readFile ./data/id_client.pub);
    privateKey = ./data/id_client;
  };

  mkEtcHostsEntry =
    node: vlanId:
    let
      inherit (lib.head node.networking.interfaces."eth${toString vlanId}".ipv6.addresses) address;
    in
    ''
      ${address} ${node.networking.hostName}
    '';
in

{
  name = "ssh-reverse-tunnelling";

  # Config shared by all nodes.
  # We set a bunch of reverse-tunnel related config here, which would otherwise
  # be configured globally as well.
  defaults =
    { nodes, config, ... }:
    {
      imports = [
        ../modules/reverse-tunnel.nix
      ];

      networking = {
        useNetworkd = true;

        firewall = {
          logRefusedPackets = true;
          logRefusedConnections = true;
          logReversePathDrops = true;
        };
      };

      services.openssh = {
        enable = true;
        # Avoid race conditions by using socket activation
        startWhenNeeded = true;
        hostKeys = [
          {
            path = "/etc/${config.environment.etc."ssh/ssh_host_ed25519_key".target}";
            type = "ed25519";
          }
        ];
        settings = {
          # Avoid the test hanging because it waits at a password prompt
          AuthenticationMethods = "publickey";
          KbdInteractiveAuthentication = false;
          PasswordAuthentication = false;

          LogLevel = "VERBOSE";
        };
      };

      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = tunnel.privateKey;
        mode = "0400";
      };

      users.groups.private-key-users = { };

      settings.reverse_tunnel = {
        privateTunnelKey = {
          group = config.users.groups.private-key-users.name;
          path = "${tunnel.privateKey}";
        };

        tunnels."${nodes.machine.networking.hostName}" = {
          public_key = tunnel.publicKey;
          # In production we have a very long connect timeout because we have
          # networks with very high latency.
          # This makes the test horribly slow though, so we use a very short
          # timeout here.
          connectTimeout = 1;
          remote_forward_port = 6004;
          reverse_tunnels.ssh = {
            forwarded_port = 22;
            prefix = 0;
          };
        };

        relay_servers = {
          sshrelay1 = {
            public_key = tunnel.publicKey;
            # We add entries in /etc/hosts below to resolve the host names
            addresses = [ nodes.sshrelay1.networking.hostName ];
          };
        };
      };
    };

  nodes = {
    sshrelay1 =
      { lib, nodes, ... }:
      {
        # The relay sits on both networks, so it's reachable by both machines
        virtualisation.vlans = [
          1
          2
        ];

        networking.extraHosts = lib.mkForce (
          lib.concatStringsSep "\n" [
            (mkEtcHostsEntry nodes.machine 1)
            (mkEtcHostsEntry nodes.client 1)
          ]
        );

        settings.reverse_tunnel = {
          relay = {
            enable = true;
            # This is done by the user module in the full setup, based on the data
            # read from keys.json
            tunneller.keys = [
              {
                username = nodes.machine.users.users.client.name;
                inherit (client) publicKey;
              }
            ];
          };
        };
      };

    machine =
      {
        config,
        lib,
        nodes,
        ...
      }:
      {
        virtualisation.vlans = [ 1 ];

        networking.extraHosts = lib.mkForce (mkEtcHostsEntry nodes.sshrelay1 1);

        settings.reverse_tunnel.enable = true;

        users = {
          users.client = {
            isNormalUser = true;
            group = config.users.groups.client.name;
            openssh.authorizedKeys.keys = [
              client.publicKey
            ];
          };
          groups.client = { };
        };
      };

    client =
      {
        nodes,
        config,
        lib,
        ...
      }:
      {
        virtualisation.vlans = [ 2 ];

        networking.extraHosts = lib.mkForce (mkEtcHostsEntry nodes.sshrelay1 2);

        # Create the key in /etc so that we can set the permissions correctly
        environment.etc."client_key" = {
          source = client.privateKey;
          mode = "0400";
        };

        programs.ssh.extraConfig = ''
          # We define this here so that it gets used for both the connection to
          # the relay and to the actual machine
          IdentityFile /etc/${config.environment.etc.client_key.target}
        '';
      };
  };

  testScript =
    { nodes, ... }:
    let
      machineHostName = nodes.machine.networking.hostName;
      remotePort =
        nodes.sshrelay1.settings.reverse_tunnel.tunnels."${machineHostName}".remote_forward_port;
    in
    # python
    ''
      def ensure_machine_connected():
        sshrelay1.wait_until_succeeds(" ".join([
          "test",
          '"$(',
          'ss --tcp --listen --numeric -6 --no-header sport == ${toString remotePort} | wc -l',
          ')"',
          "==",
          '"1"',
        ]))

      start_all()

      machine.wait_for_unit("multi-user.target")
      sshrelay1.wait_for_unit("multi-user.target")

      sshrelay1.wait_for_unit("sshd.socket")
      machine.wait_for_unit("autossh-reverse-tunnel-${nodes.machine.settings.reverse_tunnel.relay_servers.sshrelay1.name}.service")

      with subtest("Test that the server is connected"):
        ensure_machine_connected()

      with subtest("Test that the server reconnects after the relay crashed"):
        sshrelay1.shutdown()
        sshrelay1.start()
        sshrelay1.wait_for_unit("multi-user.target")
        sshrelay1.wait_for_unit("sshd.socket")
        ensure_machine_connected()

      with subtest("Connect to the server via the relay"):
        client.wait_for_unit("multi-user.target")
        client.succeed("ssh -o 'StrictHostKeyChecking=no' -J tunneller@${nodes.sshrelay1.networking.hostName} localhost -p ${toString remotePort} -l client true")
    '';
}
