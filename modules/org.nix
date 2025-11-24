{ config, lib, ... }:

let
  sys_cfg = config.settings.system;
  org_metadata = lib.importJSON ../org-config/json/org-metadata.json;
in

{
  options.settings.org = {
    static_ips = {
      hq_ips = lib.mkOption {
        type = with lib.types; listOf str;
        default = org_metadata.hq_outgoing_ips;
        readOnly = true;
        description = ''
          The fixed outgoing IP addresses of the HQ in Brussels.
        '';
      };
    };
  };

  config = {
    settings = {
      system = {
        org = {
          # This value has an impact on global environment variables,
          # be sure that you know what you are doing before changing it!!
          inherit (org_metadata) env_var_prefix;
          inherit (org_metadata) github_org;
          inherit (org_metadata) iso;
        };
        users_json_path = ../org-config/json/users.json;
        tunnels_json_dir_path = ../org-config/json/tunnels.d;
        keys_json_path = ../org-config/json/keys.json;
        secrets = {
          dest_directory = "/run/.secrets/";
          old_dest_directories = [ "/opt/.secrets" ];
          src_directory = ../org-config/secrets/generated;
        };
        app_configs = {
          dest_directory = "/run/.app_configs/";
          src_directory = ../org-config/app_configs/generated;
        };
      };

      crypto.defaultKeyFile = "${sys_cfg.secrets.dest_directory}/keyfile";

      maintenance.config_repo = {
        url = sys_cfg.org.repo_to_url org_metadata.config_repo;
        branch =
          let
            waves_and_staging_hosts = import ../org-config/waves-and-staging-hosts.nix;
            inherit (waves_and_staging_hosts) stagingHosts;
          in
          lib.mkDefault (
            if lib.elem config.settings.network.host_name stagingHosts then "staging" else "main"
          );
      };

      reverse_tunnel =
        let
          relay_jsondata = lib.importJSON ../org-config/json/relay-servers.json;
          addPublicKey = _name: server: server // { inherit (relay_jsondata) public_key; };
          relay_servers = lib.mapAttrs addPublicKey relay_jsondata.relay_servers;
        in
        {
          inherit relay_servers;
        };

      services.traefik = {
        acme = {
          email_address = org_metadata.acme_email_address;
          dnsProvider = config.settings.services.traefik.acme.dnsProviders.route53;
        };
      };
    };
  };
}
