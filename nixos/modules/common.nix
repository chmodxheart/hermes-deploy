{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

{
  nixpkgs.config.allowUnfree = true;

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        "@wheel"
      ];
      auto-optimise-store = true;
      warn-dirty = false;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  # autoUpgrade tracks the canonical remote. Keep this URL in sync with
  # `git remote get-url origin`; the `just check-autoupgrade` recipe asserts
  # this on demand. When a known-good revision is reached, bump this to
  # pin a tag (e.g. `?ref=v0.1.0`) instead of tracking `main`.
  system.autoUpgrade = {
    enable = true;
    flake = "github:chmodxheart/hermes-deploy?dir=nixos";
    flags = [
      "--update-input"
      "nixpkgs"
      "-L"
    ];
    dates = "04:00";
    randomizedDelaySec = "45min";
    allowReboot = false;
  };

  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";

  networking = {
    nftables.enable = true;
    firewall = {
      enable = true;
      allowPing = true;
      allowedTCPPorts = [ 22 ];
    };
    useNetworkd = lib.mkDefault true;
  };

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      X11Forwarding = false;
      AllowTcpForwarding = "yes";
      ClientAliveInterval = 300;
      ClientAliveCountMax = 2;
      MaxAuthTries = 3;
      Ciphers = [
        "chacha20-poly1305@openssh.com"
        "aes256-gcm@openssh.com"
        "aes128-gcm@openssh.com"
      ];
      KexAlgorithms = [
        "curve25519-sha256"
        "curve25519-sha256@libssh.org"
      ];
      Macs = [
        "hmac-sha2-512-etm@openssh.com"
        "hmac-sha2-256-etm@openssh.com"
      ];
    };
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    bantime-increment = {
      enable = true;
      maxtime = "24h";
      factor = "4";
    };
  };

  programs.fish.enable = true;

  environment.systemPackages = with pkgs; [
    # Shell / editor
    vim
    helix

    # Search & navigation
    ripgrep
    fd
    fzf
    eza
    zoxide

    # File viewing & processing
    bat
    jq
    yq

    # System monitoring
    htop
    btop
    ncdu
    duf

    # Git
    git
    git-lfs
    gh
    delta

    # Archive
    unzip
    p7zip

    # Network
    curl
    wget
    httpie
    dnsutils

    # Misc
    tree
    tldr
    watchexec
    tmux

    # Ops / secrets
    age
    sops
    ssh-to-age
  ];

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
  };

  programs.git = {
    enable = true;
    config = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      fetch.prune = true;
    };
  };

  security.sudo.wheelNeedsPassword = false;

  sops = {
    # Dedicated age identity per host, delivered by scripts/bootstrap-host.sh
    # before the first `nixos-rebuild switch`. Keeping sshKeyPaths as a
    # fallback preserves the existing hermes flow (ssh_host_ed25519 →
    # ssh-to-age) while letting new hosts use pre-generated age keys.
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.generateKey = false;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFormat = "yaml";
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/sops-nix 0700 root root -"
  ];
}
