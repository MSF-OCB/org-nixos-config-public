{ pkgs, pythonTest, qemu-common, test-instrumentation, defaultModules, flakeInputs, hosts }:
with pkgs.lib;
let
  nixosConfigurations =
    let
      hostOverrides = {
        rescue-iso = _config: {
          extraModules = [
            test-instrumentation
            {
              settings.reverse_tunnel.enable = mkForce false;
            }
          ];
        };
      };
    in
    mkNixosConfigurations {
      inherit defaultModules flakeInputs hostOverrides hosts;
    };
  iso = nixosConfigurations.rescue-iso.config.system.build.isoImage;
  isoWithKey = pkgs.runCommand "iso-with-key"
    {
      nativeBuildInputs = [ pkgs.xorriso ];
    } ''
    set -x
    mkdir $out
    cd $out
    echo "TEST" > key
    xorriso \
      -indev "${iso}/iso/${iso.name}" \
      -outdev "${iso.name}" \
      -boot_image replay replay \
      -map key id_tunnel
  '';
in
{
  benuc004 = runNixOSTest flakeInputs
    (
      { pkgs, ... }:
      {
        name = "benuc004";
        nodes = {
          machine = {
            imports = [
              ./org-config/hosts/benuc004.nix
              { _module.args = { inherit (pkgs.lib) allHosts; }; }
            ] ++ defaultModules;
            services.timesyncd.enable = mkForce false;
            settings.reverse_tunnel.enable = mkForce false;
          };
        };
        testScript = ''
          benuc004.start()
          benuc004.wait_for_unit("multi-user.target")
        '';
      }
    )
    { inherit pkgs; };
  rescue-iso =
    let
      pythonDict = params: "\n    {\n        ${concatStringsSep ",\n        " (mapAttrsToList (name: param: "\"${name}\": \"${param}\"") params)},\n    }\n";
      machineConfig = pythonDict
        {
          qemuBinary = qemu-common.qemuBinary pkgs.qemu_test;
          qemuFlags = "-m 768";
          cdrom = "${isoWithKey}/${iso.name}";
        };
    in
    pythonTest.makeTest
      {
        name = "boot-iso";
        nodes = { };
        testScript =
          ''
            machine = create_machine(${machineConfig})
            machine.start()
            machine.wait_for_unit("multi-user.target")
            assert "TEST" in machine.succeed("cat /var/lib/org-nix/id_tunnel")
            machine.shutdown()
          '';
      };
}
