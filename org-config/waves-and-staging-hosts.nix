let
  devMachines = [
    "demo-relay-1"
    "demo-nuc-001"
  ];
in
{
  firstWave = devMachines;
  finalWave = [ "demo-prod-host" ];
  latestWave = [
    "demo-uat-host"
    "wsl"
    "demo-relay-1"
    "demo-nuc-002"
    "demo-nuc-003"
    "demo-nuc-004"
    "demo-nuc-005"
    "demo-test-host"
    "nixos-test"
  ];
  stagingHosts = [
    "demo-test-host"
  ];
}
