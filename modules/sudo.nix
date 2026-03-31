{
  config,
  lib,
  ...
}:

let
  cfg = config.settings.users;
in

{
  config = {
    security.sudo = {
      enable = true;
      wheelNeedsPassword = false;

      # Use mkBefore to make sure that these rules are inserted before the
      # %wheel rule, as the last rule that matches in the sudoers file
      # is the one that gets applied. See man sudoers.
      extraRules = lib.mkBefore (
        let
          addDenyAll = cmds: [ "!ALL" ] ++ cmds;
          mkRule = username: cmds: {
            users = [ username ];
            runAs = "root";
            commands = map (command: {
              inherit command;
              options = [
                "SETENV"
                "NOPASSWD"
              ];
            }) (addDenyAll cmds);
          };
        in
        lib.compose [
          (lib.mapAttrsToList mkRule)
          (lib.filterAttrs (_: cmds: lib.length cmds > 0))
          # Avoid diffs in nix-diff because of the order in which commands were
          # added by sorting the commands for every user lexicographically
          (lib.mapAttrs (_: user: lib.naturalSort user.whitelistCommands))
        ] cfg.users
      );
    };
  };
}
