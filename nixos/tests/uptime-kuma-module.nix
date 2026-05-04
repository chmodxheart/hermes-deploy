let
  moduleText = builtins.readFile ../modules/uptime-kuma.nix;

  contains = needle: builtins.match ".*${needle}.*" moduleText != null;
in
{
  task1NativeSettings =
    assert contains "options.services.homelabUptimeKuma";
    assert contains "services.uptime-kuma";
    assert contains "DATA_DIR = toString cfg.dataDir";
    assert contains ''HOST = "0.0.0.0"'';
    assert contains "PORT = toString cfg.port";
    assert !contains "networking.firewall.allowedTCPPorts";
    assert !contains "virtualisation.oci-containers";
    true;
}
