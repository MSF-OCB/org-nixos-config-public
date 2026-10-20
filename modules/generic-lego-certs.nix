{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.settings.services.legoCerts;
  defaults = lib.importJSON ../org-config/json/lego-certs-defaults.json;

  mkLegoService =
    name: cert:
    let
      renewBeforeSeconds = cert.renewBeforeDays * 24 * 60 * 60;

      certFile = "${cfg.legoDirectory}/certificates/${cert.commonName}.crt";

      keyFile = "${cfg.legoDirectory}/certificates/${cert.commonName}.key";

      issuerFile = "${cfg.legoDirectory}/certificates/${cert.commonName}.issuer.crt";

      jsonFile = "${cfg.legoDirectory}/certificates/${cert.commonName}.json";

      domainArgs = lib.concatMapStringsSep " \\\n          " (
        domain: "--domains=${lib.escapeShellArg domain}"
      ) ([ cert.commonName ] ++ cert.sanDns);

    in
    {
      name = "lego-cert-${name}";

      value = {
        description = "Generate or renew Let's Encrypt certificate for ${cert.commonName}";

        wants = [
          "network-online.target"
        ];

        after = [
          "network-online.target"
        ];

        path = with pkgs; [
          bash
          coreutils
          gnugrep
          openssl
        ];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";

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

          DOMAIN=${lib.escapeShellArg cert.commonName}

          LEGO_CERT=${lib.escapeShellArg certFile}
          LEGO_KEY=${lib.escapeShellArg keyFile}
          LEGO_ISSUER=${lib.escapeShellArg issuerFile}
          LEGO_JSON=${lib.escapeShellArg jsonFile}

          echo "=========================================="
          echo "LEGO Certificate Service"
          echo "=========================================="
          echo "Certificate name: ${name}"
          echo "Domain:           $DOMAIN"
          echo "LEGO directory:   ${cfg.legoDirectory}"
          echo "=========================================="

          echo "=========================================="
          echo "Lego Version Check"
          echo "=========================================="

          LEGO_VERSION_OUTPUT="$(
            ${cfg.legoBinary} --version 2>&1 || true
          )"

          LEGO_VERSION="$(
            printf '%s\n' "$LEGO_VERSION_OUTPUT" |
              grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' |
              head -n1 ||
              true
          )"

          if [ -z "$LEGO_VERSION" ]; then
            echo "ERROR: Unable to determine LEGO version."
            echo
            echo "LEGO --version output:"
            echo "$LEGO_VERSION_OUTPUT"
            exit 1
          fi

          LEGO_MAJOR="''${LEGO_VERSION%%.*}"

          echo "Detected LEGO version: $LEGO_VERSION"
          echo "Detected LEGO major:   $LEGO_MAJOR"
          echo

          #
          # Only LEGO v4 and v5+ are currently supported.
          #
          if [ "$LEGO_MAJOR" -lt 4 ]; then
            echo "ERROR: Unsupported LEGO version: $LEGO_VERSION"
            echo "This service requires LEGO v4 or newer."
            exit 1
          fi

          echo "=========================================="
          echo "Ensure LEGO directories exist"
          echo "=========================================="

          mkdir -p ${lib.escapeShellArg cfg.legoDirectory}
          mkdir -p ${lib.escapeShellArg "${cfg.legoDirectory}/certificates"}


          echo "=========================================="
          echo "LEGO Certificate Generation/Renewal"
          echo "=========================================="
          echo

          if [ "$LEGO_MAJOR" -ge 5 ]; then

            echo "Using LEGO v5+ CLI."
            echo "LEGO will determine whether issuance or renewal is required."
            echo

            ${cfg.legoBinary} run \
              --accept-tos \
              --dns ${lib.escapeShellArg cfg.dnsProvider} \
              --dns.resolvers 1.1.1.1:53 \
              --dns.resolvers 8.8.8.8:53 \
              --email=${lib.escapeShellArg cfg.email} \
              --path=${lib.escapeShellArg cfg.legoDirectory} \
              ${domainArgs} \
              --renew-days=${toString cert.renewBeforeDays}

          else

            echo "Using LEGO v4 CLI."
            echo

            if [ ! -s "$LEGO_CERT" ]; then

              echo "No existing certificate found."
              echo "Issuing new certificate for $DOMAIN."
              echo

              ${cfg.legoBinary} \
                --accept-tos \
                --dns ${lib.escapeShellArg cfg.dnsProvider} \
                --dns.resolvers 1.1.1.1:53 \
                --dns.resolvers 8.8.8.8:53 \
                --email=${lib.escapeShellArg cfg.email} \
                --path=${lib.escapeShellArg cfg.legoDirectory} \
                ${domainArgs} \
                run

            else

              echo "Existing certificate found:"
              echo "$LEGO_CERT"
              echo

              if openssl x509 \
                -in "$LEGO_CERT" \
                -noout \
                -checkend ${toString renewBeforeSeconds}
              then

                echo "Certificate is valid for more than ${toString cert.renewBeforeDays} days."
                echo "No renewal required."
                echo

              else

                echo "Certificate expires within ${toString cert.renewBeforeDays} days."
                echo "Renewing certificate using LEGO v4."
                echo

                ${cfg.legoBinary} \
                  --accept-tos \
                  --dns ${lib.escapeShellArg cfg.dnsProvider} \
                  --dns.resolvers 1.1.1.1:53 \
                  --dns.resolvers 8.8.8.8:53 \
                  --email=${lib.escapeShellArg cfg.email} \
                  --path=${lib.escapeShellArg cfg.legoDirectory} \
                  ${domainArgs} \
                  renew

              fi
            fi
          fi

          echo "=========================================="
          echo "Validating certificate output..."
          echo "==========================================="
          echo

          for FILE in \
            "$LEGO_CERT" \
            "$LEGO_KEY" \
            "$LEGO_ISSUER"
          do

            if [ ! -s "$FILE" ]; then
              echo "ERROR: Expected LEGO output is missing or empty:"
              echo "$FILE"
              exit 1
            fi

          done

          if ! openssl x509 \
            -in "$LEGO_CERT" \
            -noout >/dev/null 2>&1
          then
            echo "ERROR: Unable to parse certificate:"
            echo "$LEGO_CERT"
            exit 1
          fi


          if ! openssl pkey \
            -in "$LEGO_KEY" \
            -noout >/dev/null 2>&1
          then
            echo "ERROR: Unable to parse private key:"
            echo "$LEGO_KEY"
            exit 1
          fi


          CERT_PUBLIC_KEY_HASH="$(
            openssl x509 \
              -in "$LEGO_CERT" \
              -pubkey \
              -noout |
            openssl pkey \
              -pubin \
              -outform DER 2>/dev/null |
            sha256sum |
            cut -d' ' -f1
          )"

          KEY_PUBLIC_KEY_HASH="$(
            openssl pkey \
              -in "$LEGO_KEY" \
              -pubout \
              -outform DER 2>/dev/null |
            sha256sum |
            cut -d' ' -f1
          )"

          echo "Certificate public-key hash: $CERT_PUBLIC_KEY_HASH"
          echo "Private key public-key hash: $KEY_PUBLIC_KEY_HASH"
          echo

          if [ -z "$CERT_PUBLIC_KEY_HASH" ] ||
             [ -z "$KEY_PUBLIC_KEY_HASH" ]
          then
            echo "ERROR: Unable to calculate public-key hashes."
            exit 1
          fi

          if [ "$CERT_PUBLIC_KEY_HASH" != "$KEY_PUBLIC_KEY_HASH" ]; then
            echo "ERROR: Certificate and private key do not match."
            exit 1
          fi

          echo "Certificate and private key match."
          echo

          echo "==========================================="
          echo "Setting file permissions..."
          echo "==========================================="

          chown root:root \
            "$LEGO_CERT" \
            "$LEGO_KEY" \
            "$LEGO_ISSUER"

          chmod 0644 "$LEGO_CERT"
          chmod 0644 "$LEGO_ISSUER"
          chmod 0600 "$LEGO_KEY"

          if [ -f "$LEGO_JSON" ]; then
            chown root:root "$LEGO_JSON"
            chmod 0600 "$LEGO_JSON"
          fi

          echo "==========================================="
          echo "Displaying final certificate information..."
          echo "==========================================="
          echo

          openssl x509 \
            -in "$LEGO_CERT" \
            -noout \
            -subject \
            -issuer \
            -dates \
            -ext subjectAltName

          echo
          echo "Certificate files:"
          echo "  Certificate: $LEGO_CERT"
          echo "  Private key: $LEGO_KEY"
          echo "  Issuer:      $LEGO_ISSUER"

          if [ -f "$LEGO_JSON" ]; then
            echo "  Metadata:    $LEGO_JSON"
          fi

          echo
          echo "LEGO certificate service completed successfully."
        '';
      };
    };

