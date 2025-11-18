{
  lib,
  flake,
}:

{ hostname }:

let
  inherit (lib) allHosts;

  defaultSystem = "x86_64-linux";

  mkLatestConfig =
    system:
    lib.trace "Using latest config" {
      inherit system;
      nixpkgs = flake.legacyPackages.${system}.nixpkgs-latest;
    };
  mkFirstWaveConfig =
    system:
    lib.trace "Using first-wave config" {
      inherit system;
      nixpkgs = flake.legacyPackages.${system}.nixpkgs-latest;
    };
  mkMiddleWaveConfig =
    system:
    lib.trace "Using middle-wave config" {
      inherit system;
      nixpkgs = flake.legacyPackages.${system}.nixpkgs-latest;
    };
  mkFinalWaveConfig =
    system:
    lib.trace "Using final-wave config" {
      inherit system;
      nixpkgs = flake.legacyPackages.${system}.nixpkgs-latest;
    };

  waves = import ./org-config/waves-and-staging-hosts.nix;

  mkWave =
    let
      assertHostExists =
        hostname:
        lib.throwIfNot (lib.elem hostname (lib.attrNames allHosts)) "host with name ${hostname} defined in ./org-config/waves-and-staging-hosts.nix not found in the repo";
    in
    hostnames: mkConfig:
    lib.listToAttrs (
      lib.map (
        hostname:
        # We do the validation in the attribute names since attrsets are strict in their
        # names and so we will get an error even if we're evaluating another host.
        # This allows for errors to be detected earlier.
        lib.nameValuePair (assertHostExists hostname hostname) (mkConfig defaultSystem)
      ) hostnames
    );

  firstWave = mkWave waves.firstWave mkFirstWaveConfig;
  middleWave = mkWave waves.middleWave mkMiddleWaveConfig;
  finalWave = mkWave waves.finalWave mkFinalWaveConfig;
  # These hosts always use the latest nixpkgs version since they are extra security critical, like the relays
  latest = mkWave waves.latestWave mkLatestConfig;

  # lib.mergeDisjoint fails when there's duplicated entries in ./org-config/waves-and-staging-hosts.nix
  mergedWaves = lib.mergeDisjoint [
    firstWave
    middleWave
    finalWave
    latest
  ];

  diff = lib.subtractLists (lib.attrNames mergedWaves) (lib.attrNames allHosts);
  config =
    lib.throwIfNot (builtins.length diff == 0)
      "you forgot to define in ./org-config/waves-and-staging-hosts.nix a wave for these machines: ${builtins.toString diff}"
      mergedWaves.${hostname};
in
lib.trace "host-config selected nixpkgs version ${lib.versions.majorMinor config.nixpkgs.lib.version}" config
