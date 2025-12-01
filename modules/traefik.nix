{
  config,
  lib,
  pkgs,
  ...
}:

#
# **** NOTE
#
# When updating the Traefik config here, please also update the Traefik for Windows config files we have here:
#
# <https://github.com/MSF-OCB/traefik-windows>
#

let
  cfg = config.settings.services.traefik;

  # Formatter for YAML
  yaml_format = pkgs.formats.yaml { };
in

{

  options.settings.services.traefik =
    let
      tls_entrypoint_opts =
        { name, ... }:
        {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
            };

            enable = lib.mkEnableOption "the user";

            host = lib.mkOption {
              type = lib.types.str;
              default = "";
            };

            port = lib.mkOption {
              type = lib.types.port;
            };

          };
          config = {
            name = lib.mkDefault name;
          };
        };
    in
    {
      enable = lib.mkEnableOption "the Traefik service";

      version = lib.mkOption {
        type = lib.types.str;
        default = "3.3";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "traefik";
        readOnly = true;
      };
      encode_semicolons = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      # Enable the SMTP entrypoint, which is used for sending emails

      smqtt_enable = lib.mkEnableOption "SMQTT";

      smtp_enable = lib.mkEnableOption "SMTP";

      service_name = lib.mkOption {
        type = lib.types.str;
        default = "nixos-traefik";
        readOnly = true;
      };

      dynamic_config = lib.mkOption {
        type =
          with lib.types;
          attrsOf (submodule {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
              };
              value = lib.mkOption {
                inherit (yaml_format) type;
              };
            };
          });
      };

      tls_entrypoints = lib.mkOption {
        type = with lib.types; attrsOf (submodule tls_entrypoint_opts);
        default = { };
      };

      network_name = lib.mkOption {
        type = lib.types.str;
        default = "web";
      };

      logging_level = lib.mkOption {
        type = lib.types.enum [
          "INFO"
          "DEBUG"
          "TRACE"
        ];
        default = "INFO";
      };

      accesslog = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
      };

      traefik_entrypoint_port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
      };

      content_type_nosniff_enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      forceSameOrigin = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      acme = {
        caServer = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default =
            if cfg.acme.staging.enable then "http://acme-staging-v02.api.letsencrypt.org/directory" else null;
        };

        staging.enable = lib.mkEnableOption "the Let's Encrypt staging environment";

        keytype = lib.mkOption {
          type = lib.types.str;
          default = "EC256";
          readOnly = true;
        };

        storage = lib.mkOption {
          type = lib.types.str;
          default = "/letsencrypt";
          readOnly = true;
        };

        email_address = lib.mkOption {
          type = lib.types.str;
        };

        resolvers = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "9.9.9.9:53"
            "149.112.112.112:53"
          ];
        };

        delayBeforeChecks = lib.mkOption {
          type = lib.types.ints.positive;
          default = 60;
        };

        disableChecks = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };

        extraCaCertificateFiles = lib.mkOption {
          type = lib.types.listOf lib.types.path;
          default = [ ];
        };

        dnsProviders = lib.mkOption {
          type = with lib.types; attrsOf str;
          default = {
            azure = "azure";
            route53 = "route53";
            exec = "exec";
          };
          readOnly = true;
        };

        dnsProvider = lib.mkOption {
          type = lib.types.enum (lib.attrValues cfg.acme.dnsProviders);
        };
      };

      docker.swarm = {
        enable = lib.mkEnableOption "docker swarm support";
        endpoint = lib.mkOption {
          type = lib.types.str;
        };
      };

      extraEnvironmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };

      extraVolumes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };

  config =
    let
      security-headers = "security-headers";
      #extra-security-headers = "extra-security-headers";
      hsts-headers = "hsts-headers";
      compress-middleware = "compress-middleware";
      default-middleware = "default-middleware";
      default-ssl-middleware = "default-ssl-middleware";
      # https://github.com/traefik/traefik/issues/6636
      dashboard-middleware = "dashboard-middleware";
    in
    lib.mkIf cfg.enable {

      assertions = [
        {
          assertion = config.virtualisation.docker.enable;
          message = "The Traefik module requires Docker to be enabled";
        }
      ];

      settings = {

        services.traefik = {
          dynamic_config.default_config = {
            enable = true;
            value = {
              http = {
                routers.dashboard = {
                  entryPoints = [ "traefik" ];
                  rule = "PathPrefix(`/api`) || PathPrefix(`/dashboard`)";
                  service = "api@internal";
                };

                middlewares =
                  #let
                  #  content_type = optionalAttrs cfg.content_type_nosniff_enable {
                  #    contentTypeNosniff = true;
                  #  };
                  #in
                  {
                    ${default-ssl-middleware}.chain.middlewares = [
                      "${hsts-headers}@file"
                      "${default-middleware}@file"
                    ];
                    ${default-middleware}.chain.middlewares = [
                      "${security-headers}@file"
                      "${compress-middleware}@file"
                    ];
                    ${dashboard-middleware}.chain.middlewares = [
                      "${security-headers}@file"
                      "${compress-middleware}@file"
                    ];
                    ${security-headers}.headers = {
                      referrerPolicy = "no-referrer, strict-origin-when-cross-origin";
                      customFrameOptionsValue = if cfg.forceSameOrigin then "SAMEORIGIN" else null;
                      customResponseHeaders = {
                        Expect-CT = "max-age=${toString (24 * 60 * 60)}, enforce";
                        Server = "";
                        X-Generator = "";
                        X-Powered-By = "";
                        X-AspNet-Version = "";
                      };
                    };
                    #${extra-security-headers}.headers = content_type;
                    ${hsts-headers}.headers = {
                      stsPreload = true;
                      stsSeconds = toString (365 * 24 * 60 * 60);
                      stsIncludeSubdomains = true;
                    };
                    ${compress-middleware}.compress = { };
                  };
              };

              tls.options.default = {
                minVersion = "VersionTLS12";
                sniStrict = true;
                cipherSuites = [
                  # https://godoc.org/crypto/tls#pkg-constants
                  # TLS 1.2
                  "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
                  "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
                  "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
                  "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
                  # TLS 1.3
                  "TLS_AES_256_GCM_SHA384"
                  "TLS_CHACHA20_POLY1305_SHA256"
                ];
              };
            };
          };
        };
      };

      virtualisation.oci-containers = {
        backend = "docker";
        containers =
          let
            static_config_file_name = "traefik-static.yml";
            static_config_file_target = "/${static_config_file_name}";
            dynamic_config_directory_name = "traefik-dynamic.conf.d";
            dynamic_config_directory_target = "/${dynamic_config_directory_name}";

            static_config_file_source =
              let
                generate_tls_entrypoints = lib.compose [
                  (lib.mapAttrs (_: value: { address = "${value.host}:${toString value.port}"; }))
                  lib.filterEnabled
                ];
                letsencrypt = "letsencrypt";
                caserver = lib.optionalAttrs (cfg.acme.caServer != null) { inherit (cfg.acme) caServer; };
                acme_template = {
                  email = cfg.acme.email_address;
                  storage = "${cfg.acme.storage}/acme.json";
                  keyType = cfg.acme.keytype;
                  caCertificates = lib.optionals (lib.length cfg.acme.extraCaCertificateFiles > 0) (
                    map (f: "/etc/pki/tls/certs/${builtins.baseNameOf f}") cfg.acme.extraCaCertificateFiles
                  );
                }
                // caserver;
                accesslog = lib.optionalAttrs cfg.accesslog.enable {
                  accessLog = {
                    # Make sure that the times are printed in local time
                    # https://doc.traefik.io/traefik/observability/access-logs/#time-zones
                    fields = {
                      names.StartUTC = "drop";
                      headers.names.User-Agent = "keep";
                    };
                  };
                };
                static_config = {
                  global.sendAnonymousUsage = true;
                  ping = { };
                  log.level = cfg.logging_level;
                  api.dashboard = true;

                  providers = {
                    docker = {
                      network = cfg.network_name;
                      exposedbydefault = false;
                    };
                    file = {
                      watch = true;
                      directory = dynamic_config_directory_target;
                    };
                  }
                  // lib.optionalAttrs cfg.docker.swarm.enable {
                    swarm = {
                      inherit (cfg.docker.swarm) endpoint;
                    };
                  };

                  entryPoints = {
                    web = {
                      address = ":80";
                      http = {
                        redirections.entryPoint = {
                          to = "websecure";
                          scheme = "https";
                        };
                        middlewares = [ "${default-middleware}@file" ];
                      };
                    };
                    websecure = {
                      address = ":443";
                      http = {
                        encodeQuerySemicolons = cfg.encode_semicolons;
                        middlewares = [ "${default-ssl-middleware}@file" ];
                        tls.certResolver = letsencrypt;
                      };
                      http3 = { };
                    };
                    traefik = {
                      address = ":${toString cfg.traefik_entrypoint_port}";
                      http.middlewares = [ "${dashboard-middleware}@file" ];
                    };
                  }
                  // lib.optionalAttrs cfg.smtp_enable {
                    smtp = {
                      address = ":1025";
                    };
                  }
                  // lib.optionalAttrs cfg.smqtt_enable {
                    smqtt = {
                      address = ":8883";
                    };
                  }
                  // generate_tls_entrypoints cfg.tls_entrypoints;

                  certificatesresolvers = {
                    ${letsencrypt}.acme = acme_template // {
                      httpChallenge.entryPoint = "web";
                    };
                    "${letsencrypt}_dns".acme = acme_template // {
                      dnsChallenge = {
                        provider = cfg.acme.dnsProvider;
                        resolvers = lib.optionals (lib.length cfg.acme.resolvers > 0) cfg.acme.resolvers;
                        propagation = {
                          inherit (cfg.acme) disableChecks;
                          inherit (cfg.acme) delayBeforeChecks;
                        };
                      };
                    };
                  };
                }
                // accesslog;
              in
              yaml_format.generate static_config_file_name static_config;

            dynamic_config_mounts =
              let
                buildConfigFile =
                  key: configFile:
                  let
                    name = "${key}.yml";
                    file = yaml_format.generate name configFile.value;
                  in
                  "${file}:${dynamic_config_directory_target}/${name}:ro";
                buildConfigFiles = lib.mapAttrsToList buildConfigFile;
              in
              lib.compose [
                buildConfigFiles
                lib.filterEnabled
              ] cfg.dynamic_config;

          in
          {
            "${cfg.service_name}" = {
              image = "${cfg.image}:${cfg.version}";
              cmd = [
                "--configfile=${static_config_file_target}"
              ];
              ports =
                let
                  traefik_entrypoint_port_str = toString cfg.traefik_entrypoint_port;
                  mk_tls_port =
                    cfg:
                    let
                      port = toString cfg.port;
                    in
                    "${port}:${port}";
                  mk_tls_ports = lib.mapAttrsToList (_: mk_tls_port);
                in
                [
                  "80:80"
                  "443:443/tcp"
                  "443:443/udp"
                  "8883:8883/tcp"
                  "1025:1025/tcp"
                  "127.0.0.1:${traefik_entrypoint_port_str}:${traefik_entrypoint_port_str}"
                  "[::1]:${traefik_entrypoint_port_str}:${traefik_entrypoint_port_str}"
                ]
                ++ mk_tls_ports cfg.tls_entrypoints;
              volumes = [
                "/etc/localtime:/etc/localtime:ro"
                "/var/run/docker.sock:/var/run/docker.sock:ro"
                "${static_config_file_source}:${static_config_file_target}:ro"
                "traefik_letsencrypt:${cfg.acme.storage}"
              ]
              ++ cfg.extraVolumes
              ++ map (f: "${f}:/etc/pki/tls/certs/${builtins.baseNameOf f}:ro") cfg.acme.extraCaCertificateFiles
              ++ dynamic_config_mounts;
              workdir = "/";
              extraOptions = [
                # AWS route53 DNS zone credentials,
                # these can be loaded through an env file, see below
                "--env=AWS_ACCESS_KEY_ID"
                "--env=AWS_SECRET_ACCESS_KEY"
                "--env=AWS_HOSTED_ZONE_ID"
                "--env=AWS_REGION"

                # For tests, we use the exec DNS provider
                "--env=EXEC_PATH"
                "--env=EXEC_POLLING_INTERVAL"
                "--env=EXEC_PROPAGATION_TIMEOUT"
                "--env=EXEC_SEQUENCE_INTERVAL"

                "--network=${cfg.network_name}"
                "--tmpfs=/tmp:rw,nodev,nosuid,noexec"
                "--tmpfs=/run:rw,nodev,nosuid,noexec"
                "--health-cmd=traefik healthcheck --ping"
                "--health-interval=60s"
                "--health-retries=3"
                "--health-timeout=3s"
              ];
            };
          };
      };

      systemd.services =
        let
          docker = "${pkgs.docker}/bin/docker";
          systemctl = "${pkgs.systemd}/bin/systemctl";
          traefik_docker_service_name = "docker-${cfg.service_name}";
          traefik_docker_service = "${traefik_docker_service_name}.service";
        in
        {
          # We slightly adapt the generated service for Traefik
          "${traefik_docker_service_name}" = {
            # Requires needs to be accompanied by an After condition in order to be effective
            # See https://www.freedesktop.org/software/systemd/man/systemd.unit.html#Requires=
            requires = [ "docker.service" ];
            after = [ "docker.service" ];
            wantedBy = [ "docker.service" ];
            serviceConfig = {
              # The preceding "-" means that non-existing files will be ignored
              # See https://www.freedesktop.org/software/systemd/man/systemd.exec#EnvironmentFile=
              EnvironmentFile = map (f: "-${f}") cfg.extraEnvironmentFiles;
            };
            # Create the Traefik docker network in advance if it does not exist yet
            preStart = ''
              if [ -z $(${docker} network list --filter "name=^${cfg.network_name}$" --quiet) ]; then
                ${docker} network create ${cfg.network_name}
              fi
            '';
          };

          "${traefik_docker_service_name}-pull" = {
            inherit (cfg) enable;
            description = "Automatically pull the latest version of the Traefik image";
            serviceConfig = {
              Type = "oneshot";
            };
            script = ''
              ${docker} pull ${cfg.image}:${cfg.version}
              ${systemctl} try-restart ${traefik_docker_service}
              prev_images="$(${docker} image ls \
                --quiet \
                --filter 'reference=${cfg.image}' \
                --filter 'before=${cfg.image}:${cfg.version}')"
              if [ ! -z "''${prev_images}" ]; then
                ${docker} image rm ''${prev_images}
              fi
            '';
            startAt = "Wed 03:00";
          };
        };
    };
}
