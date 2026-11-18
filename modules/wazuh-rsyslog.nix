{
  config,
  lib,
  ...
}:
let
  cfg = config.settings.services.wazuh-rsyslog;
in
{
  options = {
    settings.services.wazuh-rsyslog.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the Wazuh Rsyslog module.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Forwards journald logs to rsyslog
    # This configuration ensures that logs from systemd's journald are forwarded to rsyslog,
    # and that rsyslog writes them to /var/log/wazuh-host.log.
    # This file can be mounted into a container or accessed directly on the host.
    # Audit Logs also enabled and set to the wazuh agent
    services.journald.extraConfig = lib.mkAfter ''
      ForwardToSyslog=yes
    '';
    services.rsyslogd = {
      enable = true;
      extraConfig = ''
        *.* /var/log/wazuh-host.log
      '';
    };
    security.audit = {
      enable = true;
      backlogLimit = 8192;
      rules = [
        # Log denied file-open attempts from real logged-in users.
        "-a always,exit -F arch=b64 -S open,openat -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access_denied"
        "-a always,exit -F arch=b64 -S open,openat -F exit=-EPERM -F auid>=1000 -F auid!=4294967295 -k access_denied"
        # Critical identity/security configuration.
        "-w /etc/passwd -p wa -k identity"
        "-w /etc/group -p wa -k identity"
        "-w /etc/shadow -p wa -k identity"
        # Privilege escalation configuration.
        "-w /etc/sudoers -p wa -k sudoers_changes"
        # SSH configuration.
        "-w /etc/ssh/sshd_config -p wa -k sshd_config"
      ];
    };
    security.auditd = {
      enable = true;
      settings = {
        log_file = "/var/log/audit/audit.log";
        log_format = "RAW";
        # Flush periodically without forcing every event to disk immediately.
        flush = "INCREMENTAL_ASYNC";
        freq = 50;
        # Audit log rotation.
        max_log_file = 100;
        num_logs = 5;
        # Disk-space safeguards.
        space_left = 200;
        admin_space_left = 100;
        space_left_action = "SYSLOG";
        admin_space_left_action = "SUSPEND";
      };

    };
  };

}
