{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.settings.services.mccLegoCerts;
  defaults = lib.importJSON ../org-config/json/mcc-lego.json;
  renewBeforeSeconds = cfg.renewBeforeDays * 24 * 60 * 60;

  mkCertDefaults =
    name: cert:
    cert
    // {
      outputName = if cert.outputName == null then name else cert.outputName;
      legoCertificateName =
        if cert.legoCertificateName == null then cert.commonName else cert.legoCertificateName;
    };

  certs = lib.mapAttrs mkCertDefaults cfg.certs;

  mkGenerateCsrService = name: cert: {
    name = "mcc-generate-csr-${name}";
    value = {
      description = "Generate CSR for MCC certificate ${cert.commonName}";

      path = with pkgs; [
        bash
        coreutils
        findutils
        docker
      ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        WorkingDirectory = cfg.workingDirectory;
      };

      script = ''
        set -euo pipefail

        CSR_LINK="${cfg.certDirectory}/${cert.outputName}.csr"

        if [ -f "$CSR_LINK" ]; then
          echo "CSR already exists: $CSR_LINK"
          exit 0
        fi

        echo "Generating CSR for ${cert.commonName}"

        ${cfg.generateCsrScript} \
          -algo "${cert.keyAlgorithm}" \
          -keySizeOrCurve "${toString cert.keySizeOrCurve}" \
          -csrName "${cert.outputName}_certificate" \
          -subjectCommonName "${cert.commonName}" \
          -subjectCountry "${cert.country}" \
          -subjectOrg "${cert.organization}" \
          -sanDns "${lib.concatStringsSep "," cert.sanDns}"

        GENERATED_CSR="$(ls -1t ${cfg.certDirectory}/${cert.outputName}_certificate*.csr | head -n1)"

        if [ -z "$GENERATED_CSR" ]; then
          echo "CSR generation failed: no CSR found"
          exit 1
        fi

        ln -sfn "$GENERATED_CSR" "$CSR_LINK"

        echo "CSR created:"
        echo "$CSR_LINK -> $GENERATED_CSR"
      '';
    };
  };

  mkLegoService = name: cert: {
    name = "mcc-lego-renew-${name}";
    value = {
      description = "Issue or renew Let's Encrypt certificate for ${cert.commonName}";

      requires = [ "mcc-generate-csr-${name}.service" ];
      after = [
        "network-online.target"
        "mcc-generate-csr-${name}.service"
      ];
      wants = [ "network-online.target" ];

      path = with pkgs; [
        bash
        coreutils
        openssl
        docker
      ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        WorkingDirectory = cfg.workingDirectory;
        EnvironmentFile = cfg.environmentFile;
      };

      script = ''
        set -Eeuo pipefail

        trap '
          rc=$?
          echo "ERROR: Command failed at line $LINENO: $BASH_COMMAND (exit code $rc)" >&2
          exit "$rc"
        ' ERR

        LEGO_VERSION_OUTPUT="$(${cfg.legoBinary} --version 2>&1 || true)"

        LEGO_VERSION="$(
          printf '%s\n' "$LEGO_VERSION_OUTPUT" |
            grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' |
            head -n1 ||
            true
        )"

        if [ -z "$LEGO_VERSION" ]; then
          echo "ERROR: Unable to determine lego version."
          echo "lego --version output: $LEGO_VERSION_OUTPUT"
          exit 1
        fi

        LEGO_MAJOR="''${LEGO_VERSION%%.*}"

        CSR="${cfg.certDirectory}/${cert.outputName}.csr"
        LEGO_CERT="${cfg.legoDirectory}/certificates/${cert.legoCertificateName}.crt"
        LEGO_CERT_DIR="${cfg.legoDirectory}/certificates"

        CERT_EXISTS=false
        CERT_MATCHES_CSR=false

        echo "Using lego version: $LEGO_VERSION"
        echo "Using CSR: $CSR"
        echo "Expected certificate: $LEGO_CERT"

        if [ "$LEGO_MAJOR" -ge 5 ]; then
          echo "Checking lego v5 data migration status."

          mkdir -p "${cfg.legoDirectory}"

          V4_ACCOUNT_KEY="${cfg.legoDirectory}/accounts/acme-v02.api.letsencrypt.org/${cfg.email}/keys/${cfg.email}.key"
          V5_ACCOUNT_KEY="${cfg.legoDirectory}/accounts/acme-v02.api.letsencrypt.org/${cfg.email}/${cfg.email}.key"
          MIGRATION_MARKER="${cfg.legoDirectory}/.migrated-to-v5"

          if [ -f "$V5_ACCOUNT_KEY" ]; then
            echo "Lego account already uses the v5 layout."

            if [ ! -f "$MIGRATION_MARKER" ]; then
              touch "$MIGRATION_MARKER"

              echo "Created migration marker:"
              echo "$MIGRATION_MARKER"
            else
              echo "Lego directory already marked as migrated to v5."
            fi

          elif [ -f "$V4_ACCOUNT_KEY" ]; then
            BACKUP_DIRECTORY="${cfg.legoDirectory}.backup-before-v5-$(date +%Y%m%d%H%M%S)"

            echo "Backing up lego v4 data directory to:"
            echo "$BACKUP_DIRECTORY"

            cp -a \
              "${cfg.legoDirectory}" \
              "$BACKUP_DIRECTORY"

            echo "Migrating lego v4 data directory to v5..."

            yes | ${cfg.legoBinary} migrate \
              --path="${cfg.legoDirectory}"

            if [ ! -f "$V5_ACCOUNT_KEY" ]; then
              echo "ERROR: Migration completed but the v5 account key was not found:"
              echo "$V5_ACCOUNT_KEY"
              exit 1
            fi

            touch "$MIGRATION_MARKER"

            echo "Lego v5 migration completed successfully."
            echo "Created migration marker:"
            echo "$MIGRATION_MARKER"

          else
            echo "No existing lego v4 or v5 account key found for ${cfg.email}."
            echo "A fresh lego v5 account will be created when certificate issuance is required."

            if [ ! -f "$MIGRATION_MARKER" ]; then
              touch "$MIGRATION_MARKER"

              echo "Created migration marker:"
              echo "$MIGRATION_MARKER"
            fi
          fi
        fi

        if [ ! -f "$CSR" ]; then
          echo "ERROR: Missing CSR: $CSR"
          exit 1
        fi

        CSR_PUBLIC_KEY_HASH="$(
          openssl req \
            -in "$CSR" \
            -noout \
            -pubkey |
            openssl pkey \
              -pubin \
              -outform DER |
            openssl dgst -sha256
        )"

        echo "CSR public-key hash: $CSR_PUBLIC_KEY_HASH"

        if [ -f "$LEGO_CERT" ]; then
          CERT_EXISTS=true

          CERT_PUBLIC_KEY_HASH="$(
            openssl x509 \
              -in "$LEGO_CERT" \
              -noout \
              -pubkey |
            openssl pkey \
              -pubin \
              -outform DER |
            openssl dgst -sha256
          )"

          echo "Existing certificate public-key hash: $CERT_PUBLIC_KEY_HASH"

          if [ "$CSR_PUBLIC_KEY_HASH" = "$CERT_PUBLIC_KEY_HASH" ]; then
            CERT_MATCHES_CSR=true

            echo "Existing certificate matches the current CSR."

            if openssl x509 \
              -in "$LEGO_CERT" \
              -noout \
              -checkend "${toString renewBeforeSeconds}"
            then
              echo "Certificate for ${cert.commonName} is still valid for more than ${toString cfg.renewBeforeDays} days."
              exit 0
            fi

            echo "Certificate matches the current CSR but is expiring soon."
          else
            echo "Existing certificate does not match the current CSR."
            echo "Archiving old lego certificate files before issuing a new certificate."

            BACKUP_DIR="${cfg.legoDirectory}/certificate-backups/$(date +%Y%m%d-%H%M%S)"

            mkdir -p "$BACKUP_DIR"

            if [ -d "$LEGO_CERT_DIR" ]; then
              find "$LEGO_CERT_DIR" \
                -maxdepth 1 \
                -type f \
                -name '${cert.legoCertificateName}.*' \
                -exec mv -t "$BACKUP_DIR" {} +
            fi

            echo "Old certificate files moved to: $BACKUP_DIR"

            CERT_EXISTS=false
            CERT_MATCHES_CSR=false
          fi
        else
          echo "Certificate for ${cert.commonName} is missing."
        fi

        if [ "$LEGO_MAJOR" -ge 5 ]; then
          echo "Using lego v5 CLI"

          ${cfg.legoBinary} run \
            --accept-tos \
            --dns route53 \
            --dns.resolvers 1.1.1.1:53 \
            --dns.resolvers 8.8.8.8:53 \
            --csr="$CSR" \
            --email="${cfg.email}" \
            --path="${cfg.legoDirectory}" \
            --dns.propagation.wait="60s" \
            --renew-days="${toString cfg.renewBeforeDays}"
        else
          echo "Using lego v4 CLI"

          if [ "$CERT_EXISTS" = true ] && [ "$CERT_MATCHES_CSR" = true ]; then
            echo "Existing certificate matches the current CSR."
            echo "Renewing the certificate with lego v4."

            ${cfg.legoBinary} \
              --accept-tos \
              --dns route53 \
              --dns.resolvers 1.1.1.1:53 \
              --dns.resolvers 8.8.8.8:53 \
              --csr="$CSR" \
              --email="${cfg.email}" \
              --path="${cfg.legoDirectory}" \
              --dns.propagation-wait="60s" \
              renew
          else
            echo "No matching certificate exists."
            echo "Issuing a new certificate with lego v4."

            ${cfg.legoBinary} \
              --accept-tos \
              --dns route53 \
              --dns.resolvers 1.1.1.1:53 \
              --dns.resolvers 8.8.8.8:53 \
              --csr="$CSR" \
              --email="${cfg.email}" \
              --path="${cfg.legoDirectory}" \
              --dns.propagation-wait="60s" \
              run
          fi
        fi

        if [ ! -f "$LEGO_CERT" ]; then
          echo "ERROR: lego completed but the expected certificate was not created:"
          echo "$LEGO_CERT"

          echo "Certificate files currently present:"

          if [ -d "$LEGO_CERT_DIR" ]; then
            find "$LEGO_CERT_DIR" \
              -maxdepth 1 \
              -type f \
              -print
          fi

          exit 1
        fi

        ISSUED_CERT_PUBLIC_KEY_HASH="$(
          openssl x509 \
            -in "$LEGO_CERT" \
            -noout \
            -pubkey |
          openssl pkey \
            -pubin \
            -outform DER |
          openssl dgst -sha256
        )"

        echo "CSR public-key hash:                $CSR_PUBLIC_KEY_HASH"
        echo "Issued certificate public-key hash: $ISSUED_CERT_PUBLIC_KEY_HASH"

        if [ "$CSR_PUBLIC_KEY_HASH" != "$ISSUED_CERT_PUBLIC_KEY_HASH" ]; then
          echo "ERROR: Issued certificate does not match the current CSR."
          exit 1
        fi

        echo "Certificate successfully issued or renewed and verified against the current CSR."
      '';
    };
  };

  mkImportService = name: cert: {
    name = "mcc-import-cert-${name}";
    value = {
      description = "Import MCC certificate ${cert.commonName}";

      requires = [ "mcc-lego-renew-${name}.service" ];
      after = [ "mcc-lego-renew-${name}.service" ];

      path = with pkgs; [
        bash
        coreutils
        openssl
        docker
      ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        WorkingDirectory = cfg.workingDirectory;
      };

      script = ''
        set -euo pipefail

        LEGO_CERT="${cfg.legoDirectory}/certificates/${cert.legoCertificateName}.crt"
        TARGET_CERT="${cfg.certDirectory}/${cert.outputName}.crt"

        if [ ! -f "$LEGO_CERT" ]; then
          echo "Missing lego certificate: $LEGO_CERT"
          exit 1
        fi

        cp "$LEGO_CERT" "$TARGET_CERT"
        chmod 0644 "$TARGET_CERT"
        ls -l "$TARGET_CERT"

        ${cfg.importCertScript} --certName "${cert.importName}"

        openssl x509 \
          -in "$TARGET_CERT" \
          -noout \
          -subject \
          -ext subjectAltName
      '';
    };
  };

  mkTimer = name: cert: {
    name = "mcc-import-cert-${name}";
    value = {
      description = "Scheduled MCC certificate renewal/import for ${cert.commonName}";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };
  };