in
{
  options.settings.services.legoCerts = {

    enable = lib.mkEnableOption "Generic LEGO certificate generation and renewal";

    email = lib.mkOption {
      type = lib.types.str;
      default = "${defaults.email}";
    };

    legoBinary = lib.mkOption {
      type = lib.types.str;
      default = "${defaults.legoBinary}";
    };

    dnsProvider = lib.mkOption {
      type = lib.types.str;
      default = "route53";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      default = "${defaults.environmentFile}";
    };

    workingDirectory = lib.mkOption {
      type = lib.types.path;
      default = "${defaults.workingDirectory}";
    };

    legoDirectory = lib.mkOption {
      type = lib.types.path;
      default = "${defaults.legoDirectory}";
    };

    certs = lib.mkOption {
      default = { };

      description = ''
        Certificates managed by LEGO.
      '';

      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {

            commonName = lib.mkOption {
              type = lib.types.str;

              description = ''
                Primary DNS name for the certificate.
              '';
            };

            sanDns = lib.mkOption {
              type = lib.types.listOf lib.types.str;

              default = [ ];

              description = ''
                Additional DNS Subject Alternative Names
                included in the certificate.
              '';

              example = [
                "www.example.org"
                "files.example.org"
              ];
            };

            renewBeforeDays = lib.mkOption {
              type = lib.types.ints.positive;
              default = 30;
              description = ''
                Renewal threshold in days.
                If the certificate is valid for less than this number of days,
                it will be renewed.
              '';
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

    systemd.tmpfiles.rules = [
      "d ${cfg.legoDirectory} 0755 root root -"
      "d ${cfg.legoDirectory}/certificates 0755 root root -"
    ];

    systemd.services = lib.mapAttrs' mkLegoService cfg.certs;
  };
}
