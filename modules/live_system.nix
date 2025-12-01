{ config, lib, ... }:

{
  options.settings.live_system = {
    enable = lib.mkEnableOption "the module for live systems.";
  };

  config = lib.mkIf config.settings.live_system.enable {
    # The live disc overrides SSHd's wantedBy property to an empty value
    # with a priority of 50. We re-override it here.
    # See https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/installation-device.nix
    systemd.services.sshd.wantedBy = lib.mkOverride 10 [ "multi-user.target" ];

    settings = {
      system = {
        isISO = true;
        diskSwap.enable = false;
      };
      boot.mode = "none";
      maintenance.enable = false;
      reverse_tunnel.enable = true;
    };

    services = {
      # Turn off some unneeded services to save time
      htpdate.enable = lib.mkForce false;
      timesyncd.enable = lib.mkForce false;

      getty.helpLine = lib.mkForce "";
    };

    documentation = {
      enable = lib.mkOverride 10 false;
      nixos.enable = lib.mkOverride 10 false;
    };

    networking.wireless.enable = lib.mkOverride 10 false;

    system.extraDependencies = lib.mkOverride 10 [ ];
  };
}
