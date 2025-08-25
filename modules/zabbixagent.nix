{ config, lib, pkgs, ... }:

let
  cfg = config.settings.services.zabbixAgent;
  platform = config.settings.hardwarePlatform;
  server1 = "infra-monitoring.brussels.msfocb";
  server2 = "infra-monitoring.ocb.msf.org";
in

{

  options.settings.services.zabbixAgent = {
    enable = lib.mkEnableOption "The zabbixAgent service";
    hqNuc = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Hq Zabbix Nuc";
    };
  };

  config = lib.mkIf cfg.enable {
    services.zabbixAgent = {
      enable = true;
      openFirewall = true;
      server = if cfg.hqNuc then server2 else server1;
      extraPackages = with pkgs; [ lm_sensors gawk ];
      settings = {
        ServerActive = if cfg.hqNuc then server2 else server1;
        Hostname = config.networking.hostName;
      } // lib.optionalAttrs (platform == "nuc") {
        UnsafeUserParameters = 1;
        UserParameter = "basicCPUTemp.max,sensors | grep Core | awk -F'[:+°]' '{avg+=$3}END{print avg/NR}'";

      };
    };
  };
}
