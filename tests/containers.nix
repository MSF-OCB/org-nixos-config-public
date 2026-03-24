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
        toplevel = inputs.system-manager.lib.makeSystemConfig {
          modules = [
            ../org-config/hosts/ubuntu/demo001.nix
            (
              { lib, ... }:
              {
                settings.reverse_tunnel = {
                  enable = true;
                  tunnels = {
                    demo001 = {
                      name = "demo001";
                      remote_forward_port = 2222;
                      public_key = "";
                    };
                  };
                };
                #
                users.users.tunnel.shell = lib.mkForce "/bin/nologin";
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
          demo001.wait_for_unit("multi-user.target")

          activation_logs = machine.activate()
          for line in activation_logs.split("\n"):
              assert "ERROR" not in line, f"Activation error: {line}"

          machine.wait_for_unit("system-manager.target")

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
