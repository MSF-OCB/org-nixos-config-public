let
  libOverlay =
    final: prev:

    let
      lib = final;

      # compose [ f g h ] x == f (g (h x))
      compose =
        let
          apply = f: x: f x;
        in
        lib.flip (lib.foldr apply);

      applyN = n: f: compose (lib.genList (lib.const f) n);

      applyTwice = applyN 2;

      filterEnabled = lib.filterAttrs (_: conf: conf.enable);

      # concatMapAttrsToList :: (String -> v -> [a]) -> AttrSet -> [a]
      concatMapAttrsToList =
        f:
        compose [
          lib.concatLists
          (lib.mapAttrsToList f)
        ];

      mapListToAttrs = f: as: lib.listToAttrs (map f as);

      mergeDisjoint =
        let
          merge =
            name: values:
            if lib.length values != 1 then
              throw "mergeDisjoint: got multiple values for attribute ${name}"
            else
              lib.head values;
        in
        lib.zipAttrsWith merge;

      /*
        Find duplicate elements in a list in O(n) time

        Example:
          findDuplicates [ 1 2 2 3 4 4 4 5 ]
          => [ 2 4 ]
      */
      findDuplicates =
        let
          /*
            Function to use with foldr
            Given an element and a set mapping elements (as Strings) to booleans,
            it will add the element to the set with a value of:
              - false if the element was not previously there, and
              - true  if the element had been added already
            The result after folding, is a set mapping duplicate elements to true.
          */
          updateDuplicatesSet =
            el: set:
            let
              is_duplicate = el: lib.hasAttr (toString el);
            in
            set // { ${toString el} = is_duplicate el set; };
        in
        compose [
          lib.attrNames # return the name only
          (lib.filterAttrs (lib.flip lib.const)) # filter on trueness of the value
          (lib.foldr updateDuplicatesSet { }) # fold to create the duplicates set
        ];

      /*
        Function to find duplicate mappings in a list of attrsets

        findDuplicateMappings [ { "foo" = 1; "bar" = 2; } { "foo" = 3; } ]
          -> { "foo" = [ 1 3 ] }
      */
      findDuplicateMappings =
        let
          # For every element seen, we add an entry to the set
          updateDuplicatesSet = el: set: set // { ${toString el} = true; };
        in
        compose [
          (lib.filterAttrs (_: v: lib.length v >= 2)) # filter on users having 2 or more profiles
          (lib.mapAttrs (_: lib.attrNames)) # collect just the different profile names
          (lib.foldAttrs updateDuplicatesSet { }) # collect the values for the different keys
        ];

      # Prepend a string with a given number of spaces
      # indentStr :: Int -> String -> String
      indentStr =
        n: str:
        let
          spacesN = compose [
            lib.concatStrings
            (lib.genList (lib.const " "))
          ];
        in
        (spacesN n) + str;

      traceImportJSON = compose [
        (lib.filterAttrsRecursive (k: _: k != "_comment"))
        lib.importJSON
        (lib.traceValFn (f: "Loading file ${toString f}..."))
      ];

      ifPathExists = path: lib.optional (builtins.pathExists path) path;

      # If the given option exists in the given path, then we return the option,
      # otherwise we return null.
      # This can be used to optionally set options:
      #   config.foo.bar = {
      #     ${keyIfExists config.foo.bar "baz"} = valueIfBazOptionExists;
      #   };
      keyIfExists = path: option: if lib.hasAttr option path then option else null;

      toHostPath = hostname: ./org-config/hosts/${hostname} + ".nix";

      # Recursively merge a list of attrsets
      recursiveMerge = lib.foldl lib.recursiveUpdate { };

      stringNotEmpty = s: lib.stringLength s != 0;

      nixosVersionOf = nixpkgs: lib.versions.majorMinor nixpkgs.lib.version;

      evalHost =
        defaultModules: flakeInputs:
        # The arguments below can be overridden by the hostOverrides argument
        {
          hostname,
          nixpkgs,
          extraModules ? [ ],
          extraSpecialArgs ? { },
          ...
        }:
        let
          traceInfo = compose [
            # Trace the actual nixpkgs version used,
            # since it may have been overridden by the hostOverrides
            (lib.trace "Evaluating using nixpkgs version ${lib.versions.majorMinor nixpkgs.lib.version}")
            (lib.trace "Evaluating config: ${hostname}")
          ];
        in
        traceInfo (
          nixpkgs.lib.nixosSystem {
            # The nixpkgs instance passed down here has potentially been overridden by the host override
            specialArgs = {
              inherit flakeInputs;
            }
            // extraSpecialArgs;
            modules = [
              (toHostPath hostname)
              {
                # Pass the set of all host names as a module input
                _module.args = { inherit allHosts; };
                # Set nixpkgs.pkgs to avoid creating new nixpkgs instances
                nixpkgs.pkgs = nixpkgs;
              }
            ]
            ++ defaultModules
            ++ extraModules;
          }
        );

      # Construct the set of nixos configs, adding the given additional host overrides
      mkNixosConfigurations =
        {
          hosts,
          defaultModules,
          flakeInputs,
          hostOverrides ? { },
        }:
        let
          # Generate an attrset containing one attribute per host
          evalHosts = lib.mapAttrs (
            hostname: args: evalHost defaultModules flakeInputs ({ inherit hostname; } // args)
          );

          # Merge in the set of overrides. We need to make sure that the hostOverrides
          # do not override what was passed in from the host-config, so we need
          # to merge values one level deep into the attrset.
          # If this logic becomes any more complex, we might be better off doing
          # a module system eval to take care of the merging.
          # We map over the set of hosts, and for every host we check if there is
          # a corresponding entry in the hostOverrides set.
          # If there is, then we zip both of them together with our merge function.
          hostDefinitions = lib.flip lib.mapAttrs hosts (
            hostname: config:
            let
              # We pass the original config as an argument to the override function
              # so that the overrides can use for instance the system that was
              # configured for the host in question.
              hostOverride = (hostOverrides.${hostname} or (lib.const { })) config;
            in
            lib.flip lib.zipAttrsWith [ config hostOverride ] (
              name: values:
              {
                # The value from hostOverrides always wins here, we cannot merge this
                nixpkgs = lib.last values;
                # The value from hostOverrides always wins here, we cannot merge this
                hostname = lib.last values;
                # The value from hostOverrides always wins here, we cannot merge this
                system = lib.last values;
                # We concatenate the two lists of extraModules
                extraModules = lib.concatLists values;
                # We recursively merge the specialArgs
                extraSpecialArgs = lib.recursiveMerge values;
              }
              .${name} or (throw "Unsupported attribute in hostOverrides: ${name}")
            )
          );
        in
        evalHosts hostDefinitions;

      allHosts = compose [
        (lib.mapAttrs' (
          name: _:
          let
            host = lib.removeSuffix ".nix" name;
          in
          lib.nameValuePair host host
        ))
        (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name))
        builtins.readDir
      ] ./org-config/hosts;

      # Slice a list up in equally-sized slices and return the requested one
      getSlice =
        {
          slice,
          sliceCount,
          list,
        }:
        let
          len = lib.length list;

          # Let's imagine a list of 10 elements, and 4 slices, in that case the slice_size is 10 / 4 = 2
          # and the modulo is 10 % 4 = 2. We thus need to add an additional element to the first
          # two slices, and not to the two following ones. The below formulas do exactly that:
          # 1: from 0 * 2 + min(0, 2) = 0, size 2 + 1 = 3 (because 0 <  2), so [0:3]  = [0, 1, 2]
          # 2: from 1 * 2 + min(1, 2) = 3, size 2 + 1 = 3 (because 1 <  2), so [3:6]  = [3, 4, 5]
          # 3: from 2 * 2 + min(2, 2) = 6, size 2 + 0 = 2 (because 2 >= 2), so [6:8]  = [6, 7]
          # 4: from 3 * 2 + min(3, 2) = 8, size 2 + 0 = 2 (because 3 >= 2), so [8:10] = [8, 9]
          sliceSize = len / sliceCount;
          modulo = len - (sliceSize * sliceCount);
          begin = slice * sliceSize + (lib.min slice modulo);
          size = sliceSize + (if (slice < modulo) then 1 else 0);
        in
        lib.sublist begin size list;

      runNixOSTest =
        flakeInputs: test:
        { pkgs }:
        let
          inherit (pkgs) lib;
          nixos-lib = import (pkgs.path + "/nixos/lib") { };
        in
        (nixos-lib.runTest {
          hostPkgs = pkgs;
          # optional to speed up to evaluation by skipping evaluating documentation
          defaults.documentation.enable = lib.mkDefault false;
          # This makes `self` available in the nixos configuration of our virtual machines.
          # This is useful for referencing modules or packages from your own flake as well as importing
          # from other flakes.
          node = {
            inherit pkgs;
            specialArgs = {
              flakeInputs = flakeInputs // {
                nixpkgs = pkgs;
              };
              inherit (pkgs) lib;
            };
          };
          imports = [ test ];
        }).config.result;

      types = mergeDisjoint [
        prev.types
        {
          /*
            A type for host names, host names consist of:
            * a first character which is an upper or lower case ascii character
            * followed by zero or more of: dash (-), upper case ascii, lower case ascii, digit
            * followed by an upper or lower case ascii character or a digit
          */
          host_name_type = lib.types.strMatching "^[[:upper:][:lower:]][-[:upper:][:lower:][:digit:]]*[[:upper:][:lower:][:digit:]]$";

          empty_str_type = lib.types.strMatching "^$" // {
            description = "empty string";
          };

          pub_key_type =
            let
              key_data_pattern = "[[:lower:][:upper:][:digit:]\\/+]";
              key_patterns =
                let
                  /*
                    These prefixes consist out of 3 null bytes followed by a byte giving
                    the length of the name of the key type, followed by the key type itself,
                    and all of this encoded as base64.
                    So "ssh-ed25519" is 11 characters long, which is \x0b, and thus we get
                      b64_encode(b"\x00\x00\x00\x0bssh-ed25519")
                    For "ecdsa-sha2-nistp256", we have 19 chars, or \x13, and we get
                      b64encode(b"\x00\x00\x00\x13ecdsa-sha2-nistp256")
                    For "ssh-rsa", we have 7 chars, or \x07, and we get
                      b64encode(b"\x00\x00\x00\x07ssh-rsa")
                    For SSH hardware keys, 30 chars
                      b64encode(b"\x00\x00\x00\x26sk-ssh-ed25519@openssh.com")
                  */
                  ed25519_prefix = "AAAAC3NzaC1lZDI1NTE5";
                  ed25519_hw_prefix = "AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29t";
                  nistp256_prefix = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY";
                  rsa_prefix = "AAAAB3NzaC1yc2E";
                in
                {
                  ssh-ed25519 = "^ssh-ed25519 ${ed25519_prefix}${key_data_pattern}{48}$";
                  ecdsa-sha2-nistp256 = "^ecdsa-sha2-nistp256 ${nistp256_prefix}${key_data_pattern}{108}=$";
                  # We require 2048 bits minimum. This limit might need to be increased
                  # at some point since 2048 bit RSA is not considered very secure anymore
                  ssh-rsa = "^ssh-rsa ${rsa_prefix}${key_data_pattern}{355,}={0,2}$";
                  ssh-ed25519-hw = "^sk-ssh-ed25519@openssh.com ${ed25519_hw_prefix}${key_data_pattern}{58,}={0,2}$";
                };
              pub_key_pattern = lib.concatStringsSep "|" (lib.attrValues key_patterns);
              description =
                ''valid ${lib.concatStringsSep " or " (lib.attrNames key_patterns)} key, ''
                + ''meaning a string matching the pattern ${pub_key_pattern}'';
            in
            lib.types.strMatching pub_key_pattern // { inherit description; };
        }
      ];

      exported = {
        inherit
          compose
          applyTwice
          filterEnabled
          mergeDisjoint
          concatMapAttrsToList
          stringNotEmpty
          mapListToAttrs
          findDuplicates
          findDuplicateMappings
          indentStr
          traceImportJSON
          ifPathExists
          keyIfExists
          nixosVersionOf
          toHostPath
          recursiveMerge
          allHosts
          mkNixosConfigurations
          getSlice
          runNixOSTest
          ;
      };

      # Check whether any newly introduced attribute shadows an existing one.
      # We can only use builtins here, otherwise we run into infinite recursion.
      duplicateAttributes =
        let
          prevAttrs = builtins.attrNames prev;
          exportedAttrs = builtins.attrNames exported;

          addIfDuplicate = dupl: el: if builtins.elem el exportedAttrs then dupl ++ [ el ] else dupl;
        in
        builtins.foldl' addIfDuplicate [ ] prevAttrs;
    in
    # We can only use builtins here, otherwise we run into infinite recursion.
    if builtins.length duplicateAttributes > 0 then
      throw "newly added attribute shadows an existing one: ${builtins.concatStringsSep ", " duplicateAttributes}"
    else
      exported // { inherit types; };
in
libOverlay
