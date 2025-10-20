{ config, lib, pkgs, ... }:

let
  mkSudoStartServiceCmds =
    { serviceName
    , extraOpts ? [ "--system" ]
    }:
    let
      optsStr = lib.concatStringsSep " " extraOpts;
      mkStartCmd = service: "/run/current-system/sw/bin/systemctl ${optsStr} start ${service}";
    in
    [
      (mkStartCmd serviceName)
      (mkStartCmd "${serviceName}.service")
    ];

  reset_git =
    { url
    , branch
    , git_options
    , indent ? 0
    }:
    let
      git = "${pkgs.git}/bin/git";
      mkOptionsStr = lib.concatStringsSep " ";
      mkGitCommand = git_options: cmd: "${git} ${mkOptionsStr git_options} ${cmd}";
      mkGitCommandIndented = indent: git_options:
        lib.compose [ (lib.indentStr indent) (mkGitCommand git_options) ];
    in
    lib.concatMapStringsSep "\n" (mkGitCommandIndented indent git_options) [
      ''remote set-url origin "${url}"''
      # The following line is only used to avoid the warning emitted by git.
      # We will reset the local repo anyway and remove all local changes.
      ''config pull.rebase true''
      ''fetch origin ${branch}''
      ''checkout ${branch} --''
      ''reset --hard origin/${branch}''
      ''clean -d --force''
      ''pull''
    ];

  clone_and_reset_git =
    { clone_dir
    , github_repo
    , branch
    , git_options ? [ ]
    , indent ? 0
    }:
    let
      repo_url = config.settings.system.org.repo_to_url github_repo;
    in
    lib.optionalString (config != null) ''
      if [ ! -d "${clone_dir}" ] || [ ! -d "${clone_dir}/.git" ]; then
        if [ -d "${clone_dir}" ]; then
          # The directory exists but is not a git clone
          ${pkgs.coreutils}/bin/rm --recursive --force "${clone_dir}"
        fi
        ${pkgs.coreutils}/bin/mkdir --parent "${clone_dir}"
        ${pkgs.git}/bin/git clone "${repo_url}" "${clone_dir}"
      fi
      ${reset_git { inherit branch indent;
                    url = repo_url;
                    git_options = git_options ++ [ "-C" ''"${clone_dir}"'' ]; }}
    '';

  mkDeploymentService =
    { enable ? true
    , deploy_dir_name
    , github_repo
    , git_branch ? "main"
    , pre-compose_script ? "deploy/pre-compose.sh"
    , extra_script ? ""
    , restart ? false
    , force_build ? false
    , docker_compose_files ? [ "docker-compose.yml" ]
    }:
    let
      secrets_dir = "/run/secrets";
      app_configs_dir = config.settings.system.app_configs.dest_directory;
      deploy_dir = "/opt/${deploy_dir_name}";
      pre-compose_script_path = "${deploy_dir}/${pre-compose_script}";
    in
    {
      inherit enable;
      serviceConfig = {
        Type = "oneshot";
        WorkingDirectory = "-${deploy_dir}";
      };

      /* We need to explicitly set the docker runtime dependency
       since docker-compose does not depend on docker.
       Nix is included so that nix-shell can be used in the external scripts
       called dynamically by this function.
       Bash is included because several pre-compose scripts depend on it.
      */
      path = with pkgs; [ nix docker bash ];

      environment =
        let
          inherit (config.settings.system) github_private_key;
          inherit (config.settings.system.org) env_var_prefix;
        in
        {
          # We need to set the NIX_PATH env var so that we can resolve <nixpkgs>
          # references when using nix-shell.
          inherit (config.environment.sessionVariables) NIX_PATH;
          GIT_SSH_COMMAND = lib.concatStringsSep " " [
            "${pkgs.openssh}/bin/ssh"
            "-F /etc/ssh/ssh_config"
            "-i ${github_private_key}"
            "-o IdentitiesOnly=yes"
            "-o StrictHostKeyChecking=yes"
          ];
          "${env_var_prefix}_SECRETS_DIRECTORY" = secrets_dir;
          "${env_var_prefix}_CONFIGS_DIRECTORY" = app_configs_dir;
          "${env_var_prefix}_DEPLOY_DIR" = deploy_dir;
        };
      script =
        let
          docker_creds_prefix = "docker_private_repo_creds";
          docker_creds_prefix_length = builtins.stringLength docker_creds_prefix;
          forEachDockerRepo = body: ''
            for secret_file in $(ls "${secrets_dir}"); do
              if [ "''${secret_file::${toString docker_creds_prefix_length}}" = \
                   "${docker_creds_prefix}" ]; then
                source "${secrets_dir}/''${secret_file}"
                ${body}
              fi
            done
          '';

          docker_login = forEachDockerRepo ''
            echo "logging in to ''${DOCKER_PRIVATE_REPO_URL}..."

            echo ''${DOCKER_PRIVATE_REPO_PASS} | \
            ${pkgs.docker}/bin/docker login \
              --username "''${DOCKER_PRIVATE_REPO_USER}" \
              --password-stdin \
              "''${DOCKER_PRIVATE_REPO_URL}"
          '';

          docker_logout = forEachDockerRepo ''
            ${pkgs.docker}/bin/docker logout "''${DOCKER_PRIVATE_REPO_URL}"
          '';
        in
        ''
          ${clone_and_reset_git { inherit github_repo;
                                  clone_dir = deploy_dir;
                                  branch = git_branch; }}

          # Change to the deploy dir in case it did not exist yet
          # when the service started.
          # The previous command should have created it in that case.
          cd "${deploy_dir}"

          echo "Log in to all defined docker repos..."
          ${docker_login}


          if [ -x "${pre-compose_script_path}" ]; then
            echo "Running the pre-compose.sh script..."
            "${pre-compose_script_path}"
          else
            echo "Pre-compose script (${pre-compose_script_path}) does not exist or is not executable, skipping."
          fi

          ${extra_script}

          ${pkgs.docker-compose}/bin/docker-compose \
            --project-directory "${deploy_dir}" \
            ${lib.concatMapStringsSep " " (s: ''--file "${deploy_dir}/${s}"'') docker_compose_files} \
            --ansi never \
            ${if restart
              then "restart"
              else ''up --detach --remove-orphans ${lib.optionalString force_build "--build"}''
            }

          echo "Log out of all docker repos..."
          ${docker_logout}
        '';
    };
in
{
  config.lib.ext_lib = {
    inherit mkSudoStartServiceCmds mkDeploymentService;
  };
}
