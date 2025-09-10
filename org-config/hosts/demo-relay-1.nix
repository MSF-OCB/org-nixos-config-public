{
  time.timeZone = "Europe/Brussels";

  settings = {
    disko.diskDevice = "/dev/disk/by-path/pci-0000:03:00.0-scsi-0:0:0:0"; # Replace with actual disk device path
    system.isMbr = false;
    boot.mode = "uefi";
    vmware = {
      enable = true;
      inDMZ = true;
    };
    reverse_tunnel.relay.enable = true;
    network = {
      host_name = "demo-relay-1";
      static_ifaces.ens160 = {
        address = "192.168.50.5";
        prefix_length = 24;
        gateway = "192.168.50.1";
        fallback = false;
      };
    };
  };
}
# Note: Replace <disk device path>, <IP address>, and <gateway IP> with actual values for your setup.
# This configuration sets up a demo relay host with specific network and system settings.
# Ensure that the disk device path, IP address, and gateway IP are correctly specified for your environment.
# The time zone is set to Europe/Brussels, and the boot mode is configured for UEFI.
# The VMware settings indicate that this host is intended to run in a DMZ environment.
