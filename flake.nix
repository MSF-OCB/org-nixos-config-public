{
  inputs = {
    systems.url = "github:nix-systems/x86_64-linux";

    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
    };

    nixpkgs-legacy.url = "github:NixOS/nixpkgs/nixos-24.11-small";
    nixpkgs-latest.url = "github:NixOS/nixpkgs/nixos-25.05-small";

    disko = {
      url = "github:nix-community/disko";
      inputs = {
        nixpkgs.follows = "nixpkgs-latest";
      };
    };

    devshell = {
      url = "github:numtide/devshell";
      inputs = {
        nixpkgs.follows = "nixpkgs-latest";
      };
    };
    srvos = {
      url = "github:numtide/srvos";
      inputs = {
        nixpkgs.follows = "nixpkgs-latest";
      };
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs-latest";
    };
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs = {
        nixpkgs.follows = "nixpkgs-latest";
        flake-compat.follows = "flake-compat";
      };
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs-latest";
    };
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs-latest";
        flake-compat.follows = "flake-compat";
      };
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs-latest";
    };
    server-lock = {
      url = "github:msf-ocb/nixos_server_lock";
      inputs = {
        systems.follows = "systems";
        flake-utils.follows = "flake-utils";
        nixpkgs.follows = "nixpkgs-latest";
        devshell.follows = "devshell";
      };
    };
    nix-github-actions = {
      url = "github:nix-community/nix-github-actions";
      inputs.nixpkgs.follows = "nixpkgs-latest";
    };
  };

  outputs =
    { self
    , systems
    , nix-index-database
    , devshell
    , treefmt-nix
    , pre-commit-hooks
    , nix-github-actions
    , ...
    }@flakeInputs:
    let
      # Get a lib instance that we use only in the scope of this flake.
      # The actual NixOS configs use their own instances of nixpkgs.
      inherit (self.legacyPackages."x86_64-linux".nixpkgs-latest) lib;

      eachSystem = flakeInputs.nixpkgs-latest.lib.genAttrs (import systems);

      hostConfigFunction = import ./host-config.nix {
        inherit lib;
        flake = self;
      };

      hosts = (lib.mapAttrs (hostname: _: hostConfigFunction {
        inherit hostname;
      })) lib.allHosts;

      treefmt-config = {
        projectRootFile = "flake.nix";
        programs = {
          nixpkgs-fmt.enable = true;
          shellcheck.enable = true;
          shfmt.enable = true;
          statix = {
            enable = true;
            disabled-lints = [
              "empty_pattern"
              "eta_reduction"
              "faster_groupby"
              "faster_zipattrswith"
            ];
          };
          prettier.enable = true;
          ruff = {
            check = true;
            format = true;
          };
        };
        settings = {
          global.excludes = [
            "org-config/secrets/**"
            "org-config/app_configs/generated/**"
          ];
          formatter = {
            prettier = {
              options = [
                "--trailing-comma"
                "all"
              ];
            };
            ruff-check = {
              options = [
                # Ignore errors about line length
                "--ignore"
                "E501"
              ];
            };
          };
        };
      };
    in
    {
      # expose a Github matrix via `nix eval --json '.#githubActions.matrix'
      # currently it builds all the toplevel packages for each nixos configuration
      githubActions =
        nix-github-actions.lib.mkGithubMatrix {

          # Uncomment the following section to change the runner that is used for building a given system:
          #
          #  githubPlatforms = {
          #    "x86_64-linux" = "ubuntu-24.04";
          #    "x86_64-darwin" = "macos-13";
          #    "aarch64-darwin" = "macos-14";
          #    "aarch64-linux" = "ubuntu-24.04-arm";
          #  };

          checks = eachSystem (system:
            lib.mapAttrs'
              (n: v: {
                name = "nixos-${n}";
                value = v.config.system.build.toplevel;
              })
              (
                lib.filterAttrs
                  (_: v: v.config.nixpkgs.pkgs.stdenv.hostPlatform.system == system)
                  self.nixosConfigurations
              )
          );
        };

      nixosModules.default = [
        ./modules
        ./org-config
        flakeInputs.disko.nixosModules.default
        ({ lib, pkgs, ... }: {
          imports = [
            nix-index-database.nixosModules.nix-index
          ];
          programs.nix-index.package = pkgs.nix-index-with-db;
        })
      ];

      nixosConfigurations =
        let
          # The arguments to the evalHost function can be overridden here
          # on a per-host basis, e.g.
          #   rescue-iso = { nixpkgs = nixpkgs-latest; extraModules = [ { ... } ]; };
          # This is only meant for temporary ad-hoc overrides,
          # anything else should probably be done in host-config.nix instead.
          hostOverrides = { };
          hosts = lib.mapAttrs
            (hostname: _: hostConfigFunction {
              inherit hostname;
            })
            lib.allHosts;
        in
        lib.mkNixosConfigurations {
          inherit flakeInputs hosts hostOverrides;
          defaultModules = self.nixosModules.default;
        };

      packages = eachSystem (system:
        let
          pkgs = self.legacyPackages.${system}.nixpkgs-latest;
        in
        {
          nixostools =
            pkgs.callPackage ./scripts/python_nixostools/default.nix { };

          treefmtWrapper = treefmt-nix.lib.mkWrapper pkgs treefmt-config;

          inherit (pkgs) nix-eval-jobs;
        }
        //
        # Targets to build QEMU virtual machines that can be used for local testing or debugging.
        # You can build the VM with:
        #   nix build '.#nixos-dev-vm'
        lib.flip lib.mapAttrs' self.nixosConfigurations
          (hostname: nixosConfig:
            lib.nameValuePair "${hostname}-vm" nixosConfig.config.system.build.vm
          )
        //
        # Installation images
        {
          rescue-iso-img = self.nixosConfigurations.rescue-iso.config.system.build.isoImage;
        }
      );

      legacyPackages = eachSystem (system:
        let
          mkInstance = nixpkgs: extraOverlays: (import nixpkgs {
            inherit system;
            # We need to permit node 16 as an insecure package since it is used
            # by the github-runners module. More and more github actions will be
            # using nodejs 20 so we will be able to remove this soon.
            config.permittedInsecurePackages = [
              "nodejs_20"
            ];
            overlays = [
              nix-index-database.overlays.nix-index
              flakeInputs.server-lock.overlays.default
              devshell.overlays.default
              (final: prev: {
                ocb-nixostools = final.callPackage ./scripts/python_nixostools { };

                lib = (prev.lib.extend (import ./lib.nix)).extend (final: prev: {
                  # nixosSystem by default passes the import of nixpkgs' lib/default.nix.
                  # It is not aware of the overlay that we added when we created the nixpkgs
                  # instance, so we pass that extended lib here explicitly.
                  nixosSystem = args: nixpkgs.lib.nixosSystem ({ lib = final; } // args);
                });

                # Register the nixpkgs flake so we can use it in NixOS to set the registry entry.
                nixpkgsFlake = nixpkgs;

                # We overwrite the command-not-found script here instead of
                # in nix-index-unwrapped to avoid needing to rebuild nix-index-unwrapped
                # from source everytime because of the changed hash.
                nix-index-with-db = prev.nix-index-with-db.overrideAttrs (_: prevAttrs: {
                  buildCommand =
                    let
                      destination = "$out/etc/profile.d/command-not-found.sh";
                    in
                    (prevAttrs.buildCommand or "") + ''
                      if [ ! -f "${destination}" ]; then
                        echo "command-not-found.sh was not found, something changed in the nix-index package!"
                        exit 1
                      fi
                      unlink $out/etc/profile.d/command-not-found.sh
                      substitute \
                        "${./command-not-found.sh}" \
                        "$out/etc/profile.d/command-not-found.sh" \
                        --replace "@out@" "$out"
                    '';
                });
              })
            ] ++ extraOverlays;
          }) // nixpkgs.sourceInfo;
        in
        {
          nixpkgs-latest = mkInstance self.inputs.nixpkgs-latest [ ];
          nixpkgs-legacy = mkInstance self.inputs.nixpkgs-legacy [ ];
        });

      # Targets to easily access the config of a host in the nix REPL.
      # Example REPL session:
      #
      # $ nix repl
      # Welcome to Nix 2.13.3. Type :? for help.
      #
      # nix-repl> :lf .
      # Added 13 variables.
      #
      # nix-repl> configs.sshrelay2.time.timeZone
      # "Europe/Brussels"
      configs = lib.mapAttrs (hostname: nixosConfig: nixosConfig.config) self.nixosConfigurations;
      # Target that can be used with nix-eval-jobs
      # In bash: nix build $(jq --raw-output '.drvPath | "\(.)^*"' < <(nix run 'nixpkgs#nix-eval-jobs' -- --flake '.#allSystems' --workers 4))
      # In fish: nix build (jq --raw-output '.drvPath | "\(.)^*"' < (nix run 'nixpkgs#nix-eval-jobs' -- --flake '.#allSystems' --workers 4 | psub))
      allSystems = lib.mapAttrs (_: nixos: nixos.config.system.build.toplevel) self.nixosConfigurations;

      devShells = eachSystem (system:
        let
          pkgs = self.legacyPackages.${system}.nixpkgs-latest;
        in
        {
          default = pkgs.devshell.mkShell {
            packages =
              let
                pkgs = self.legacyPackages.${system}.nixpkgs-latest;
              in
              [
                pkgs.azure-cli
                pkgs.ruff
                self.packages.${system}.treefmtWrapper
                pkgs.nil
                # jq and xorriso are used to build the rescue ISO
                pkgs.jq
                pkgs.xorriso
                pkgs.nixpkgs-fmt
              ];
            env = [{
              name = "DEVSHELL_NO_MOTD";
              value = "1";
            }];
            commands = [
              {
                name = "fmt";
                help = "Format code";
                command = "nix fmt";
              }
              {
                name = "check-configs";
                help = "Check all configurations";
                command = "nix flake check -L";
              }
              {
                name = "check";
                help = "Check the code";
                command = "pre-commit run --all-files";
              }
              {
                name = "build";
                help = "Build a system";
                command = "nix build .#nixosConfigurations.$1.config.system.build.toplevel";
              }
            ];
            devshell.startup.pre-commit.text = self.checks.${system}.pre-commit-check.shellHook;
          };
        });

      # Create a set of builders that can build a subset of the nixos configs defined by
      # this flake.
      # We distribute configs evenly between all builders.
      checks = eachSystem (system:
        let
          pkgs = self.legacyPackages.${system}.nixpkgs-latest;
        in
        # Build all the other packages as well
        self.packages.${system}
        //
        {
          pre-commit-check = pre-commit-hooks.lib.${system}.run {
            src = ./.;
            tools = {
              inherit (pkgs) nil;
            };
            hooks = {
              nil.enable = true;
              treefmt = {
                enable = true;
                package = self.packages.${system}.treefmtWrapper;
                pass_filenames = lib.mkForce false;
              };
            };
          };

          vmTests = pkgs.callPackage ./tests/default.nix { };
        }
        //
        (import ./test.nix {
          qemu-common =
            import "${flakeInputs.nixpkgs-latest}/nixos/lib/qemu-common.nix" {
              inherit (pkgs) lib pkgs;
            };
          pythonTest =
            import "${flakeInputs.nixpkgs-latest}/nixos/lib/testing-python.nix" {
              inherit (pkgs.stdenv.hostPlatform) system;
            };
          inherit pkgs hostConfigFunction flakeInputs hosts;
          defaultModules = self.nixosModules.default;
          test-instrumentation =
            "${flakeInputs.nixpkgs-latest}/nixos/modules/testing/test-instrumentation.nix";
        })
      );
      formatter = eachSystem (system: self.packages.${system}.treefmtWrapper);
    };
}
