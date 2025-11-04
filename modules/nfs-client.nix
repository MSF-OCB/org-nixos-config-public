{ config, lib, ... }:

let
  cfg = config.nfs-client;
in
{

  options.nfs-client = {
    mounts = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf str);
      default = { };
      description = ''
        List of NFS mounts configurations.
        Example:
        mounts = {
          shareone = {
            what = "ip-address:/nfs-share";
            where = "/mount-point";
          };
          sharetwo = {
            what = "ip-address:/nfs-share";
            where = "/mount-point";
          };
        }
      '';
    };
  };


  config = {
    systemd = {
      mounts =
        let
          mkMount = name: mount: {
            enable = true;
            what = "${mount.what}";
            where = "${mount.where}";
            type = "nfs";
            options = "proto=tcp,auto,_netdev";
            wantedBy = [ "pre-application-setup.target" ];
            before = [ "pre-application-setup.target" ];
            after = [ "network.target" ];
          };
        in
        lib.mapAttrsToList mkMount cfg.mounts;
    };
  };

}

