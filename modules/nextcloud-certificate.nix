{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.settings.services.nextcloudCertificate;

  legoCertDir = "${cfg.workingDirectory}/certificates";

  certFile = "${legoCertDir}/${cfg.domain}.crt";

  keyFile = "${legoCertDir}/${cfg.domain}.key";

  issuerFile = "${legoCertDir}/${cfg.domain}.issuer.crt";

  stagingDir = "/var/snap/nextcloud/common/custom-cert";

in
{
  options.settings.services.nextcloudCertificate = {

    enable = lib.mkEnableOption "Nextcloud certificate deployment";

    certificateName = lib.mkOption {
      type = lib.types.str;
    };

    domain = lib.mkOption {
      type = lib.types.str;
    };

    workingDirectory = lib.mkOption {
      type = lib.types.str;
    };

    enableHSTS = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {

    systemd.tmpfiles.rules = [
      "d ${stagingDir} 0755 root root -"
    ];

    systemd.services.nextcloud-certificate = {

      description = "Install LEGO certificate into Nextcloud";
      # Call Generic LEGO Certs service to ensure the certificate is generated
      # before attempting to install it into Nextcloud.
      requires = [
        "lego-cert-${cfg.certificateName}.service"
      ];

      after = [
        "lego-cert-${cfg.certificateName}.service"
      ];

      path = with pkgs; [
        coreutils
      ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };

      script = ''
        set -euo pipefail

        CERT="${certFile}"
        KEY="${keyFile}"
        CHAIN="${issuerFile}"

        TARGET_CERT="${stagingDir}/cert.pem"
        TARGET_KEY="${stagingDir}/privkey.pem"
        TARGET_CHAIN="${stagingDir}/chain.pem"

        echo "==========================================="
        echo "Copying certificates for ${cfg.domain}"
        echo "==========================================="
        echo

        install \
          -m 0644 \
          -o root \
          -g root \
          "$CERT" \
          "$TARGET_CERT"

        install \
          -m 0600 \
          -o root \
          -g root \
          "$KEY" \
          "$TARGET_KEY"

        install \
          -m 0644 \
          -o root \
          -g root \
          "$CHAIN" \
          "$TARGET_CHAIN"

        echo "============================================"
        echo "Installing certificate into Nextcloud"
        echo "============================================"
        echo

        ${lib.optionalString cfg.enableHSTS ''
          /snap/bin/nextcloud.enable-https custom -s \
            "$TARGET_CERT" \
            "$TARGET_KEY" \
            "$TARGET_CHAIN"
        ''}

        ${lib.optionalString (!cfg.enableHSTS) ''
          /snap/bin/nextcloud.enable-https custom \
            "$TARGET_CERT" \
            "$TARGET_KEY" \
            "$TARGET_CHAIN"
        ''}

        echo "============================================"
        echo "Nextcloud certificate installed successfully."
        echo "============================================"
      '';
    };
  };
}
