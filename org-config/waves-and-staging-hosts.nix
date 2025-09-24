let
  stagingHosts = [
    "demo-nuc-001"
    "nixos-test"
  ];
in
{
  firstWave = stagingHosts ++ [
    "demo-test-host"
    "rescue-iso"
    "azure-template"
  ];
  middleWave = [
    "demo-uat-host"
    "demo-nuc-002"
    "demo-nuc-003"
    "demo-nuc-004"
  ];
  finalWave = [
    "demo-prod-host"
    "demo-nuc-005"
  ];
  latestWave = [
    "wsl"
    "demo-relay-1"
  ];
  inherit stagingHosts;
}
