{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  proxmoxLXC = {
    manageNetwork = false;
    manageHostName = false;
  };

  # Nix build sandbox needs mount namespaces that Proxmox LXC doesn't expose
  # by default; builds fail unless we turn it off.
  nix.settings.sandbox = false;

  # systemd-networkd-wait-online hangs forever in LXC; the network is up
  # long before systemd decides it is.
  systemd.network.wait-online.enable = false;
  systemd.services.systemd-networkd-wait-online.enable = false;

  # LXC delivers an already-running init, so console units fight for the tty.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  boot.isContainer = true;
  boot.loader.grub.enable = false;

  # Podman, rootful, for hermes-agent's container mode.
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    autoPrune.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };
  virtualisation.containers.enable = true;
}
