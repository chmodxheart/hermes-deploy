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

  task2PhaseInvariants =
    assert contains ''toString cfg.dataDir == "/var/lib/uptime-kuma"'';
    assert contains "cfg.port == 3001";
    assert contains "@sha256:";
    assert contains "NFS";
    true;
}
