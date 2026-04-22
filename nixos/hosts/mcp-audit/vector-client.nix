# hosts/mcp-audit/vector-client.nix
#
# Vector audit-client configuration for mcp-audit (D-07 publish side).
# Imported by the full `mcp-audit` flake output ONLY — not by `mcp-audit-phase1`.
# Kept separate so bootstrap-cluster.sh can deploy mcp-audit without Vector
# until NATS creds are available, then switch to the full config.
#
# Prerequisites:
#   - NATS cluster bootstrapped
#   - Real creds written to nixos/secrets/mcp-audit.yaml (nats_client_creds)
#   - sops binding for nats-client-creds added to hosts/mcp-audit/default.nix
{ ... }:
{
  imports = [
    ../../modules/vector-audit-client.nix
  ];

  # mcp-audit also runs a Vector client that forwards its own journald into
  # the NATS cluster, so operator activity on this box is captured by the
  # same audit pipeline it hosts.
  services.mcpVectorAuditClient.enable = true;
  services.mcpVectorAuditClient.lxcIp = "10.0.120.20";
  # mcp-audit hosts step-ca locally; use the exported root cert path
  # instead of the sops-provisioned one (which is placeholder-only
  # on the CA host since the root is generated on first boot).
  services.mcpVectorAuditClient.caRootPath = "/var/lib/step-ca-root/root_ca.pem";

  # Order Vector's cert-bootstrap after the root export so the --root
  # path is guaranteed to exist.
  systemd.services.vector-client-cert = {
    after = [ "step-ca-root-export.service" ];
    requires = [ "step-ca-root-export.service" ];
  };

  # nats-client-creds: sops binding for Vector's NATS auth.
  # Present only in this phase-2 module; absent in phase-1 so sops-nix
  # never materializes the file and vector.service is never triggered.
  sops.secrets."nats-client-creds" = {
    key = "nats_client_creds";
    path = "/run/secrets/nats-client.creds";
    owner = "vector";
    group = "vector";
    mode = "0400";
  };
}
