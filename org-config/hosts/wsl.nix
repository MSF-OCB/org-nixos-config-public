{ config, flakeInputs, pkgs, ... }:
{

  imports = [
    flakeInputs.home-manager.nixosModules.home-manager
    flakeInputs.nixos-wsl.nixosModules.wsl
  ];

  time.timeZone = "Europe/Brussels";

  wsl = {
    enable = true;
    wslConf.automount.root = "/mnt";
    defaultUser = "nixos";
    startMenuLaunchers = true;
    extraBin = with pkgs; [
      { src = "${coreutils}/bin/uname"; }
      { src = "${coreutils}/bin/dirname"; }
      { src = "${coreutils}/bin/readlink"; }
      { src = "${coreutils}/bin/rm"; }
      { src = "${coreutils}/bin/cp"; }
      { src = "${coreutils}/bin/mv"; }
      { src = "${coreutils}/bin/sleep"; }
      { src = "${coreutils}/bin/wc"; }
      { src = "${coreutils}/bin/mkdir"; }
      { src = "${coreutils}/bin/date"; }
      { src = "${gnutar}/bin/tar"; }
      { src = "${gzip}/bin/gzip"; }
      { src = "${findutils}/bin/find"; }
      { src = "${nodejs_18}/bin/node"; }
    ];
  };

  environment.systemPackages = [
    pkgs.wget
    pkgs.nodejs_18
  ];

  virtualisation.docker.enable = true;

  users.users.nixos.isNormalUser = true;
  programs = {
    nix-ld.enable = true;
  };

  home-manager.users.nixos = { pkgs, ... }: {
    home.packages = [
      pkgs.fd
      pkgs.git
      pkgs.jq
      pkgs.ripgrep
      pkgs.tldr
      pkgs.wget
      pkgs.nixpkgs-fmt
      pkgs.nil
      pkgs.statix
    ];

    programs = {
      bash.enable = true;
      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };
      fzf.enable = true;
      gh = {
        enable = true;
        settings = {
          # Workaround for https://github.com/nix-community/home-manager/issues/4744
          version = 1;
        };
      };
      git = {
        enable = true;
        includes = [
          { path = "~/.config/git/config.inc"; }
        ];
        aliases = {
          b = "branch --color -v";
          co = "checkout";
          d = "diff HEAD";
          ds = "diff --staged";
          exec = "!exec ";
          ri = "rebase --interactive";
        };
      };
      home-manager.enable = true;
      neovim.enable = true;
      starship.enable = true;
    };

    # Until HM does not use optionsDocBook anymore, we just disable the HM config manpage.
    manual.manpages.enable = false;

    home.stateVersion = "23.05";
  };

  nix.buildMachines = [
    {
      hostName = "bld1.numtide.com";
      system = "x86_64-linux";
      maxJobs = 4;
      speedFactor = 2;
      sshUser = "jfroche";
      protocol = "ssh";
      sshKey = "/home/nixos/.ssh/id_ed25519";
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    }
  ];

  settings = {
    boot.mode = "none";
    network.host_name = "wsl";
    hardwarePlatform = config.settings.hardwarePlatforms.none;
    reverse_tunnel.enable = false;
    sshd.enable = false;
    sshguard.enable = false;
    system.secrets.enable = false;
    services = {
      server-lock.enable = true;
    };
  };
}