in
{
  options.settings.services.mccLegoCerts = {
    enable = lib.mkEnableOption "MCC lego certificate automation";

    email = lib.mkOption {
      type = lib.types.str;
      default = "${defaults.email}";
    };

    legoBinary = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.lego}/bin/lego";
      defaultText = lib.literalExpression ''"''${pkgs.lego}/bin/lego"'';
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      default = "${defaults.environmentFile}";
    };

    workingDirectory = lib.mkOption {
      type = lib.types.path;
      default = "${defaults.workingDirectory}";
    };

    certDirectory = lib.mkOption {
      type = lib.types.path;
      default = "${defaults.certDirectory}";
    };

    legoDirectory = lib.mkOption {
      type = lib.types.path;
      default = "${defaults.legoDirectory}";
    };

    generateCsrScript = lib.mkOption {
      type = lib.types.path;
      default = "${defaults.generateCsrScript}";
    };

    importCertScript = lib.mkOption {
      type = lib.types.path;
      default = "${defaults.importCertScript}";
    };

    renewBeforeDays = lib.mkOption {
      type = lib.types.int;
      default = 30;
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "daily";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "1h";
    };

    certs = lib.mkOption {
      default = { };

      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            commonName = lib.mkOption {
              type = lib.types.str;
            };

            sanDns = lib.mkOption {
              type = lib.types.listOf lib.types.str;
            };

            country = lib.mkOption {
              type = lib.types.str;
            };

            organization = lib.mkOption {
              type = lib.types.str;
            };

            keyAlgorithm = lib.mkOption {
              type = lib.types.str;
              default = "RSA";
            };

            keySizeOrCurve = lib.mkOption {
              type = lib.types.int;
              default = 4096;
            };

            importName = lib.mkOption {
              type = lib.types.str;
            };

            outputName = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };

            legoCertificateName = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      lego
      openssl
    ];

    systemd.services =
      lib.mapAttrs' mkGenerateCsrService certs
      // lib.mapAttrs' mkLegoService certs
      // lib.mapAttrs' mkImportService certs;

    systemd.timers = lib.mapAttrs' mkTimer certs;
  };
}
