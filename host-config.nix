{ lib
, flake
}:

{ hostname }:

let
  inherit (lib) allHosts;

  defaultSystem = "x86_64-linux";

  mkLatestConfig = system: lib.trace "Using latest config" {
    inherit system;
    nixpkgs = flake.legacyPackages.${system}.nixpkgs-latest;
  };
  mkFirstWaveConfig = system: lib.trace "Using first-wave config" {
    inherit system;
    nixpkgs = flake.legacyPackages.${system}.nixpkgs-latest;
  };
  mkFinalWaveConfig = system: lib.trace "Using final-wave config" {
    inherit system;
    nixpkgs = flake.legacyPackages.${system}.nixpkgs-latest;
  };
  defaultConfig =
    let
      system = defaultSystem;
    in
    lib.trace "Using default config" {
      inherit system;
      nixpkgs = flake.legacyPackages.${system}.nixpkgs-latest;
    };

  waves = lib.importJSON ./org-config/json/waves-and-staging-hosts.json;

  mkWave =
    let
      assertHostExists = hostname:
        lib.throwIfNot
          (lib.elem hostname (lib.attrNames allHosts))
          "host with name ${hostname} defined in waves-and-staging-hosts.json not found in the repo!";
    in
    hostnames: mkConfig: lib.listToAttrs (
      lib.map
        (hostname:
          # We do the validation in the attribute names since attrsets are strict in their
          # names and so we will get an error even if we're evaluating another host.
          # This allows for errors to be detected earlier.
          lib.nameValuePair (assertHostExists hostname hostname) (mkConfig defaultSystem)
        )
        hostnames
    );

  firstWave = mkWave waves.firstWave mkFirstWaveConfig;
  finalWave = mkWave waves.finalWave mkFinalWaveConfig;
  # These hosts always use the latest nixpkgs version since they are extra security critical, like the relays
  latest = mkWave waves.latestWave mkLatestConfig;

  config = (lib.mergeDisjoint [ firstWave finalWave latest ]).${hostname} or defaultConfig;
in
lib.trace "host-config selected nixpkgs version ${lib.versions.majorMinor config.nixpkgs.lib.version}"
  config
