{
  config,
  pkgs,
  lib,
  inputs,
  modulesPath,
  ...
}:

{
  imports = [
    inputs.disko.nixosModules.disko
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # Per-host disko layout is expected under hosts/<name>/disk-config.nix;
  # importers should add it themselves. This profile only wires up the
  # generic cloud-VM surface.

  boot.loader = {
    grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
    systemd-boot.enable = lib.mkDefault false;
  };

  services.qemuGuest.enable = true;
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # Serial console for providers that expose one (Hetzner, DO, etc.)
  boot.kernelParams = [
    "console=tty1"
    "console=ttyS0,115200"
  ];

  # Grow the root filesystem on first boot if the image is resized
  # (most providers resize on instance create).
  systemd.services.growfs = {
    description = "Grow root filesystem on first boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.cloud-utils}/bin/growpart /dev/disk/by-label/nixos 1 || true";
    };
  };
}
