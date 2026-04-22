{
  lib,
  pkgs,
  options,
  ...
}:

let
  isSystemManager = options ? system-manager;
in

{
  config = {
    nix = {
      enable = true;

      registry.nixpkgs = {
        from = {
          type = "indirect";
          id = "nixpkgs";
        };
        flake = pkgs.nixpkgsFlake;
      };

      # man nix.conf
      settings = {
        auto-optimise-store = true;
        trusted-users = [
          "root"
          "@wheel"
        ];
        builders-use-substitutes = true;
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        # Fall back to building from source if we cannot substitute
        fallback = true;
        # Disable the global flake registry
        flake-registry = "";
      };
    }
    // lib.optionalAttrs (!isSystemManager) {
      nixPath = [
        "nixpkgs=flake:nixpkgs"
      ];
    };
  };
}
