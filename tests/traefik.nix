# Test the traefik module by booting a machine running traefik and letting it proxy
# a simple webserver.
# We will do local ACME certificate generation, and validate the TLS chain from
# the client (the VM making the web request to traefik) to traefik.
#
# The test consists of the following VMs:
#   - traefik: the main machine running traefik
#   - client: the client making requests to traefik
#   - acme: the acme server handing out certificates, imported from nixpkgs
#   - dnsserver: the DNS server used to implement DNS-01 ACME challenges
#
# The ACME server is the stand-in for the Let's Encrypt ACME server in the real
# world (it runs Let's Encrypt Pebble server, which was explicitly designed for
# testing ACME).
# The dnsserver is the stand-in for our DNS provider in the real world (currently
# AWS route 53 and Azure DNS) and runs the Pebble challtestsrv DNS server.
# This DNS server initially responds to every request with the same A/AAAA record,
# and exposes an API to create new records (either TXT records for ACME validation
# or additional mappings from domain names to A/AAAA entries).

# TODO: remove the version override below once we have traefik version >= 3.2

let
  # Content served by the webserver. We test for it in the test script.
  testDocumentContent = "hello world";

  registerDnsModule =
    { domain }:
    {
      nodes,
      config,
      lib,
      pkgs,
      ...
    }:
    {
      systemd.services.register-dns = {
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          RemainAfterExit = true;
        };
        requiredBy = [
          config.systemd.targets.multi-user.name
        ];
        before = [
          config.systemd.targets.multi-user.name
        ];
        after = [
          "network-online.target"
        ];
        requires = [
          "network-online.target"
        ];
        script = ''
          ${lib.getExe pkgs.curl} \
            --no-progress-meter \
            --data '${
              builtins.toJSON {
                host = domain;
                addresses = [ config.networking.primaryIPAddress ];
              }
            }' \
            "http://[${nodes.dnsserver.networking.primaryIPv6Address}]:8055/add-a"

          ${lib.getExe pkgs.curl} \
            --no-progress-meter \
            --data '${
              builtins.toJSON {
                host = domain;
                addresses = [ config.networking.primaryIPv6Address ];
              }
            }' \
            "http://[${nodes.dnsserver.networking.primaryIPv6Address}]:8055/add-aaaa"
        '';
      };
    };
in

