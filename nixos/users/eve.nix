{
  config,
  pkgs,
  ...
}:

{
  users.mutableUsers = false;

  users.users.eve = {
    isNormalUser = true;
    description = "Eve";
    extraGroups = [
      "wheel"
      "systemd-journal"
    ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINPlYx9G8C3FPSKXEiEe1fXazdknuWz5tSiyf+BsgE9y eve@Nyx"
    ];
  };
}
