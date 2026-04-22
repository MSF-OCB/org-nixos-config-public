{
  config,
  lib,
  pkgs,
  options,
  ...
}:

let
  cfg = config.settings.services.zabbixAgent;
  platform = if options ? system-manager then "none" else config.config.settings.hardwarePlatform;
  # Read JSON file and parse into an attrset
  servers = lib.importJSON ../org-config/json/zabbix-servers.json;
in

{

  options.settings.services.zabbixAgent = {
    enable = lib.mkEnableOption "The zabbixAgent service";
    internalHost = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Server on internal network";
    };
  };

  config = lib.mkIf cfg.enable {
    services.zabbixAgent = {
      enable = true;
      openFirewall = true;
      server = if cfg.internalHost then servers.internalZabbixHost else servers.externalZabbixHost;
      extraPackages = with pkgs; [
        lm_sensors
        gawk
      ];
      settings = {
        ServerActive = if cfg.internalHost then servers.internalZabbixHost else servers.externalZabbixHost;
        Hostname = config.networking.hostName;
      }
      // lib.optionalAttrs (platform == "nuc") {
        UnsafeUserParameters = 1;
        UserParameter = "basicCPUTemp.max,sensors | grep Core | awk -F'[:+°]' '{avg+=$3}END{print avg/NR}'";

      };
    };
  };
}
