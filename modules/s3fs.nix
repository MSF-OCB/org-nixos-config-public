{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.s3fs;
in
{
  options.services.s3fs = {
    enable = mkEnableOption "Mounts s3 object storage using s3fs";
    keyPath = mkOption {
      type = types.str;
    };
    mountPath = mkOption {
      type = types.str;
    };
    bucket = mkOption {
      type = types.str;
    };
    url = mkOption {
      type = types.str;
    };
    region = mkOption {
      type = types.str;
    };
  };

  config = mkIf cfg.enable {
    systemd.services.s3fs = {
      description = "Object storage s3fs";
      wantedBy = [ "multi-user.target" ];
      after = [ "pre-application-setup.target" ];
      serviceConfig = {
        ExecStartPre = [
          "${pkgs.coreutils}/bin/chmod 600 ${cfg.keyPath}" # s3fs needs the key file to be only readable by the owner
          "${pkgs.coreutils}/bin/mkdir -m 777 -pv ${cfg.mountPath}" # create the mount dir with permissions for everyone to read/write (since s3fs will be running as root, but we want other users to be able to write to it)
          "${pkgs.e2fsprogs}/bin/chattr +i ${cfg.mountPath}" # stop files being written to unmounted dir
        ];
        ExecStart =
          let
            options = [
              "passwd_file=${cfg.keyPath}"
              "use_path_request_style"
              "allow_other"
              "url=${cfg.url}"
              "umask=0000"
              "endpoint=${cfg.region}"
            ];
          in
          "${pkgs.s3fs}/bin/s3fs ${cfg.bucket} ${cfg.mountPath} -f "
          + lib.concatMapStringsSep " " (opt: "-o ${opt}") options;
        ExecStopPost = "-${pkgs.fuse}/bin/fusermount -u ${cfg.mountPath}";
        KillMode = "process";
        Restart = "on-failure";
      };
    };
  };
}
