{ kioskSettings, ... }:

let
  inherit (kioskSettings) user;
  inherit (kioskSettings) url;
in
{
  home.username = user;
  home.homeDirectory = "/home/${user}";
  home.stateVersion = "25.11";

  home.file.".config/openbox/autostart" = {
    executable = true;
    text = ''
      #!/bin/bash
      exec > /home/${user}/autostart.log 2>&1

      echo "=== Autostart started at $(date) ==="

      xset s off
      xset s noblank
      xset dpms 0 0 0
      xset -dpms

      xsetroot -solid "#1a1a1a"
      unclutter -idle 5 -root &

      echo "=== Running autorandr ==="
      autorandr --change --default default
      echo "=== autorandr exit code: $? ==="

      echo "=== xrandr output ==="
      xrandr

      echo "=== Waiting for network ==="
      sleep 5
      echo "=== Network ready ==="

      xdotool mousemove 2000 1000

      while true; do
        echo "=== Launching Firefox at $(date) ==="
        firefox --kiosk "${url}" &
        FIREFOX_PID=$!
        echo "=== Firefox PID: $FIREFOX_PID ==="

        sleep ${kioskSettings.firefox_relaunch_freq}

        echo "=== Killing Firefox at $(date) ==="
        kill "$FIREFOX_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$FIREFOX_PID" 2>/dev/null || true
        pkill -f firefox 2>/dev/null || true
        sleep 3
        echo "=== Restarting Firefox at $(date) ==="
      done &
    '';
  };

  xdg.configFile."kiosk-settings.env".text = ''
    ON_TIME="${kioskSettings.onTime}"
    OFF_TIME="${kioskSettings.offTime}"
    REFRESH_FREQ="${kioskSettings.refreshFreq}"
    KIOSK_URL="${kioskSettings.url}"
    FIREFOX_REFRESH_FREQ=${kioskSettings.firefox_relaunch_freq};
  '';

  home.file.".config/openbox/rc.xml".text = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <openbox_config xmlns="http://openbox.org/3.4/rc">
      <focus>
        <focusNew>yes</focusNew>
        <followMouse>no</followMouse>
      </focus>
      <desktops>
        <number>1</number>
      </desktops>
      <margins>
        <top>0</top>
        <bottom>0</bottom>
        <left>0</left>
        <right>0</right>
      </margins>
      <applications>
        <application class="firefox" name="firefox">
          <decor>no</decor>
          <maximized>yes</maximized>
          <fullscreen>yes</fullscreen>
        </application>
      </applications>
    </openbox_config>
  '';
}
