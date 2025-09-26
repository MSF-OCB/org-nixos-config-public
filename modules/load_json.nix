{ config, lib, ... }:

{
  options.settings.users.available_permission_profiles = lib.mkOption {
    type = with lib.types; attrsOf anything;
    description = ''
      Attribute set of the permission profiles that can be defined through JSON.
    '';
  };

  config =
    let
      sys_cfg = config.settings.system;
      hostName = config.settings.network.host_name;

      pathToString = lib.concatStringsSep ".";

      get_tunnel_contents =
        let
          /*
            Note: if a json value is extracted multiple times, the warning only gets
            printed once per file.
            Since the value of the default expression does not depend on the input
            argument to the function, Nix memoizes the result of the trace call and
            the side-effect only occurs once.
          */
          get_tunnels_set =
            let
              tunnels_json_path = [ "tunnels" "per-host" ];
              warn_string = "ERROR: JSON structure does not contain the attribute " +
                pathToString tunnels_json_path;
            in
            lib.attrByPath tunnels_json_path (abort warn_string);

          get_json_contents = dir: lib.compose [
            (map lib.traceImportJSON)
            (lib.mapAttrsToList (name: _: dir + ("/" + name)))
            (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".json" name))
            builtins.readDir
          ]
            dir;
        in
        lib.compose [
          (map get_tunnels_set)
          get_json_contents
        ];

      tunnel_json = get_tunnel_contents sys_cfg.tunnels_json_dir_path;
    in
    {
      assertions =
        let
          mkDuplicates = lib.compose [
            lib.findDuplicates
            (lib.concatMap lib.attrNames) # map the JSON files to the server names
          ];
          duplicates = mkDuplicates tunnel_json;
        in
        [
          {
            assertion = lib.length duplicates == 0;
            message = "Duplicate entries found in the tunnel definitions. " +
              "Duplicates: " + lib.generators.toPretty { } duplicates;
          }
        ];

      settings = {
        users.users =
          let
            inherit (sys_cfg) users_json_path;
            users_json_data = lib.traceImportJSON users_json_path;
            inherit (sys_cfg) keys_json_path;
            keys_json_data = lib.traceImportJSON keys_json_path;

            hostPath = [ "users" "per-host" ];
            rolePath = [ "users" "roles" ];
            permissionProfiles = config.settings.users.available_permission_profiles;

            onRoleAbsent = path:
              let
                formatRoles = lib.compose [
                  (map (r: pathToString (rolePath ++ [ r ])))
                  lib.attrNames
                  (lib.attrByPath rolePath { })
                ];
              in
              abort (
                ''The role "${path}" which was '' +
                ''enabled for host "${hostName}", is not defined. '' +
                "Available roles: " +
                lib.generators.toPretty { } (formatRoles users_json_data)
              );

            onCycle = entriesSeen: abort (
              "Cycle detected while resolving roles: " +
              lib.generators.toPretty { } entriesSeen
            );

            onProfileNotFound = p: abort (
              ''Permission profile "${p}", mentioned in '' +
              ''file "${toString users_json_path}", '' +
              "could not be found. " +
              "Available profiles: \n" +
              lib.generators.toPretty { } (lib.attrNames permissionProfiles)
            );

            # Given an attrset mapping users to their permission profile,
            # resolve the permission profiles and activate the users
            # to obtain an attrset of activated users with the requested permissions.
            # This function return the attrset to be included in the final config.
            activateUsers =
              let
                enableProfile = p: p // { enable = true; };
                retrieveProfile = p:
                  if lib.hasAttr p permissionProfiles
                  then enableProfile permissionProfiles.${p}
                  else onProfileNotFound p;
              in
              lib.mapAttrs (_: retrieveProfile);

            # An 'entry' is either the top-level definition for a host in the
            # JSON file, or a role that has been enabled for that host and
            # therefore needs to be resolved.
            # If a host has roles enabled, we will recursively resolve each of
            # these roles and merge the results together.
            #
            # During role resolution, we maintain a set of the visited entries
            # to be able to detect and report any cycles during role resolution.
            # We also maintain a list of the visited entries since attribute sets
            # do not preserve insertion order and if there is a cycle, we want
            # to be able to print the cycle as part of the error message.

            # Initial empty set of entries to use for the top-level call.
            initEntriesSet = {
              # A set of entries that we have seen, allowing for efficient lookups.
              entriesSeenSet = { };
              # A list of entries that we have seen which keeps the order in
              # which we saw them, so that we can print them later in order.
              entriesSeenList = [ ];
            };

            # Add a new entry to the set, updating both the internal set and list.
            addEntryToSet = entryPathStr: { entriesSeenSet, entriesSeenList }:
              {
                entriesSeenSet =
                  entriesSeenSet // { ${entryPathStr} = true; };
                entriesSeenList =
                  entriesSeenList ++ [ entryPathStr ];
              };

            # Resolve an entry.
            # We resolve the users given in the 'enable' property and
            # we recurse into the roles given in the 'enable_roles' property.
            # The result is a mapping of every user to its permissions profile.
            resolveEntry = onEntryAbsent: entriesSeen: path: entry:
              let
                entryPath = path ++ [ entry ];
                entryPathStr = pathToString entryPath;
                entriesSeen' = addEntryToSet entryPathStr entriesSeen;
                entryData =
                  lib.attrByPath
                    entryPath
                    (onEntryAbsent entryPathStr)
                    users_json_data;

                direct = lib.attrByPath [ "enable" ] { } entryData;

                # We pass onRoleAbsent instead of onEntryAbsent in the recursive calls below,
                # this ensures that an error is thrown if we encounter a non-existing role.
                nested = resolveEntries onRoleAbsent entriesSeen' rolePath
                  (lib.attrByPath [ "enable_roles" ] [ ] entryData);

                # The property "enable_roles_with_profile" allows to enable a role but
                # to set the permission profile of all members of the role to a fixed
                # value.
                # We do mostly the same as for "enable_roles" above,
                # but before returning the result we replace the permission profile.
                nested_with_profile =
                  resolveEntriesWithProfiles onRoleAbsent entriesSeen' rolePath
                    (lib.attrByPath [ "enable_roles_with_profile" ] { } entryData);
              in
              if lib.hasAttr entryPathStr entriesSeen.entriesSeenSet
              then onCycle entriesSeen'.entriesSeenList
              else [ direct ] ++ nested ++ nested_with_profile;

            resolveEntries = onEntryAbsent: entriesSeen: path:
              lib.concatMap (resolveEntry onEntryAbsent entriesSeen path);

            # Resolve the given roles, after resolution we set the profile of
            # the resolved entries to a fixed specified one.
            resolveEntriesWithProfiles = _onEntryAbsent: entriesSeen: path:
              let
                doResolve = resolveEntry onRoleAbsent entriesSeen path;
                # Replace the profiles in the resolved role with the one
                # that was specified.
                replaceProfilesWith = profile: map (lib.mapAttrs (_: _: profile));
                # Resolve the given role and set the profiles in the result to
                # the given fixed profile.
                resolveWithProfile = role: profile:
                  replaceProfilesWith profile (doResolve role);
              in
              lib.concatMapAttrsToList resolveWithProfile;

            ensure_no_duplicates = attrsets:
              let
                duplicates = lib.findDuplicateMappings attrsets;
                msg = "Duplicate permission profiles found for users: " +
                  lib.generators.toPretty { } duplicates;
              in
              if lib.length (lib.attrNames duplicates) == 0
              then attrsets
              else abort msg;

            enabledUsersForHost =
              let
                # We do not abort if a host is not found,
                # in that case we simply do not activate any user for that host.
                onHostAbsent = lib.const { };
              in
              lib.compose [
                # Activate all users
                activateUsers
                # Merge everything together
                lib.recursiveMerge
                # Detect any users with multiple permissions
                ensure_no_duplicates
                # resolve the entry for the current server
                (resolveEntry onHostAbsent initEntriesSet hostPath)
              ];

            enabledUsers = enabledUsersForHost hostName;
          in
          # Take all enabled users and merge them with their public keys.
          lib.recursiveUpdate keys_json_data.keys enabledUsers;

        reverse_tunnel.tunnels =
          let
            # We add the SSH tunnel by default
            addSshTunnel = tunnel:
              let
                ssh_tunnel.reverse_tunnels.ssh = {
                  prefix = 0;
                  forwarded_port = 22;
                };
              in
              lib.recursiveUpdate tunnel ssh_tunnel;

            addSshTunnels = lib.mapAttrs (_: addSshTunnel);

            load_tunnel_files = lib.compose [
              addSshTunnels
              # We check in an assertion above that the two attrsets have an
              # empty intersection, so we do not need to worry about the order
              # in which we merge them here.
              lib.recursiveMerge
            ];
          in
          load_tunnel_files tunnel_json;
      };
    };
}
