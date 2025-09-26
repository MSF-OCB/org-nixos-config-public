{ flakeInputs, config, lib, ... }:
{
  imports = [
    flakeInputs.sops-nix.nixosModules.sops
  ];

  sops = {
    # TODO: generate and put that into place in install.sh
    age.keyFile = "/var/lib/host-identity.key";

    # Don't use the default SSH host key files for decryption
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];

    # Per host
    defaultSopsFile = ../org-config/secrets/hosts/${config.networking.hostName}.yaml;
  };
}
