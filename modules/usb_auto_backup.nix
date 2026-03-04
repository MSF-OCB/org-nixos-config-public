{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.settings.services.autoBackup;

  copy_to_usb = pkgs.writeShellScript "usb_auto_backup.sh" ''
    set -euo pipefail

    DEV="$1"
    if [ -z "$DEV" ]; then
      echo "missing device like /dev/sdb1" >&2
      exit 2
    fi

    UUID="$(${pkgs.util-linux}/bin/blkid -o value -s UUID "$DEV" 2>/dev/null || true)"
    if [ -n "$UUID" ]; then
      SAFE_ID="$UUID"
    else
      SAFE_ID="$(${pkgs.coreutils}/bin/basename "$DEV")"
    fi


    MNT="/run/usb-mounts/$SAFE_ID"
    SECRETS_FILE="${cfg.secretsFile}"
    MARKER_NAME="${cfg.markerName}"
    COPY_DIR="${cfg.copyDir}"
    DESTINATION_DIR="${cfg.destinationDir}"

    # First check if secrets file exists before doing any mounts or other work

    if [ ! -f "$SECRETS_FILE" ]; then
      exit 1
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$MNT"

    # Wait for device node to be ready
    for i in $(seq 1 30); do
      [ -b "$DEV" ] && break
      ${pkgs.coreutils}/bin/sleep 0.2
    done

    # Mount read-only first to verify marker before allowing writes
    if ! ${pkgs.util-linux}/bin/mountpoint -q "$MNT"; then
      ${pkgs.util-linux}/bin/mount -o ro "$DEV" "$MNT"
    fi

    MARKER="$MNT/$MARKER_NAME"

    # if marker is missing, or mismatch -> unmount and exit
    if [ ! -f "$MARKER" ]; then
      ${pkgs.util-linux}/bin/umount "$MNT" || true
      exit 0
    fi

    USB_VAL="$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$MARKER")"
    EXP_VAL="$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$SECRETS_FILE")"

    if [ "$USB_VAL" != "$EXP_VAL" ]; then
      ${pkgs.util-linux}/bin/umount "$MNT" || true
      exit 0
    fi

    # Verified: remount rw and copy
    ${pkgs.util-linux}/bin/mount -o remount,rw "$MNT"

    mkdir -p "$MNT/$DESTINATION_DIR"
    ${pkgs.rsync}/bin/rsync -r --delete --no-owner --no-group --no-perms "$COPY_DIR/" "$MNT/$DESTINATION_DIR/"

    ${pkgs.coreutils}/bin/sync
    ${pkgs.util-linux}/bin/umount "$MNT"
  '';
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
  };

  config = lib.mkIf cfg.enable {
    # Trigger on any USB partition add
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_BUS}=="usb", TAG+="systemd", ENV{SYSTEMD_WANTS}="usb_auto_backup@%k.service"
    '';

    systemd.services."usb_auto_backup@" = {
      description = "Automatically back up data to a USB drive when plugged in (%I)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${copy_to_usb} /dev/%I";
      };
    };
  };
}
