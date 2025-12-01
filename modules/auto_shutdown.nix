{ config, lib, ... }:

let
  cfg = config.settings.autoShutdown;
in
{
  options.settings.autoShutdown = {
    enable = lib.mkEnableOption "the auto-shutdown service";

    startAt = lib.mkOption {
      type = with lib.types; either str (listOf str);
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.auto_shutdown = {
      enable = true;
      description = "Automatically shut down the server at a fixed time.";
      serviceConfig.Type = "oneshot";
      script = ''
        /run/current-system/sw/bin/shutdown -h +5
      '';
      inherit (cfg) startAt;
    };
  };
}
