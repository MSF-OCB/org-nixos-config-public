{ flakeInputs, config, ... }:
{
  imports = [
    flakeInputs.sops-nix.nixosModules.sops
  ];

  sops = {
    age.keyFile = "/var/lib/host-identity.key";
    defaultSopsFile = ../org-config/secrets/hosts/${config.networking.hostName}.yaml;
  };
}
