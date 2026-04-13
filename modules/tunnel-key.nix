{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  cfg = config.settings.system;
  tnl_cfg = config.settings.reverse_tunnel;
  isSystemManager = options ? system-manager;
in

{
  config = {
    assertions = [
      {
        assertion = lib.hasAttr config.networking.hostName tnl_cfg.tunnels;
        message =
          "This host's host name is not present in the tunnel config "
          + "(${toString cfg.tunnels_json_dir_path}).";
      }
    ];

    settings.reverse_tunnel = {
      privateTunnelKey = {
        path = config.settings.system.private_key;
        group = config.users.groups.private-key-access.name;
      };
      relay = {
        tunnel.extraGroups = [
          config.settings.users.ssh-group
          config.settings.users.rev-tunnel-group
        ];
        # The fwd-tunnel-group is required to be able to proxy through the relay
        tunneller.extraGroups = [
          config.settings.users.ssh-group
          config.settings.users.fwd-tunnel-group
        ];
      };
    };

    users.groups.private-key-access = { };

    systemd = {
      services =
        let
          legacy_key_path = "/etc/nixos/local/id_tunnel";
        in
        {
          tunnel-key-permissions = {
            enable = !cfg.isISO;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            unitConfig = {
              RequiresMountsFor = [
                "/run"
                "/var/lib"
              ];
            };
            script =
              let
                base_files = [
                  cfg.private_key_source
                  legacy_key_path
                ];
                files = lib.concatStringsSep " " (
                  lib.unique (
                    lib.concatMap (f: [
                      f
                      "${f}.pub"
                    ]) base_files
                  )
                );
              in
              ''
                for file in ${files}; do
                  if [ -f ''${file} ]; then
                    ${pkgs.coreutils}/bin/chown root:root ''${file}
                    ${pkgs.coreutils}/bin/chmod 0400 ''${file}
                  fi
                done
              '';
          };
          move-legacy-tunnel-key = lib.mkIf (!isSystemManager) {
            enable = !cfg.isISO;
            wants = [ "tunnel-key-permissions.service" ];
            after = [ "tunnel-key-permissions.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            unitConfig = {
              RequiresMountsFor = [
                "/run"
                "/var/lib"
              ];
            };
            script = ''
              if [ ! -f "${cfg.private_key_source}" ] && [ -f "${legacy_key_path}" ]; then
                echo -n "Moving the private key into the new location..."
                mkdir --parent "$(dirname "${cfg.private_key_source}")"
                cp "${legacy_key_path}" "${cfg.private_key_source}"
                # TODO: enable this line
                #rm --recursive --force /etc/nixos/
                echo " done"
              fi
            '';
          };
          copy-tunnel-key = {
            wants = [ "move-legacy-tunnel-key.service" ];
            after = [ "move-legacy-tunnel-key.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            unitConfig = {
              RequiresMountsFor = [
                "/run"
                "/var/lib"
              ];
            };
            script =
              let
                install =
                  {
                    source,
                    dest,
                    perms,
                  }:
                  ''
                    ${pkgs.coreutils}/bin/install \
                      -o ${config.users.users.root.name} \
                      -g ${config.users.groups.private-key-access.name} \
                      -m ${perms} \
                      "${source}" \
                      "${dest}"
                  '';
              in
              ''
                if [ -f "${cfg.private_key_source}" ]; then
                  ${install {
                    source = cfg.private_key_source;
                    dest = cfg.private_key;
                    perms = "440";
                  }}
                  ${install {
                    source = cfg.private_key_source;
                    dest = cfg.github_private_key;
                    perms = "400";
                  }}
                else
                  echo "No private key found, ignoring!"
                fi
              '';
          };
        };
      targets.tunnel-key-ready.wants = [ "copy-tunnel-key.service" ];
    };
  };
}