{
  name = "traefik";

  # Config shared by all nodes.
  defaults =
    { nodes, ... }:
    {
      networking = {
        # Use networkd, which also enables resolved, which makes network config easier
        useNetworkd = true;

        # Log blocked packets for easier debugging
        firewall = {
          logRefusedPackets = true;
          logRefusedConnections = true;
          logReversePathDrops = true;
        };

        # Use our DNS server for all nodes
        nameservers = [
          nodes.dnsserver.networking.primaryIPv6Address
        ];
      };

      systemd.network.wait-online = {
        ignoredInterfaces = [
          # Ignore the management interface
          "eth0"
        ];
      };
    };

  nodes = {
    acme =
      { config, modulesPath, ... }:
      {
        imports = [
          (modulesPath + "/../tests/common/acme/server")
          (registerDnsModule { domain = config.test-support.acme.caDomain; })
        ];
      };

    # A fake DNS server which can be configured with records as desired
    # Used to test DNS-01 challenge
    dnsserver =
      {
        pkgs,
        nodes,
        lib,
        ...
      }:
      {
        # Allow DNS requests and the management HTTP API
        networking.firewall = {
          allowedTCPPorts = [
            8055
            53
          ];
          allowedUDPPorts = [ 53 ];
        };

        # We don't want resolved to bind on port 53, since we need pebble there
        services.resolved.enable = lib.mkForce false;

        systemd.services.pebble-challtestsrv = {
          enable = true;
          description = "Pebble ACME challenge test server";
          wantedBy = [ "network.target" ];
          serviceConfig = {
            # By default, we respond to every A/AAAA query with the IP address of the traefik node
            ExecStart = "${lib.getExe' pkgs.pebble "pebble-challtestsrv"} -dns01 ':53' -defaultIPv6 '${nodes.traefik.networking.primaryIPv6Address}' -defaultIPv4 '${nodes.traefik.networking.primaryIPAddress}'";
            DynamicUser = true;
            # Required to bind on privileged ports.
            AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
          };
        };
      };

    traefik =
      {
        config,
        lib,
        nodes,
        pkgs,
        ...
      }:
      let
        traefikImage =
          version:
          pkgs.runCommandLocal "traefik-image.tar"
            {
              # Break the nix sandbox so that we can download the traefik docker image
              # from docker hub.
              # See https://zimbatm.com/notes/nix-packaging-the-heretic-way
              __noChroot = true;
            }
            ''
              ${lib.getExe pkgs.skopeo} copy \
                docker://docker.io/traefik:${version} \
                docker-archive:$out:traefik:${version}
            '';

        # This script will be executed by treafik (well, actually by lego, the acme
        # library used by treafik) when it does the ACME challenge.
        # It creates the TXT record containing the token obtained from the ACME
        # server, and cleans it up again once the validation is done.
        # In production we use the AWS Route53 DNS provider, but in this test we
        # use this simple exec provider instead.
        dnsScript =
          nodes:
          let
            dnsAddress = nodes.dnsserver.networking.primaryIPAddress;
          in
          pkgs.writeShellApplication {
            name = "dns-hook.sh";
            text = ''
              echo '[INFO]' "[$2]" 'dns-hook.sh' "$*"
              if [ "$1" = "present" ]; then
                ${lib.getExe pkgs.curl} --no-progress-meter --data '{"host": "'"$2"'", "value": "'"$3"'"}' "http://${dnsAddress}:8055/set-txt"
              else
                ${lib.getExe pkgs.curl} --no-progress-meter --data '{"host": "'"$2"'"}' "http://${dnsAddress}:8055/clear-txt"
              fi
            '';
          };
      in
      {
        imports = [
          ../modules/traefik.nix
        ];

        virtualisation.docker = {
          enable = true;
          enableOnBoot = true;
        };

        settings.services.traefik = {
          enable = true;
          logging_level = "DEBUG";
          acme = {
            email_address = "foo@bar.xyz";
            # See above, we use the exec provider to set the DNS TXT record for validation
            dnsProvider = config.settings.services.traefik.acme.dnsProviders.exec;
            caServer = "https://${nodes.acme.test-support.acme.caDomain}/dir";
            # This is not used currently since we turned off the propagation check below
            resolvers = [
              nodes.dnsserver.networking.primaryIPAddress
            ];
            # Add the CA certificate that signed the ACME servers's TLS certificate
            extraCaCertificateFiles = [
              nodes.acme.test-support.acme.caCert
            ];
            delayBeforeChecks = 5;
            # It seems that lego does a SOA request as the first step in its
            # propagation check, but pebble-challtestsrv doesn't seem to respond
            # to SOA queries.
            disableChecks = true;
          };

          # See above, pass the script for the exec provider to traefik
          extraEnvironmentFiles = [
            "${pkgs.writeTextFile {
              name = "dns_provider_env_vars";
              text = ''
                EXEC_PATH="${lib.getExe (dnsScript nodes)}"
              '';
            }}"
          ];

          extraVolumes = [
            # We mount the nix store in the traefik container so that the script
            # set in EXEC_PATH can be found.
            "/nix/store:/nix/store:ro"
          ];

          # Configure a router that proxies requests to the webserver machine
          dynamic_config = {
            traefik-dns = {
              value =
                let
                  traefik-dns-service = "traefik-dns-service";
                in
                {
                  http = {
                    routers = {
                      traefik-dns = {
                        entrypoints = [ "websecure" ];
                        rule = "Host(`traefik-dns.example.test`)";
                        service = traefik-dns-service;
                        tls.certresolver = "letsencrypt_dns";
                      };
                    };
                    services = {
                      ${traefik-dns-service}.loadBalancer.servers = [
                        { url = "http://foo.acme.test"; }
                      ];
                    };
                  };
                };
            };
          };
        };

        # Service to import the downloaded docker image for traefik
        systemd.services.load-traefik-image = {
          after = [ config.systemd.services.docker.name ];
          wants = [ config.systemd.services.docker.name ];

          wantedBy = [ config.systemd.services.docker-nixos-traefik.name ];
          before = [ config.systemd.services.docker-nixos-traefik.name ];

          serviceConfig.Type = "oneshot";

          script = ''
            ${lib.getExe pkgs.docker} load < ${traefikImage config.settings.services.traefik.version}
          '';
        };
      };

    client =
      { nodes, ... }:
      {
        # We need to trust the acme CA certificate since in the test script we will
        # download the CA certificate that the generated certificates were signed with.
        security.pki.certificateFiles = [
          nodes.acme.test-support.acme.caCert
        ];
      };

    # Simple webserver to have something that traefik can proxy to
    webserver =
      { pkgs, ... }:
      let
        documentRoot = pkgs.runCommandLocal "docroot" { } ''
          mkdir -p "$out"
          echo "${testDocumentContent}" > "$out/index.html"
        '';
      in
      {
        imports = [
          (registerDnsModule { domain = "foo.acme.test"; })
        ];
        networking.firewall.allowedTCPPorts = [ 80 ];

        # Set log level to info so that we can see when the service is reloaded
        services.nginx = {
          logError = "stderr info";
          enable = true;
          virtualHosts."foo.acme.test" = {
            default = true;
            locations."/".root = documentRoot;
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
              }
              {
                addr = "[::]";
                port = 80;
              }
            ];
          };
        };
      };
  };

  testScript =
    { nodes, ... }:
    # python
    ''
      dnsserver.start()
      with subtest("the DNS server is up"):
          dnsserver.wait_for_unit("multi-user.target")
          dnsserver.wait_for_unit("pebble-challtestsrv.service")
          dnsserver.wait_for_open_port(53)
          dnsserver.wait_for_open_port(8055)

      with subtest("all other auxiliary servers ar up"):
          # Don't start traefik yet, it needs the DNS records to be in place
          acme.start()
          webserver.start()
          client.start()

          acme.wait_for_unit("register-dns.service")
          webserver.wait_for_unit("register-dns.service")

          # We can start Traefik now, DNS should be populated
          start_all()

          acme.wait_for_unit("multi-user.target")
          webserver.wait_for_unit("multi-user.target")
          client.wait_for_unit("multi-user.target")

      with subtest("traefik started"):
          traefik.wait_for_unit("multi-user.target")
          traefik.wait_for_unit("docker-nixos-traefik.service")

          traefik.wait_for_open_port(80)
          traefik.wait_for_open_port(443)

      with subtest("HTTP is reachable"):
          client.wait_until_succeeds("curl -4 --fail --no-progress-meter -v http://traefik-dns.example.test")

      with subtest("obtain the root CA cert"):
          client.succeed("curl --fail --no-progress-meter -vL -o /tmp/root_ca.pem https://${nodes.acme.test-support.acme.caDomain}:15000/roots/0")

      with subtest("HTTPS works with a valid certificate"):
          out = client.wait_until_succeeds("curl -4 --cacert /tmp/root_ca.pem --fail --no-progress-meter -vL https://traefik-dns.example.test")

          assert out.rstrip() == "${testDocumentContent}", "the web server did not send the expected reply"
    '';
}
