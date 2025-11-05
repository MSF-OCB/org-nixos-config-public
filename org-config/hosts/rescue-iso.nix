{ modulesPath
, config
, pkgs
, lib
, ...
}:

let
  sys_cfg = config.settings.system;
in
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    "${modulesPath}/installer/cd-dvd/channel.nix"
  ];

  time.timeZone = "Europe/Brussels";

  settings = {
    hardwarePlatform = config.settings.hardwarePlatforms.none;
    live_system.enable = true;
    network.host_name = "rescue-iso";
  };

  networking.networkmanager.enable = lib.mkForce false;

  services.openssh = {
    settings.PermitRootLogin = lib.mkForce "prohibit-password";
    authorizedKeysFiles = lib.mkForce [ "%h/.ssh/authorized_keys" ];
  };

  programs = {
    nix-index.enable = false;
  };

  systemd.services = {
    decrypt-secrets.enable = lib.mkForce false;
    extract-app-configs.enable = lib.mkForce false;
    copy-iso-key = {
      serviceConfig = {
        Type = "oneshot";
      };
      unitConfig = {
        RequiresMountsFor = [
          "/run"
          "/var/lib"
        ];
      };
      before = [ "copy-tunnel-key.service" ];
      wantedBy = [ "copy-tunnel-key.service" ];
      script = ''
        if [ -f "/iso/id_tunnel" ] && [ ! -f "${config.settings.system.private_key_source}" ]; then
          echo -n "Moving the ISO private key into the usual location..."
          mkdir --parent "$(dirname "${config.settings.system.private_key_source}")"
          cp "/iso/id_tunnel" "${config.settings.system.private_key_source}"
          echo " done"
        fi
      '';
    };
  };

  boot.supportedFilesystems = lib.mkOverride 10 [
    "vfat"
    "tmpfs"
    "auto"
    "squashfs"
    "tmpfs"
    "overlay"
  ];

  image = {
    fileName = lib.mkForce (
      (lib.concatStringsSep "-" [
        sys_cfg.org.iso.file_label
        config.isoImage.isoBaseName
        config.system.nixos.label
        pkgs.stdenv.hostPlatform.system
      ])
      + ".iso"
    );
  };
  isoImage.appendToMenuLabel = " ${sys_cfg.org.iso.menu_label}";
}
