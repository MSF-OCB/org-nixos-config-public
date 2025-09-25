{ config, lib, ... }:

with lib;

let
  inherit (config.lib) ext_lib;

  cfg = config.settings.services.deployment_services;

  deploymentServiceOptions = types.submodule ({ name, ... }: {
    options = {
      enable = (mkEnableOption "the ${name} service") // { default = true; };
      deploy_dir_name = mkOption { type = types.str; };
      github_repo = mkOption { type = types.str; };
      git_branch = mkOption { type = types.str; default = "main"; };
      pre-compose_script = mkOption { type = types.str; default = "deploy/pre-compose.sh"; };
      extra_script = mkOption { type = types.str; default = ""; };
      restart = mkOption { type = types.bool; default = false; };
      force_build = mkOption { type = types.bool; default = false; };
      docker_compose_files = mkOption { type = types.listOf types.str; default = [ "docker-compose.yml" ]; };
      secrets_dir = mkOption { type = types.str; default = "/run/secrets"; };
    };
  });

in
{

  options.settings.services.deployment_services = mkOption {
    type = types.attrsOf deploymentServiceOptions;
  };

  config =
    let
      enabledDeploymentServices = lib.filterEnabled cfg;
      enabledDeploymentUnits = lib.mapAttrs (_n: ext_lib.mkDeploymentUnit) enabledDeploymentServices;
    in
    mkMerge [
      {
        # Configure services by adding to the "deployment_services" attrset.
        settings.services.deployment_services = {
          update_demo_app_config = {
            deploy_dir_name = "demo-app";
            github_repo = "demo-app";
          };
        };
      }
      {
        # Implementation: Map "deployment_services" to lower-level NixOS Options.
        systemd.services = enabledDeploymentUnits;

        settings.users.robot.whitelistCommands =
          let
            mkStartCmds = serviceName:
              ext_lib.mkSudoStartServiceCmds { inherit serviceName; };
          in
          lib.compose [
            (concatMap mkStartCmds)
            attrNames
          ]
            enabledDeploymentUnits;
      }
    ];
}
