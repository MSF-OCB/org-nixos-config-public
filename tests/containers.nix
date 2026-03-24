{
  inputs,
  pkgs,
  lib,
  defaultUbuntuModules,
  ...
}:
let
  ubuntuTests = {
    reverseTunnel =
      let
        tunnel = {
          publicKey = lib.trim (lib.readFile ./data/id_tunnel.pub);
          privateKey = ./data/id_tunnel;
        };
        toplevel = inputs.system-manager.lib.makeSystemConfig {
          modules = [
            (
              { ... }:
              {

                nixpkgs.hostPlatform = "x86_64-linux";
                settings.network.host_name = "test001";
                networking.hostName = "test001";
                environment.etc."ssh/ssh_host_ed25519_key" = {
                  source = tunnel.privateKey;
                  mode = "0400";
                  replaceExisting = true;
                };

                services.openssh.hostKeys = [
                  {
                    path = "/etc/ssh/ssh_host_ed25519_key";
                    type = "ed25519";
                  }
                ];
                users.groups.ssh-users = { };

                settings.reverse_tunnel = {
                  enable = true;
                  privateTunnelKey = {
                    group = "ssh-users";
                    path = "${tunnel.privateKey}";
                  };
                  tunnels = {
                    test001 = {
                      name = "tunnel";
                      public_key = tunnel.publicKey;
                      # In production we have a very long connect timeout because we have
                      # networks with very high latency.
                      # This makes the test horribly slow though, so we use a very short
                      # timeout here.
                      connectTimeout = 1;
                      remote_forward_port = 2323;
                      reverse_tunnels.ssh = {
                        forwarded_port = 22;
                        prefix = 0;
                      };
                    };
                  };
                  relay_servers = {
                    test001 = {
                      public_key = tunnel.publicKey;
                      addresses = [ "localhost" ];
                    };
                  };

                  relay = {
                    enable = true;
                    tunnel.extraGroups = [ "ssh-rev-tun-users" ];
                    # This is done by the user module in the full setup, based on the data
                    # read from keys.json
                    tunneller.keys = [
                      {
                        username = "client";
                        inherit (tunnel) publicKey;
                      }
                    ];
                  };
                };
              }
            )
          ]
          ++ defaultUbuntuModules;
          specialArgs = {
            inherit lib;
            flakeInputs = inputs;
          };
        };
      in
      inputs.system-manager.lib.containerTest.makeContainerTest {
        hostPkgs = pkgs;
        name = "reverse-tunnel-test";
        inherit toplevel;
        skipTypeCheck = true;
        extraPathsToRegister = [ toplevel ];
        testScript = ''
          start_all()
          machine.wait_for_unit("multi-user.target")

          # For some reason, the ubuntu image is lacking the ssh host key.
          # It's generated as a postinstall hook, so let's run it again.
          machine.succeed("dpkg-reconfigure openssh-server")
          # Configure by ubuntu. Will mess up with autossh.

          activation_logs = machine.activate()
          for line in activation_logs.split("\n"):
              assert "ERROR" not in line, f"Activation error: {line}"

          machine.wait_for_unit("system-manager.target")
          machine.wait_for_unit("ssh-system-manager.service")
          machine.wait_for_unit("autossh-reverse-tunnel-test001.service")
          # The tunnel user shell is set to nologin, so we won't be able to log-in.
          # That being said, if the tunnel works correctly, the host
          # ssh daemon should be reachable through the 2323 reverse
          # tunnel port and send us a error message when trying to
          # log-in without a key.
          machine.wait_for_open_port(2323)
          res=machine.run('ssh -p 2323 tunnel@localhost | grep "tunnel@localhost: Permission denied (publickey)"')
          assert "tunnel@localhost: Permission denied (publickey)" in res.stdout, "autossh does not seem to be exposing 2323"
        '';
      };
    demo001 =
      let
        toplevel = inputs.system-manager.lib.makeSystemConfig {
          modules = [
            ../org-config/hosts/ubuntu/demo001.nix
          ]
          ++ defaultUbuntuModules;
          specialArgs = {
            inherit lib;
            flakeInputs = inputs;
          };
        };
      in
      inputs.system-manager.lib.containerTest.makeContainerTest {
        hostPkgs = pkgs;
        name = "demo001";
        inherit toplevel;
        skipTypeCheck = true;
        extraPathsToRegister = [ toplevel ];
        testScript = ''
          start_all()
          demo001.wait_for_unit("multi-user.target")

          activation_logs = machine.activate()
          for line in activation_logs.split("\n"):
              assert "ERROR" not in line, f"Activation error: {line}"

          machine.wait_for_unit("system-manager.target")

          with subtest("Verify users"):
            assert demo001.user("zimbatm").exists, "User zimbatm should exist"

          with subtest("sudoers"):
            sudoers = demo001.file("/etc/sudoers")
            assert sudoers.exists, "Sudoers file should exist"
            assert sudoers.contains("robot     ALL=(root)    SETENV:NOPASSWD: !ALL, SETENV:NOPASSWD: /run/current-system/sw/bin/systemctl --system start nixos-upgrade, SETENV:NOPASSWD: /run/current-system/sw/bin/systemctl --system start nixos-upgrade.service, SETENV:NOPASSWD: /run/current-system/sw/bin/systemctl --system start nixos_rebuild_config, SETENV:NOPASSWD: /run/current-system/sw/bin/systemctl --system start nixos_rebuild_config.service"), "Robot user should have whitelisted systemctl commands"
            assert sudoers.contains("%wheel  ALL=(ALL:ALL)    NOPASSWD:SETENV: ALL"), "Wheel group should have passwordless sudo"

          with subtest("wheel group"):
            wheel = demo001.group("wheel")
            assert wheel.exists, "Wheel group should exist"
            for user in ["zimbatm", "ibrahim_balla", "sohel_sarder", "yves_de_voghel"]:
              assert user in wheel.members, f"User {user} should be in wheel group"

          with subtest("ssh relay"):
            known_hosts = demo001.file("/etc/ssh/ssh_known_hosts")
            assert known_hosts.exists, "SSH known_hosts should exist"
            assert known_hosts.contains("demo-relay-1.ocb.msf.org,108.143.32.245 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINHILWx5iekpGR4s8N8d/Aa37Vgq8ZuxNs+7eT+YvMBU"), "SSH known_hosts should contain demo-relay-1.ocb.msf.org"
        '';
      };
  };
in
(pkgs.linkFarmFromDrvs "container-tests" (lib.attrValues ubuntuTests)) // ubuntuTests
