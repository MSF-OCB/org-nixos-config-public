{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.settings.users;

  userOpts = { name, config, ... }: {
    options = {
      name = mkOption {
        type = types.str;
      };

      enable = mkEnableOption "the user";

      sshAllowed = mkOption {
        type = types.bool;
        default = false;
      };

      extraGroups = mkOption {
        type = with types; listOf str;
        default = [ ];
      };

      hasShell = mkOption {
        type = types.bool;
        default = false;
      };

      canTunnel = mkOption {
        type = types.bool;
        default = false;
      };

      public_keys = mkOption {
        type = lib.types.listOf (lib.types.coercedTo
          lib.types.pub_key_type
          (publicKey: {
            inherit publicKey;
          })
          (lib.types.submodule (
            let
              userConfig = config;
            in
            { config, ... }: {
              options = {
                publicKey = lib.mkOption {
                  type = lib.types.pub_key_type;
                };
                keyOptions = lib.mkOption {
                  type = lib.types.listOf (lib.types.strMatching "[a-zA-Z=@.,\"-]*");
                  default = [ ];
                };
                finalKey = lib.mkOption {
                  type = lib.types.str;
                  default =
                    if config.keyOptions == [ ]
                    then "${config.publicKey} ${userConfig.name}"
                    else "${lib.concatStringsSep "," config.keyOptions} ${config.publicKey} ${userConfig.name}";
                };
              };
            }
          ))
        );
        default = [ ];
      };

      forceCommand = mkOption {
        type = with types; nullOr str;
        default = null;
      };

      whitelistCommands = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
      };
    };
    config = {
      name = mkDefault name;
    };
  };

in
{
  options = {
    settings.users = {
      users = mkOption {
        type = with types; attrsOf (submodule userOpts);
        default = { };
      };

      shell-user-group = mkOption {
        type = types.str;
        default = "shell-users";
        readOnly = true;
      };

      ssh-group = mkOption {
        type = types.str;
        default = "ssh-users";
        readOnly = true;
        description = ''
          Group to tag users who are allowed log in via SSH
          (either for shell or for tunnel access).
        '';
      };

      fwd-tunnel-group = mkOption {
        type = types.str;
        default = "ssh-fwd-tun-users";
        readOnly = true;
      };

      rev-tunnel-group = mkOption {
        type = types.str;
        default = "ssh-rev-tun-users";
        readOnly = true;
      };
    };
  };

  config =
    let
      public_keys_for = user: map (key: key.finalKey)
        user.public_keys;
    in
    {
      settings.users.users =
        let
          # Build an attrset of all public keys defined for tunnels that need to be
          # copied to users.
          # See settings.reverse_tunnel.tunnels.*.copy_key_to_user
          keysToCopy =
            let
              inherit (config.settings.reverse_tunnel) tunnels;

              # Convert a tunnel definition to a partial user definition with its pubkeys
              # We collect for every user the keys to be copied into a set
              # We cannot use a list directly since recursiveMerge only merges attrsets
              tunnelToUsers = t: map
                (u: {
                  ${u} = optionalAttrs (lib.stringNotEmpty t.public_key) {
                    public_keys = { ${t.public_key} = true; };
                  };
                })
                t.copy_key_to_users;

              tunnelsToUsers = lib.compose [
                # Convert the attrsets containing the keys into lists
                (mapAttrs (_: u: { public_keys = attrNames u.public_keys; }))
                # Merge all definitions together
                lib.recursiveMerge
                # Apply the function converting tunnel definitions to user definitions
                (concatMap tunnelToUsers)
                attrValues
              ];
            in
            tunnelsToUsers tunnels;
        in
        keysToCopy;

      users = {
        mutableUsers = false;

        # !! These lines are very important !!
        # Without it, the ssh groups are not created
        # and no-one has SSH access to the system!
        groups = {
          ${cfg.ssh-group} = {
            members = [
              config.users.users.root.name
            ];
          };
          ${cfg.fwd-tunnel-group} = { };
          ${cfg.rev-tunnel-group} = { };
          ${cfg.shell-user-group} = { };
        }
        //
        # Create a group per user
        lib.compose [
          (mapAttrs' (_: u: nameValuePair u.name { }))
          lib.filterEnabled
        ]
          cfg.users;

        users =
          let
            isRelay = config.settings.reverse_tunnel.relay.enable;

            hasForceCommand = user: user.forceCommand != null;

            hasShell = user: user.hasShell || (hasForceCommand user && isRelay);

            mkUser = _: user: {
              inherit (user) name;
              isNormalUser = user.hasShell;
              isSystemUser = ! user.hasShell;
              group = user.name;
              extraGroups = user.extraGroups ++
                (optional (user.sshAllowed || user.canTunnel) cfg.ssh-group) ++
                (optional user.canTunnel cfg.fwd-tunnel-group) ++
                (optional user.hasShell cfg.shell-user-group) ++
                (optional user.hasShell "users");
              shell = if (hasShell user) then config.users.defaultUserShell else pkgs.shadow;
              openssh.authorizedKeys.keys = public_keys_for user;
            };

            mkUsers = lib.compose [
              (mapAttrs mkUser)
              lib.filterEnabled
            ];
          in
          mkUsers cfg.users //
          # Allow users that are in the wheel to also log in as root.
          # This is needed for instance in order to (re-)install using nixos-anywhere.
          {
            root.openssh.authorizedKeys.keys =
              lib.flatten (
                lib.mapAttrsToList (_: user: map (key: key.finalKey) user.public_keys) (
                  lib.filterAttrs (_: user: lib.elem "wheel" user.extraGroups) config.settings.users.users
                )
              );
          };
      };

      settings.reverse_tunnel.relay.tunneller.keys =
        let
          mkKeys = lib.compose [
            # Filter out any duplicates
            lib.unique
            # Flatten this list of lists to get
            # a list containing all keys
            lib.flatten
            (lib.mapAttrsToList (_: user:
              map
                (publicKey: {
                  username = user.name;
                  inherit (publicKey) publicKey keyOptions;
                })
                user.public_keys
            ))
          ];
        in
        mkKeys cfg.users;

      # Use mkBefore to make sure that these rules are inserted before the
      # %wheel rule, as the last rule that matches in the sudoers file
      # is the one that gets applied. See man sudoers.
      security.sudo.extraRules = lib.mkBefore (
        let
          addDenyAll = cmds: [ "!ALL" ] ++ cmds;
          mkRule = username: cmds: {
            users = [ username ];
            runAs = "root";
            commands = map
              (command: {
                inherit command;
                options = [ "SETENV" "NOPASSWD" ];
              })
              (addDenyAll cmds);
          };
        in
        lib.compose [
          (lib.mapAttrsToList mkRule)
          (lib.filterAttrs (_: cmds: lib.length cmds > 0))
          # Avoid diffs in nix-diff because of the order in which commands were
          # added by sorting the commands for every user lexicographically
          (lib.mapAttrs (_: user: lib.naturalSort user.whitelistCommands))
        ]
          cfg.users
      );
    };
}
