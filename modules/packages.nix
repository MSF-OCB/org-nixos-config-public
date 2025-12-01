{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.settings.packages.python_package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.python3;
  };

  config.environment.systemPackages =
    with pkgs;
    (
      [
        acl
        dnsutils
        cryptsetup
        curl
        dmidecode
        file
        gptfdisk
        htop
        lsof
        mkpasswd
        psmisc
        rsync
        unzip
      ]
      ++ lib.optionals (!config.settings.system.isISO) [
        config.settings.packages.python_package
        cifs-utils
        ethtool
        nfs-utils
        nmap
        tcpdump
        tcptrack
        traceroute
        lm_sensors
        git
      ]
    );
}
