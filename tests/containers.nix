{
  inputs,
  pkgs,
  lib,
  defaultUbuntuModules,
  ...
}:
let
  ubuntuTests = {
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
            assert demo001.user("jfroche").exists, "User jfroche should exist"

          with subtest("ssh relay"):
            known_hosts = demo001.file("/etc/ssh/ssh_known_hosts")
            assert known_hosts.exists, "SSH known_hosts should exist"
            assert known_hosts.contains("demo-relay-1.ocb.msf.org,108.143.32.245 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINHILWx5iekpGR4s8N8d/Aa37Vgq8ZuxNs+7eT+YvMBU"), "SSH known_hosts should contain demo-relay-1.ocb.msf.org"
        '';
      };
  };
in
(pkgs.linkFarmFromDrvs "container-tests" (lib.attrValues ubuntuTests)) // ubuntuTests
