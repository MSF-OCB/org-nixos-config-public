{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.settings.services.autoBackup;

  copy_to_usb = pkgs.writeShellApplication {
    name = "orgnix_usb_auto_backup";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.util-linux
      pkgs.gnugrep
      pkgs.rsync
      pkgs.docker
    ];
    text = ''
      set -euo pipefail
      echo "Starting USB auto backup script..." | tee /dev/tty1 | systemd-cat

      dev="$1"
      if [ -z "$dev" ]; then
        echo "The USB device argument is missing - backup script cannot proceed." | tee /dev/tty1 | systemd-cat
        exit 5
      fi

      uuid="$(blkid -o value -s UUID "$dev" 2>/dev/null || true)"
      if [ -n "$uuid" ]; then
        safe_id="$uuid"
      else
        safe_id="$(basename "$dev")"
      fi

      mnt_point="/run/usb-mounts/$safe_id"
      secrets_file="${cfg.secretsFile}"
      marker_name="${cfg.markerName}"
      copy_dir="${cfg.copyDir}"
      destination_dir="${cfg.destinationDir}"

      container="${if cfg.dockerContainer == null then "" else cfg.dockerContainer}"
      backup_type="${cfg.backupType}"
      autorun_backup="${if cfg.autorun_backup then "true" else "false"}"

      state_dir="${cfg.stateDir}"
      cooldown_seconds="${toString cfg.cooldownSeconds}"
      eligible_for_rsync=false

      echo "Device: $dev, UUID: $uuid, Safe ID: $safe_id, Mount: $mnt_point, Secrets: $secrets_file, Marker: $marker_name, Copy Dir: $copy_dir, Destination Dir: $destination_dir, Autorun:  $autorun_backup, Cooldown: $cooldown_seconds seconds, Docker Container: $container, Backup Type: $backup_type" >&2

      # First check if secrets file exists before doing any mounts or other work
      if [ ! -f "$secrets_file" ]; then
        echo "Secrets file $secrets_file not found, exiting without copying." | tee /dev/tty1 | systemd-cat
        exit 10
      fi

      echo "Secrets File Used to Verify USB: $secrets_file is present in the system." | tee /dev/tty1 | systemd-cat

      mkdir -p "$mnt_point" "$state_dir"

      echo "Acquiring lock..." >&2

      # Prevent concurrent runs for the same or different USBs
      lock="$state_dir/lock"
      exec 9>"$lock"

      if ! flock -n 9; then
        echo "The backup script is already running for another device, exiting." | tee /dev/tty1 | systemd-cat
        exit 20
      fi

      cleanup() {
        if [ "$eligible_for_rsync" = true ]; then
          echo "Starting file copy to USB..." | tee /dev/tty1 | systemd-cat
          # Verified: remount rw and copy
          echo "Remounting $mnt_point as read-write..." >&2
          mount -o remount,rw "$mnt_point"
          echo "ensuring destination directory exists and copying files with rsync..." >&2
          mkdir -p "$mnt_point/$destination_dir"
          set -x
          rsync -r --delete --modify-window=1 --no-owner --no-group --no-perms "$copy_dir/" "$mnt_point/$destination_dir/"
          set +x
          sync
          echo "File copy completed successfully - Backup finished." | tee /dev/tty1 | systemd-cat
        fi

        # Attempt to unmount
        if mountpoint -q "$mnt_point"; then
          for _ in $(seq 1 10); do
            if umount "$mnt_point" 2>/dev/null; then
              break
            fi
            sleep 0.2
          done
        fi

        # Attempt to remove mount directory
        if [ -d "$mnt_point" ]; then
          for _ in $(seq 1 5); do
            if rmdir "$mnt_point" 2>/dev/null; then
              break
            fi
            sleep 0.1
          done
        fi
      }
      trap cleanup EXIT

      # Wait for device node to be ready
      for _ in $(seq 1 30); do
        [ -b "$dev" ] && break
        sleep 0.2
      done
      # Abort if device is still not ready
      if [ ! -b "$dev" ]; then
        echo "Backup Script cannot proceed - The USB $dev is not ready." | tee /dev/tty1 | systemd-cat
        exit 1
      fi

      echo "Mounting USB RO $dev to $mnt_point..." | tee /dev/tty1 | systemd-cat

      # Abort if mountpoint is already occupied
      if mountpoint -q "$mnt_point"; then
        echo "Backup Script cannot proceed - Mountpoint $mnt_point already has a filesystem mounted." | tee /dev/tty1 | systemd-cat
        exit 1
      fi

      # Mount read-only to verify marker
      mount -o ro "$dev" "$mnt_point"

      marker_file="$mnt_point/$marker_name"

      # if marker is missing, or mismatched -> exit
      if [ ! -f "$marker_file" ]; then
        echo "The Marker File that Authenticates the USB is missing, exiting without copying." | tee /dev/tty1 | systemd-cat
        exit 30
      fi

      echo "Marker File that Authenticates the USB is present in the USB, verifying contents..." | tee /dev/tty1 | systemd-cat
      usb_val="$(tr -d '\r\n' < "$marker_file")"
      exp_val="$(tr -d '\r\n' < "$secrets_file")"

      if [ "$usb_val" != "$exp_val" ]; then
        echo "The Marker File content does not match the expected value, exiting without copying." | tee /dev/tty1 | systemd-cat
        exit 40
      fi

      eligible_for_rsync=true

      echo "Marker verification successful, proceeding with backup..." | tee /dev/tty1 | systemd-cat

      # If autorun enabled, check cooldown and docker container before proceeding with executing backup
      if [ "$autorun_backup" = "true" ]; then
        if [ -z "$container" ]; then
          echo "Docker container not configured - cannot execute backup script" | tee /dev/tty1 | systemd-cat
          exit 50
        fi
        stamp="$state_dir/$safe_id.last_run"
        now="$(date +%s)"

        last=0
        if [ -f "$stamp" ]; then
          last="$(cat "$stamp" 2>/dev/null || echo 0)"
        fi
        if ! echo "$last" | grep -Eq '^[0-9]+$'; then
          last=0
        fi

        delta=$((now - last))
        if (( delta < cooldown_seconds )); then
          echo "Cooldown Period is Active - Please wait $((cooldown_seconds - delta)) seconds before inserting the USB again." | tee /dev/tty1 | systemd-cat
          exit 60
        fi

        if ! docker info >/dev/null 2>&1; then
          echo "Docker not available, cannot execute backup script" | tee /dev/tty1 | systemd-cat
          exit 70
        fi

        container_running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false)"
        if [ "$container_running" != "true" ]; then
          echo "Docker container $container is not running, cannot execute backup script" | tee /dev/tty1 | systemd-cat
          exit 80
        fi

        docker exec "$container" ./backup.sh "$backup_type"

        echo "Docker backup executed Successfully - Latest Backup is Available for Copying, proceeding to copy..." | tee /dev/tty1 | systemd-cat
      fi

      # Update stamp only in autorun mode
      if [ "$autorun_backup" = "true" ]; then
        echo "$now" > "$stamp"
      fi
    '';
  };
