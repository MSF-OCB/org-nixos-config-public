{ config, lib, ... }:

let
  inherit (config.lib) ext_lib;

  cfg = config.settings.services.deployment_services;
in

{
  options.settings.services.deployment_services = {
    update_demo_app_config.enable =
      lib.mkEnableOption "the update_demo_app_config service";

  };

  config =
    let
      deployment_services = {

        update_demo_app_config =
          ext_lib.mkDeploymentService {
            inherit (cfg.update_demo_app_config) enable;
            deploy_dir_name = "demo-app";
            github_repo = "demo-app";
            git_branch = "main";
            pre-compose_script = "deploy/pre-compose.sh";
            docker_compose_files = [
              "docker-compose.yml"
            ];
          };

      };

      enabled_deployment_services = lib.filterEnabled deployment_services;
    in
    {
      systemd.services = enabled_deployment_services;

      settings.users.robot.whitelistCommands =
        let
          mkStartCmds = serviceName:
            ext_lib.mkSudoStartServiceCmds { inherit serviceName; };
        in
        lib.compose [
          (lib.concatMap mkStartCmds)
          lib.attrNames
        ]
          enabled_deployment_services;
    };
}
