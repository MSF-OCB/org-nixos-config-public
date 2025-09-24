{ config, lib, pkgs, ... }:

with lib;

let
  inherit (config.lib) ext_lib;

  cfg = config.settings.users;

  addGroups = new_groups: role: role // {
    extraGroups =
      let
        existing_groups = attrByPath [ "extraGroups" ] [ ] role;
      in
      existing_groups ++ new_groups;
  };

  addWhitelistCommands = newCmds: role: role // {
    whitelistCommands = (role.whitelistCommands or [ ]) ++ newCmds;
  };

  # Global admin users have the same rights as admin users but
  # are enabled by default on every server
  # This permission cannot be attributed through the JSON config
  globalAdmin = user_perms.admin // { enable = true; };

  users_json = lib.importJSON ../org-config/json/users.json;

  global_admins = builtins.listToAttrs (lib.map (user: { name = user; value = globalAdmin; }) users_json.global_admins);

  user_perms =
    let

      systemd_journal = "systemd-journal";

      # Admin users have shell access and belong to the wheel group
      admin = {
        enable = mkDefault false;
        sshAllowed = true;
        hasShell = true;
        canTunnel = true;
        extraGroups = [ "wheel" "docker" ];
      };

      dockerAdmin = addGroups [ "docker" ] remoteTunnelWithShell;

      localDockerAdmin = addGroups [ "docker" ] localShell;

      remoteTunnelWithShell = {
        enable = mkDefault false;
        sshAllowed = true;
        hasShell = true;
        canTunnel = true;
      };

      localShell = {
        enable = mkDefault false;
        sshAllowed = true;
        hasShell = true;
        canTunnel = false;
      };

      # Users who can tunnel only
      remoteTunnel = {
        enable = mkDefault false;
        sshAllowed = true;
        hasShell = false;
        canTunnel = true;
      };

      # Users who are tunnel-only but can connect to all NixOS servers and query
      # the open tunnels.
      remoteTunnelMonitor = remoteTunnel // {
        forceCommand = ''
          ${pkgs.iproute2}/bin/ss -tunl6 | \
          ${pkgs.coreutils}/bin/sort -n | \
          ${pkgs.gnugrep}/bin/egrep "\[::1\]:[0-9]{4}[^0-9]"
        '';
      };

      fieldSupport = lib.compose [
        (addGroups [ systemd_journal ])
        # Members of the field support team can reboot servers and flush DHCP
        (addWhitelistCommands ([
          "/run/current-system/sw/bin/systemctl reboot"
        ] ++
        ext_lib.mkSudoStartServiceCmds { serviceName = "dhcpcd"; }))
      ]
        remoteTunnelWithShell;

      docker_logs = lib.compose [
        (addGroups [ systemd_journal ])
        (addWhitelistCommands [
          # Be careful adding commands here!
          # Docker access can easily allow for privilege escalation.
          # Do not add any commands allowing for indirect command execution
          # such as "docker run" or "docker exec".
          # Do not add the docker command without fixing the subcommand.
          # This also applies to the docker-compose command.
          "/run/current-system/sw/bin/docker ps"
          "/run/current-system/sw/bin/docker logs *"
          "/run/current-system/sw/bin/docker-compose logs *"
        ])
      ]
        remoteTunnelWithShell;

      devops = lib.compose [
        (addGroups [ systemd_journal ])
        # Members of the devops team get some additional privileges
        (addWhitelistCommands ([
          "/run/current-system/sw/bin/systemctl reboot"
          "/run/current-system/sw/bin/dmidecode"
        ] ++
        ext_lib.mkSudoStartServiceCmds { serviceName = "nixos_rebuild_config"; } ++
        ext_lib.mkSudoStartServiceCmds { serviceName = "nixos-upgrade"; }))
      ]
        dockerAdmin;

    in
    {
      inherit admin dockerAdmin localDockerAdmin devops fieldSupport docker_logs
        remoteTunnelWithShell localShell remoteTunnel remoteTunnelMonitor;
    };
in
{
  options = {
    settings.users = {
      robot = {
        enable = mkEnableOption "the robot user";

        username = mkOption {
          type = types.str;
          default = "robot";
          readOnly = true;
          description = ''
            User used for automated access (eg. Ansible)
          '';
        };

        whitelistCommands = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
        };
      };
    };
  };

  config = {
    settings.users = {
      robot = {
        enable = true;
        whitelistCommands =
          ext_lib.mkSudoStartServiceCmds { serviceName = "nixos_rebuild_config"; } ++
          ext_lib.mkSudoStartServiceCmds { serviceName = "nixos-upgrade"; };
      };

      available_permission_profiles = user_perms;

      users = global_admins // {
        ${cfg.robot.username} = lib.mkIf cfg.robot.enable (
          user_perms.remoteTunnelWithShell // {
            enable = true;
            inherit (cfg.robot) whitelistCommands;
          }
        );
      } // lib.optionalAttrs (users_json.users ? expires)
        (lib.mapAttrs (username: expire: { expires = expire; }) users_json.users.expires);
    };

    users.users = {
      # Lock the root user
      root = {
        hashedPassword = mkForce "!";
      };
    };
  };
}
