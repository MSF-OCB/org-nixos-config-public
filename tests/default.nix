{
  linkFarmFromDrvs,
  testers,
  lib,
}:

let
  tests = {
    sshrelay = testers.runNixOSTest ./sshrelay.nix;
    docker = testers.runNixOSTest ./docker-opt.nix;
    traefik = testers.runNixOSTest ./traefik.nix;
  };
in

(linkFarmFromDrvs "vm-tests" (lib.attrValues tests))
// {
  passthru = {
    inherit tests;
  };
}
