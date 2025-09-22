{ config, pkgs, lib, ... }:

#with lib;

let
  cfg = config.settings.nfs;

  nfsCryptoMountOpts = { name, config, ... }: {
    options = {
      enable = lib.mkEnableOption "the crypto mount";

      name = lib.mkOption {
        type = lib.types.str;
      };

      device = lib.mkOption {
        type = lib.types.str;
      };

      exportTo = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
      };
    };

    config = {
      name = lib.mkDefault name;
    };
  };
in
{
  options.settings.nfs = {
    nfsPorts = lib.mkOption {
      type = with lib.types; listOf int;
      default = [ 111 2049 ];
      readOnly = true;
    };
    nfsUserId = lib.mkOption {
      type = lib.types.int;
      default = 20000;
      readOnly = true;
    };
    nfsExportOptions = lib.mkOption {
      type = lib.types.str;
      default = "rw,nohide,secure,no_subtree_check,all_squash,anonuid=${toString cfg.nfsUserId},anongid=65534";
      readOnly = true;
    };
    client = {
      enable = lib.mkEnableOption "the NFS client.";
    };
    server = {
      enable = lib.mkEnableOption "the NFS server.";

      cryptoMounts = lib.mkOption {
        type = with lib.types; attrsOf (submodule nfsCryptoMountOpts);
        default = { };
      };
    };
  };

  config =
    let
      exported_path = name: "/exports/${name}";

      mkNfsCryptoMount = _: conf: {
        enable = true;
        inherit (conf) device;
        mount_point = exported_path conf.name;
        mount_options = "acl,noatime,nosuid,nodev";
      };
      mkNfsCryptoMounts = lib.mapAttrs mkNfsCryptoMount;

      mkClientConf = client: "${client}(${cfg.nfsExportOptions})";
      mkExportEntry = _: conf: "${exported_path conf.name} ${lib.concatMapStringsSep " " mkClientConf conf.exportTo}";
      mkExports = confs: lib.concatStringsSep "\n" (lib.mapAttrsToList mkExportEntry confs);

      enabledCryptoMounts = lib.filterEnabled cfg.server.cryptoMounts;
    in
    lib.mkIf cfg.server.enable {
      users =
        let
          nfs = "nfs";
        in
        {
          extraUsers.${nfs} = {
            uid = cfg.nfsUserId;
            group = nfs;
            isNormalUser = false;
            isSystemUser = true;
            shell = pkgs.shadow;
          };

          groups.${nfs} = { };
        };
      settings.crypto.mounts = mkNfsCryptoMounts enabledCryptoMounts;
      services.nfs.server = {
        inherit (cfg.server) enable;
        exports = mkExports enabledCryptoMounts;
      };
      systemd.services.nfs-server = {
        after = [ "crypto-mounts-ready.target" ];
        wants = [ "crypto-mounts-ready.target" ];
      };
      networking.firewall = {
        allowedTCPPorts = cfg.nfsPorts;
        allowedUDPPorts = cfg.nfsPorts;
      };
    };
}
