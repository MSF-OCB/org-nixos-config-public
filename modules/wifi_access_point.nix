{
  config,
  lib,
  ...
}:
let
  cfg = config.settings.services.accessPoint;
in
{
  options.settings.services.accessPoint = {
    enable = lib.mkEnableOption "The accessPoint service";
    interface = lib.mkOption {
      type = lib.types.str;
      default = "wlp1s0";
      description = "The wireless interface to be used as access point.";
    };
    uplink_interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        List of uplink network interfaces to check for internet connectivity.
        If any of these interfaces is online, the access point services will not start
        (to avoid conflicts with fortigate-wifi).
      '';
    };

    network_range = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.12.2,192.168.12.254" ];
      description = "The IP range(s) for the access point network.";
    };
    ssid = lib.mkOption {
      type = lib.types.str;
      default = "NixOS-Access-Point";
      description = "The SSID of the access point.";
    };
    password_file = lib.mkOption {
      type = lib.types.str;
      default = null;
      description = "Path to a file containing the pre-shared key (password) for the access point. If set, this takes precedence over 'psk'.";
    };
    dns = lib.mkOption {
      default = "192.168.12.1";
      type = lib.types.str;
      description = "DNS address to advertise through DHCP";
      example = "192.168.12.1, 8.8.8.8, 1.1.1.1";
    };
    domain = lib.mkOption {
      default = null;
      type = lib.types.str;
      description = "Domain name to advertise through DHCP";
      example = "ocb.msf.org";
    };
    country_code = lib.mkOption {
      type = lib.types.str;
      description = "The country code for the access point (ISO 3166-1 alpha-2).";
    };

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (i: i != cfg.interface) cfg.uplink_interfaces;
        message = "uplink_interfaces must not include the access point interface (${cfg.interface})";
      }
    ];
    networking.wireless.enable = lib.mkForce false;
    networking.firewall = {
      allowedUDPPorts = [
        53
        67
      ];
      trustedInterfaces = [ "${cfg.interface}" ];
    };
    services.hostapd = {
      enable = true;
      radios."${cfg.interface}" = {
        band = "2g";
        channel = 6;
        countryCode = cfg.country_code;

        networks."${cfg.interface}" = {
          inherit (cfg) ssid;
          authentication = {
            mode = "wpa2-sha1";
            wpaPasswordFile = cfg.password_file;
          };
        };
      };
    };
    services.haveged.enable = true;
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    boot.kernelModules = [
      "iwlwifi"
      "iwlmvm"
      "mac80211"
      "cfg80211"
    ];
    services.dnsmasq = {
      enable = true;

      settings = {
        listen-address = [
          "127.0.0.1"
          cfg.dns
        ];
        bind-dynamic = true;
        inherit (cfg) domain;
        expand-hosts = true;
        dhcp-range = cfg.network_range;
        dhcp-option = [
          "option:router,${cfg.dns}"
          "option:dns-server,${cfg.dns}"
        ];
        address = [
        ];
        server = [
          "8.8.8.8"
          "1.1.1.1"
        ];
      };
    };

  };

}
