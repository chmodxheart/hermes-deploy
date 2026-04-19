# modules/step-ca.nix
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-04 (24h ACME certs)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pattern 2 (canonical module body)
# Source: https://smallstep.com/docs/step-ca/configuration (ACME provisioner)
#
# Thin wrapper around the upstream nixpkgs `services.step-ca` module. Stood up
# on `mcp-audit` (co-located per RESEARCH §Claude's Discretion — no dedicated
# `mcp-ca` LXC). Issues 24-hour certs via one ACME provisioner; every NATS
# server and Vector client bootstraps its cert through that provisioner.
#
# Deliberately NOT in this module:
#   * Client-side cert-bootstrap oneshots (`nats-server-cert.service` et al.)
#     — they need `${config.networking.hostName}.samesies.gay` interpolation
#     and live in Plans 01-05 (NATS) / 01-06 (mcp-audit). See RESEARCH §P9.
#   * Inbound port carve-outs (firewall / nftables allow rules) — those are
#     per-host per CONTEXT D-11; this module stays host-agnostic.
#
# Secret binding: sops-nix materialises the intermediate-key password into
# `/run/secrets/step-ca-intermediate-pw` at boot; step-ca reads it via
# `services.step-ca.intermediatePasswordFile`. The sops key is
# `step_ca_intermediate_pw` (see secrets/mcp-audit.yaml.example line 68).
{ config, lib, ... }:
{
  services.step-ca = {
    enable = true;
    # ACME HTTP-01 challenge needs LAN reach; inbound 8443 is scoped per-host
    # in Plan 01-06's nftables rules (NATS + Vector client IPs only).
    address = "0.0.0.0";
    port = 8443;
    intermediatePasswordFile = "/run/secrets/step-ca-intermediate-pw";
    settings = {
      root = "/var/lib/step-ca/certs/root_ca.crt";
      crt = "/var/lib/step-ca/certs/intermediate_ca.crt";
      key = "/var/lib/step-ca/secrets/intermediate_ca_key";
      dnsNames = [
        "mcp-audit.samesies.gay"
        "ca.samesies.gay"
      ];
      db = {
        type = "badgerv2";
        dataSource = "/var/lib/step-ca/db";
      };
      authority = {
        provisioners = [
          {
            type = "ACME";
            name = "acme";
            # Issued cert CN must match the requested identity — mitigates a
            # malicious client requesting a spoofed CN.
            forceCN = true;
            claims = {
              defaultTLSCertDuration = "24h";
              maxTLSCertDuration = "24h";
              minTLSCertDuration = "5m";
            };
          }
        ];
      };
      tls = {
        minVersion = 1.2;
        maxVersion = 1.3;
      };
    };
  };

  # Literal "step-ca" owner/group rather than `config.services.step-ca.user`:
  # the upstream module does not expose a `.user` option, and resolving it
  # through `config` would introduce an ordering hazard on first eval.
  sops.secrets."step-ca-intermediate-pw" = {
    key = "step_ca_intermediate_pw";
    path = "/run/secrets/step-ca-intermediate-pw";
    owner = "step-ca";
    group = "step-ca";
    mode = "0400";
  };
}
