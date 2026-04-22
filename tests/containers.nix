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
            # set pkgs just like evalSystemManagerHost does
            { _module.args.pkgs = lib.mkForce pkgs; }
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

                settings.reverse_tunnel = {
                  enable = true;
                  tunnels = {
                    test001 = {
                      name = "tunnel";
                      public_key = lib.mkForce tunnel.publicKey;
                      # In production we have a very long connect timeout because we have
                      # networks with very high latency.
                      # This makes the test horribly slow though, so we use a very short
                      # timeout here.
                      connectTimeout = 1;
                      remote_forward_port = lib.mkForce 2323;
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

          # Provision the tunnel private key where tunnel-key-ready.target expects it
          machine.succeed("mkdir -p /var/lib/org-nix")
          machine.succeed("cp ${tunnel.privateKey} /var/lib/org-nix/id_tunnel")
          machine.succeed("chmod 600 /var/lib/org-nix/id_tunnel")

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
    zabbixSetup =
      let
        toplevel = inputs.system-manager.lib.makeSystemConfig {
          modules = [
            ../org-config/hosts/ubuntu/demo001.nix
            "${inputs.nixpkgs-latest}/nixos/modules/services/monitoring/zabbix-server.nix"
            "${inputs.nixpkgs-latest}/nixos/modules/services/databases/postgresql.nix"
            zabbixServerModule
          ]
          ++ defaultUbuntuModules;
          specialArgs = {
            inherit lib;
            flakeInputs = inputs;
          };
        };
        zabbixServerModule =
          { lib, ... }:
          {
            # Mocking a few options missing from system-manager to get a zabbix-server to run.
            # Note: this is not a proper port of the zabbix-server nixpkgs module. We're porting just enough
            # stuff to test the zabbix agent setup.
            options = {
              services.mysql.enable = lib.mkEnableOption "mocked-mysql";
              services.zabbixWeb.enable = lib.mkEnableOption "mocked-zabbixweb";
              system.stateVersion = lib.mkOption {
                type = lib.types.str;
              };
            };
            config = {
              system.stateVersion = "25.11";
              # Using the default postgres + nginx setup automagically set up by the
              # nixpkgs module.
              services.zabbixServer = {
                enable = true;
              };
              # The nginx + phpfpm + postgres stack takes a while to start. Adding a dependency
              # to make sure the server is properly booted and  the agent is be able to connect
              # at initialization without having to wait for the exponantially backed-off retry to be fired.
              systemd.services.zabbix-agent.after = [ "zabbix-server.service" ];
            };
          };
      in
      inputs.system-manager.lib.containerTest.makeContainerTest {
        hostPkgs = pkgs;
        name = "zabbix";
        inherit toplevel;
        skipTypeCheck = true;
        extraPathsToRegister = [ toplevel ];
        testScript = ''
          import time
          start_all()
          machine.wait_for_unit("multi-user.target")

          activation_logs = machine.activate()
          for line in activation_logs.split("\n"):
              assert "ERROR" not in line, f"Activation error: {line}"

          machine.wait_for_unit("system-manager.target")
          machine.wait_for_unit("zabbix-server.service")
          machine.wait_for_unit("zabbix-agent.service")

          # Ok, bear with me on this one. Configuring zabbix-server without its UI
          # is pretty hard. So, we won't be adding any checks for demo001 to the server.
          # Instead, we'll just test the agent is polling the checks from the server and the server is
          # failing to find these checks.

          # Server test
          machine.wait_for_open_port(10050)
          # There's a race condition. Sometimes, the agent is faster than the server and won't connect on the first try :/
          # Trying this out 20 times
          serverConnected=False
          i=0
          while (not serverConnected) and (i < 20):
            serverLogs=machine.succeed("journalctl -u zabbix-server.service")
            for line in serverLogs.split("\n"):
              if "cannot send list of active checks to \"127.0.0.1\": host [demo001] not found" in line:
                serverConnected=True
            if not serverConnected:
              i+=1
              time.sleep(2)
              print("INFO: Can't find agent connection in server log line, retrying.")
          agentLogs=machine.succeed("journalctl -u zabbix-agent.service")
          assert serverConnected, "Can't find log line proving the server is connected to the agent in zabbix-server journald logs:\n {}\n\n".format(serverLogs)


          # Agent test
          agentConnected=False
          # There's a race condition. Sometimes, the agent is faster than the server and won't connect on the first try :/
          # Trying this out 20 times
          i=0
          while (not agentConnected) and (i < 20):
            agentLogs=machine.succeed("journalctl -u zabbix-agent.service")
            for line in agentLogs.split("\n"):
               if "no active checks on server [localhost:10051]: host [demo001] not found" in line:
                 agentConnected=True
            if not agentConnected:
              i += 1
              time.sleep(2)
              print("INFO: Can't find server connection in agent log line, retrying.")
          serverLogs=machine.succeed("journalctl -u zabbix-server.service")
          assert agentConnected, "Can't find log line proving the agent is connected to the server in zabbix-agent journald logs:\n {}\n\n\n{}".format(agentLogs, serverLogs)

        '';
      };
    demo001 =
      let
        toplevel = inputs.system-manager.lib.makeSystemConfig {
          modules = [
            # set pkgs just like evalSystemManagerHost does
            { _module.args.pkgs = lib.mkForce pkgs; }
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

          with subtest("auto-upgrade"):
            timer_unit = demo001.file("/etc/systemd/system/system-manager-upgrade.timer")
            assert timer_unit.exists, "system-manager-upgrade.timer unit should exist"
            assert timer_unit.contains("OnCalendar=Tue 03:00"), "Timer should match configured schedule"

            service_unit = demo001.file("/etc/systemd/system/system-manager-upgrade.service")
            assert service_unit.exists, "system-manager-upgrade.service unit should exist"
            exec_start_line = [l for l in service_unit.content_string.splitlines() if l.startswith("ExecStart=")][0]
            script_path = exec_start_line.split("ExecStart=")[1].strip()
            start_script = demo001.file(script_path)
            assert start_script.exists, "Service start script should be readable"
            assert start_script.contains("system-manager switch"), "Service should invoke system-manager switch"
            assert start_script.contains("--flake git+ssh://git@github.com/MSF-OCB/org-nixos-config-public.git?ref=main"), "Service should reference the correct flake URL"
            assert start_script.contains("--ssh-option -F /etc/ssh/ssh_config"), "Service should use host SSH config"
            assert start_script.contains("--ssh-option -o IdentitiesOnly=yes"), "Service should enforce identity-only auth"
            assert start_script.contains("--ssh-option -o StrictHostKeyChecking=yes"), "Service should enforce strict host key checking"
            assert start_script.contains("--ssh-option -i"), "Service should specify the SSH private key"

          with subtest("ssh relay"):
            known_hosts = demo001.file("/etc/ssh/ssh_known_hosts")
            assert known_hosts.exists, "SSH known_hosts should exist"
            assert known_hosts.contains("demo-relay-1.ocb.msf.org,108.143.32.245 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINHILWx5iekpGR4s8N8d/Aa37Vgq8ZuxNs+7eT+YvMBU"), "SSH known_hosts should contain demo-relay-1.ocb.msf.org"

          with subtest("nix config"):
            nix_conf = demo001.file("/etc/nix/nix.conf")
            assert nix_conf.exists, "Nix config should exist"
            assert nix_conf.contains("experimental-features = nix-command flakes"), "Nix config should enable nix-command and flakes"
            assert nix_conf.contains("auto-optimise-store = true"), "Nix config should enable auto-optimise-store"
            assert nix_conf.contains("builders-use-substitutes = true"), "Nix config should enable builders-use-substitutes"
            assert nix_conf.contains("fallback = true"), "Nix config should enable fallback"
            assert nix_conf.contains("flake-registry = "), "Nix config should disable the global flake-registry"
            assert nix_conf.contains("trusted-users = root @wheel"), "Nix config should trust root and the wheel group"

            registry = demo001.file("/etc/nix/registry.json")
            assert registry.exists, "Nix registry should exist"
            assert registry.contains('"id":"nixpkgs"'), "Nix registry should contain a nixpkgs entry"
        '';
      };
  };
in
(pkgs.linkFarmFromDrvs "container-tests" (lib.attrValues ubuntuTests)) // ubuntuTests
