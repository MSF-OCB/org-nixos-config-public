{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.rsyncBackup;

  jumpKey = if cfg.jumpPrivateKey != null then cfg.jumpPrivateKey else cfg.privateKey;
  usesPassword = cfg.authentication == "password";

  proxyCommand =
    "${pkgs.openssh}/bin/ssh "
    + "-i ${escapeShellArg jumpKey} "
    + "-o IdentitiesOnly=yes "
    + "-o BatchMode=yes "
    + "-o ServerAliveInterval=60 "
    + "-o StrictHostKeyChecking=${if cfg.strictHostKeyChecking then "yes" else "no"} "
    + optionalString (!cfg.strictHostKeyChecking) "-o UserKnownHostsFile=/dev/null "
    + optionalString (cfg.jumpPort != 22) "-p ${toString cfg.jumpPort} "
    + "-W [%h]:%p "
    + "${cfg.jumpUser}@${cfg.jumpHost}";

  sshCommand = concatStringsSep " " (
    [
      "${pkgs.openssh}/bin/ssh"
      "-p ${toString cfg.port}"
      "-o ServerAliveInterval=60"
      "-o StrictHostKeyChecking=${if cfg.strictHostKeyChecking then "yes" else "no"}"
    ]
    ++ optionals (!usesPassword) [
      "-i ${escapeShellArg cfg.privateKey}"
      "-o IdentitiesOnly=yes"
      "-o BatchMode=yes"
    ]
    ++ optionals usesPassword [
      "-o PreferredAuthentications=password"
      "-o PubkeyAuthentication=no"
      "-o NumberOfPasswordPrompts=1"
    ]
    ++ optional (!cfg.strictHostKeyChecking) "-o UserKnownHostsFile=/dev/null"
    ++ optional (cfg.jumpHost != null) "-o ProxyCommand=${escapeShellArg proxyCommand}"
  );

  passwordCommand = optionalString usesPassword "${pkgs.sshpass}/bin/sshpass -f ${escapeShellArg cfg.passwordFile} ";

  excludeArgs = concatStringsSep " " (
    map (pattern: "--exclude=${escapeShellArg pattern}") cfg.excludes
  );

  rsyncPathArg = optionalString (
    cfg.remoteRsyncPath != null
  ) "--rsync-path=${escapeShellArg cfg.remoteRsyncPath}";

  rsyncCommand = ''
    ${passwordCommand}${pkgs.rsync}/bin/rsync \
      ${concatStringsSep " " cfg.rsyncOptions} \
      ${excludeArgs} \
      ${rsyncPathArg} \
      -e ${escapeShellArg sshCommand} \
      ${escapeShellArg cfg.source} \
      ${escapeShellArg "${cfg.remoteUser}@${cfg.host}:${cfg.destination}"}
  '';
in
{
  options.services.rsyncBackup = {
    enable = mkEnableOption "rsync backup service";

    enableTimer = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable the systemd timer for scheduled runs.";
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = "Local user running the service.";
    };

    group = mkOption {
      type = types.str;
      default = "root";
      description = "Local group running the service.";
    };

    source = mkOption {
      type = types.str;
      description = "Local source path to sync.";
    };

    host = mkOption {
      type = types.str;
      description = "Remote SSH host. Can also be localhost when using a relay/jump pattern.";
    };

    port = mkOption {
      type = types.port;
      default = 22;
      description = "Remote SSH port.";
    };

    remoteUser = mkOption {
      type = types.str;
      description = "Remote SSH user.";
    };

    destination = mkOption {
      type = types.str;
      description = "Remote destination path.";
    };

    authentication = mkOption {
      type = types.enum [
        "key"
        "password"
      ];
      default = "key";
      description = "SSH authentication method for the remote rsync host.";
    };

    privateKey = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "SSH private key path. Required when authentication is key.";
    };

    passwordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/password";
      description = "File containing the SSH password. Required when authentication is password; use a runtime secret outside the Nix store.";
    };

    jumpPrivateKey = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Optional SSH private key for the jump host. Falls back to privateKey if null.";
    };

    jumpHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional SSH jump host.";
    };

    jumpUser = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "SSH user for the jump host.";
    };

    jumpPort = mkOption {
      type = types.port;
      default = 22;
      description = "SSH port for the jump host.";
    };

    remoteRsyncPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional remote rsync binary/path, e.g. sudo rsync.";
    };

    rsyncOptions = mkOption {
      type = types.listOf types.str;
      default = [
        "-a"
        "-z"
        "--delete"
      ];
      example = [
        "-a"
        "-z"
        "-v"
        "--delete"
        "--no-p"
        "--chmod=ugo=rwX"
      ];
      description = "List of rsync options.";
    };

    excludes = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "*.tmp"
        ".cache"
        "node_modules"
      ];
      description = "Exclude patterns passed to rsync.";
    };

    strictHostKeyChecking = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enable strict host key checking.";
    };

    startAt = mkOption {
      type = types.str;
      default = "daily";
      example = "03:00";
      description = "systemd OnCalendar value used when enableTimer = true.";
    };

    debug = mkOption {
      type = types.bool;
      default = false;
      description = "Enable verbose SSH debugging.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = usesPassword || cfg.privateKey != null;
          message = "services.rsyncBackup.privateKey is required when authentication is key.";
        }
        {
          assertion = !usesPassword || cfg.passwordFile != null;
          message = "services.rsyncBackup.passwordFile is required when authentication is password.";
        }
        {
          assertion = cfg.jumpHost == null || jumpKey != null;
          message = "services.rsyncBackup.jumpPrivateKey is required for a jump host when password authentication is used for the remote host.";
        }
        {
          assertion = cfg.jumpHost == null || cfg.jumpUser != null;
          message = "services.rsyncBackup.jumpUser is required when jumpHost is configured.";
        }
      ];

      systemd.services.rsync-backup = {
        description = "Rsync backup service";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        path = [
          pkgs.rsync
          pkgs.openssh
        ]
        ++ optional usesPassword pkgs.sshpass;

        serviceConfig = {
          ExecStartPre = optional (!usesPassword) "${pkgs.coreutils}/bin/chmod 600 ${cfg.privateKey}";
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };

        script = ''
          ${optionalString cfg.debug "set -x"}
          ${rsyncCommand}
        '';
      };
    }

    (mkIf cfg.enableTimer {
      systemd.timers.rsync-backup = {
        description = "Timer for rsync backup service";
        wantedBy = [ "timers.target" ];

        timerConfig = {
          OnCalendar = cfg.startAt;
          Persistent = true;
        };
      };
    })
  ]);
}
