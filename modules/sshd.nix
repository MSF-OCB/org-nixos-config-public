{ config, pkgs, lib, ... }:

let
  cfg_users = config.settings.users.users;
  cfg_rev_tun = config.settings.reverse_tunnel;
in

{
  options = {
    settings = {
      sshd.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      fail2ban.enable = lib.mkOption {
        type = lib.types.bool;
        default = !config.settings.sshguard.enable;
      };
      sshguard.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };
  };

  config = {
    services = {
      openssh =
        let
          # We define a function to build the Match section defining the
          # configured ForceCommand settings.
          # For users having a ForceCommand configured, we group together all users
          # having the same ForceCommand and then generate a Match section for every
          # such group of users.
          buildForceCommandSection =
            let
              hasForceCommand = _: user: user.enable && user.forceCommand != null;

              filterForceCommand = lib.filterAttrs hasForceCommand;

              # Nix strings that refer to store paths, like the string holding the
              # ForceCommand in this case, carry a context that tracks the
              # dependencies that need to be present in the store in order for this
              # string to actually make sense. So in the case of the ForceCommand
              # here, the context would track the executables present in the command
              # string, like e.g.  ${pkgs.docker}/bin/docker}.
              # If Nix did not do this, then it could not guarantee that executables
              # mentioned in the string, will actually be present in the store of
              # the resulting system.
              #
              # However, Nix does not allow for strings carrying such contexts to be
              # used as keys to attribute sets (the reason for this seems to be
              # related to how attribute sets are internally represented).
              # And therefore the groupBy command cannot use the forceCommand string
              # as a key to group by.
              #
              # So, we need to use unsafeDiscardStringContext which discards the
              # string's context, after which Nix allows us to use the string as
              # a key in an attribute set.
              # We need to be careful though, since this means that the keys do not
              # carry any dependency information anymore and so if we would use these
              # keys to construct the resulting sshd_config file, then the dependencies
              # would not actually be included in the Nix store.
              # We therefore hash the string, which ensures that it can only be used
              # as a key but does not actually contain usable content anymore.
              # By doing so, we make sure that to build the final sshd_config file,
              # we need to grab the original string, with dependency context included,
              # from the users in the group.
              hashCommand = lib.compose [
                (builtins.hashString "sha256")
                builtins.unsafeDiscardStringContext
              ];

              # As explained above, we cannot use the key of the groupBy result.
              # Instead we get the forceCommand, including dependency context, from
              # the actual users.
              # Since we grouped the users by command, they are guaranteed to all
              # have the same forceCommand value and we can simply look at the first
              # one in the list (which is also guaranteed to be non empty).
              cleanResults = lib.mapAttrs (_: users: {
                inherit (builtins.head users) forceCommand;
                users = map (user: user.name) users;
              });

              groupByCommand =
                let
                  doGroupByCommand = lib.groupBy (user: hashCommand user.forceCommand);
                in
                lib.compose [
                  cleanResults
                  doGroupByCommand
                  lib.attrValues
                ];

              toCfgs = lib.mapAttrsToList (_: res: ''
                Match User ${lib.concatStringsSep "," res.users}
                PermitTTY no
                ForceCommand ${pkgs.writeShellScript "ssh_force_command" res.forceCommand}
              '');

            in
            lib.compose [
              (lib.concatStringsSep "\n")
              toCfgs
              groupByCommand
              filterForceCommand
            ];
        in
        {
          inherit (config.settings.sshd) enable;
          startWhenNeeded = true;
          settings = {
            X11Forwarding = false;
            KexAlgorithms = [
              "sntrup761x25519-sha512@openssh.com"
              "curve25519-sha256@libssh.org"
            ];
            Ciphers = [
              "aes256-gcm@openssh.com"
              "chacha20-poly1305@openssh.com"
            ];
            Macs = [
              "hmac-sha2-512-etm@openssh.com"
              "hmac-sha2-256-etm@openssh.com"
              "umac-128-etm@openssh.com"
            ];
            PermitRootLogin = "prohibit-password";
            PasswordAuthentication = false;
            ChallengeResponseAuthentication = false;
            KbdInteractiveAuthentication = false;
          };
          # Ignore the authorized_keys files in the users' home directories,
          # keys should be added through the config.
          authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
          allowSFTP = true;
          extraConfig = ''
            StrictModes yes
            AllowAgentForwarding no
            TCPKeepAlive yes
            ClientAliveInterval 10
            ClientAliveCountMax 5

            ${lib.optionalString cfg_rev_tun.relay.enable ''
              # See man sshd_config
              # We increase this value for the relays since we sometimes get bursts of
              # authentication attempts when many remote servers connect after the relay
              # was down.
              # We start dropping 30% of connections when we exceed 100 open, unauthenticated connections.
              # We drop all new connections when we reach 300 open, unauthenticated connections.
              MaxStartups 100:30:300
            ''}

            AllowGroups wheel ${config.settings.users.ssh-group}

            AllowTcpForwarding no
            AllowAgentForwarding no

            Match Group wheel
              AllowTcpForwarding yes

            Match Group ${config.settings.users.rev-tunnel-group},!wheel
              AllowTcpForwarding remote

            Match Group ${config.settings.users.fwd-tunnel-group},!wheel
              AllowTcpForwarding local

            ${buildForceCommandSection cfg_users}
          '';
        };

      fail2ban = lib.mkIf config.settings.fail2ban.enable {
        inherit (config.settings.fail2ban) enable;
        jails.ssh-iptables = lib.mkForce "";
        jails.ssh-iptables-extra = ''
          action   = iptables-multiport[name=SSH, port="${
            lib.concatMapStringsSep "," toString config.services.openssh.ports
          }", protocol=tcp]
          maxretry = 3
          findtime = 3600
          bantime  = 3600
          filter   = sshd[mode=extra]
        '';
      };

      sshguard = lib.mkIf config.settings.sshguard.enable {
        inherit (config.settings.sshguard) enable;
        # We are a bit more strict on the relays
        attack_threshold =
          if cfg_rev_tun.relay.enable
          then 40 else 80;
        blocktime = 10 * 60;
        detection_time = 7 * 24 * 60 * 60;
        whitelist = [ "localhost" ];
      };
    };

    # The default is only 64, which is way too low for us
    systemd.sockets.sshd.socketConfig.MaxConnections = if cfg_rev_tun.relay.enable then 500 else 150;
  };
}