in
{
  options.settings.services.autoBackup = {
    enable = lib.mkEnableOption "the auto-backup service";

    markerName = lib.mkOption {
      type = lib.types.str;
      default = "secured";
      description = ''
        Marker filename to look for on the USB root.
        Its contents are compared with secretsFile to verify correct USB.
      '';
    };

    copyDir = lib.mkOption {
      type = lib.types.str;
      description = "Directory containing data to copy to the USB.";
    };

    destinationDir = lib.mkOption {
      type = lib.types.str;
      default = "exports";
      description = "Destination directory (relative to USB root) to copy into.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to secrets file on the machine used for verification (e.g. /run/.secrets/usb_backup).";
    };

    autorun_backup = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        If true, run docker backup before rsync and apply cooldown to both.
        If false, perform plain rsync on every insert (no cooldown).
      '';
    };

    cooldownSeconds = lib.mkOption {
      type = lib.types.int;
      default = 1800; # 30 minutes
      description = "Minimum number of seconds between runs per USB (autorun mode only).";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/opt/usb_auto_backup";
      description = "Directory on the NUC to store cooldown timestamps + lock.";
    };

    dockerContainer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Name of the running Backup container to exec into.";
    };

    backupType = lib.mkOption {
      type = lib.types.str;
      default = "L1";
      description = "Argument passed to ./backup.sh e.g 1S, L1, L2 etc";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(cfg.autorun_backup && cfg.dockerContainer == null);
        message = "autoBackup: dockerContainer must be set when autorun_backup = true";
      }
    ];
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_BUS}=="usb", TAG+="systemd", ENV{SYSTEMD_WANTS}="orgnix_usb_auto_backup@%k.service"
    '';

    systemd.services."orgnix_usb_auto_backup@" = {
      description = "Automatically back up data to a USB drive when plugged in (%I)";
      after = [ "docker.service" ];
      wants = [ "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${copy_to_usb}/bin/orgnix_usb_auto_backup /dev/%I";
      };
    };
  };
}
