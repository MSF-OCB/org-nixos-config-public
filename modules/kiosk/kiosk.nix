{
  config,
  lib,
  pkgs,
  flakeInputs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.services.kiosk;

  refreshScript = pkgs.writeShellScript "kiosk-refresh" ''
    export DISPLAY=:0
    export XAUTHORITY=/var/run/lightdm/root/:0
    ${pkgs.xdotool}/bin/xdotool search --onlyvisible --class "firefox" key ctrl+F5
  '';

  displayScript =
    action:
    pkgs.writeShellScript "kiosk-display-${action}" ''
      export DISPLAY=:0
      export XAUTHORITY=/var/run/lightdm/root/:0

      if [ "${action}" = "off" ]; then
        ${pkgs.xorg.xset}/bin/xset dpms force off
      else
        ${pkgs.xorg.xset}/bin/xset dpms force on
        ${pkgs.xorg.xset}/bin/xset s reset
        ${pkgs.xorg.xset}/bin/xset dpms 0 0 0
        ${pkgs.xorg.xset}/bin/xset -dpms
        ${pkgs.xorg.xset}/bin/xset s noblank
      fi
    '';
in
{
  options.services.kiosk = {
    enable = mkEnableOption "X11 kiosk mode";

    user = mkOption {
      type = types.str;
      default = "kiosk";
    };

    url = mkOption {
      type = types.str;
    };

    onTime = mkOption {
      type = types.str;
    };

    offTime = mkOption {
      type = types.str;
    };

    refreshFreq = mkOption {
      type = types.str;
      default = "30min";
    };

    firefox_relaunch_freq = mkOption {
      type = types.str;
      default = "3600";
    };

    videoDrivers = mkOption {
      type = types.listOf types.str;
      default = [ "modesetting" ];
    };

    monitorSection = mkOption {
      type = types.lines;
      default = ''
        Modeline "1920x720_60" 100.20 1920 2040 2072 2180 720 736 746 756
        Option "PreferredMode" "1920x720_60"
      '';
    };

    screenSection = mkOption {
      type = types.lines;
      default = ''
        DefaultDepth 24
        SubSection "Display"
          Depth 24
          Modes "1920x720_60"
        EndSubSection
      '';
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
    };
  };

  config = mkIf cfg.enable {

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "backup";

      extraSpecialArgs = {
        kioskSettings = {
          inherit (cfg) user;
          inherit (cfg) url;
          inherit (cfg) onTime;
          inherit (cfg) offTime;
          inherit (cfg) refreshFreq;
          inherit (cfg) firefox_relaunch_freq;
        };
      };

      users.${cfg.user} = import (flakeInputs.self + /modules/kiosk/kiosk_user.nix);
    };

    services.xserver = {
      enable = true;
      inherit (cfg) videoDrivers;

      displayManager.sessionCommands = ''
        ${pkgs.xorg.xset}/bin/xset s off
        ${pkgs.xorg.xset}/bin/xset dpms 0 0 0
        ${pkgs.xorg.xset}/bin/xset -dpms
        ${pkgs.xorg.xset}/bin/xset s noblank
      '';

      displayManager.lightdm = {
        enable = true;
        autoLogin = {
          enable = true;
          inherit (cfg) user;
        };
      };

      displayManager.defaultSession = "none+openbox";
      windowManager.openbox.enable = true;
      desktopManager.xterm.enable = false;

      libinput.enable = true;
      libinput.touchpad.disableWhileTyping = true;

      inherit (cfg) monitorSection;
      inherit (cfg) screenSection;
    };

    systemd.timers.kiosk-on = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onTime;
        Persistent = true;
      };
    };

    systemd.services.kiosk-on = {
      script = "${displayScript "on"}";
      serviceConfig.Type = "oneshot";
    };

    systemd.timers.kiosk-off = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.offTime;
        Persistent = true;
      };
    };

    systemd.services.kiosk-off = {
      script = "${displayScript "off"}";
      serviceConfig.Type = "oneshot";
    };

    systemd.timers.kiosk-refresh = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnUnitActiveSec = cfg.refreshFreq;
        OnBootSec = "5min";
      };
    };

    systemd.services.kiosk-refresh = {
      script = "${refreshScript}";
      serviceConfig.Type = "oneshot";
    };

    services.autorandr.enable = true;

    environment.systemPackages =
      with pkgs;
      [
        firefox
        openbox
        autorandr
        xorg.xrandr
        xorg.xset
        xorg.xsetroot
        xorg.xinit
        xdotool
        unclutter-xfixes
      ]
      ++ cfg.extraPackages;

    users.users.${cfg.user} = {
      isNormalUser = true;
      home = "/home/${cfg.user}";
      extraGroups = [
        "video"
        "audio"
      ];
    };

    boot.kernelParams = [
      "consoleblank=0"
      "quiet"
      "i915.enable_psr=0"
    ];
  };
}
