# hosts/mcp-audit/default.nix
# Source: .planning/phases/01-audit-substrate/01-08-PLAN.md Task 2 (host entry)
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-04 D-05 D-06 D-08 D-11 D-12 D-13 D-17
# Source: .planning/phases/01-audit-substrate/01-PATTERNS.md §hosts/mcp-nats-{1,2,3}/default.nix
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P5 P9
#
# Audit-sink LXC. Co-hosts step-ca (D-04), the full Langfuse v3 stack
# (D-05/06, native Postgres/ClickHouse/Redis + digest-pinned oci-containers),
# the langfuse-nats-ingest bridge (D-08), and the Vector consumer side of
# audit.journal.> (D-07). External MinIO backing store at
# https://minio.samesies.gay (D-05) — no in-LXC S3 container.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Host-identity bindings (CONTEXT §infra_facts).
  lxcIp = "10.0.120.20";
  # Hermes source address. Appears only in this let-binding — never in an
  # accept rule below. That absence IS the AUDIT-03 / D-11 invariant; the
  # `assert-no-hermes-reach` flake-check greps every rendered table for this
  # string and asserts zero matches.
  hermesIp = "10.0.1.91";
  # D-17 narrow Prom carve-out. FIXME(Plan 01-09): substitute the real Cilium
  # egress gateway IP before production rebuild; this placeholder is in the
  # common Cilium pod-CIDR range but is not verified against live infra.
  promSourceIp = "10.42.0.14";
  # Audit-plane peers (NATS cluster + self). Kept for symmetry with
  # mcp-nats-{1,2,3}; used to scope the step-ca ACME port. Every cert-bootstrap
  # client in the audit plane bootstraps through this mcp-audit:8443.
  auditPlaneAllowlist = [
    "10.0.120.20"
    "10.0.120.21"
    "10.0.120.22"
    "10.0.120.23"
  ];
  # step-ca ACME is peer-only within the audit plane. Hermes is deliberately
  # absent (AUDIT-03 / D-11). If a future phase needs hermes-issued certs it
  # must use a separate posture (e.g. a relay).
  acmeAllowlist = auditPlaneAllowlist;
  # FIXME(Plan 01-09 / T-06-03): tighten to Evelyn's workstation IP once the
  # mcp-audit bring-up runbook confirms the admin source. LAN-wide 10.0.1.0/24
  # is acceptable for the bootstrap window; fail2ban (common.nix) caps probe
  # cost.
  sshAllowlist = "10.0.1.0/24";
in
{
  imports = [
    ../../modules/mcp-audit.nix
    ../../modules/mcp-otel.nix
    ../../modules/step-ca.nix
    ../../modules/vector-audit-client.nix
    ../../modules/mcp-prom-exporters.nix
    ../../modules/pbs-excludes.nix
  ];

  system.stateVersion = "25.11";

  # FOUND-05 mkForce: common.nix ships auto-upgrade enabled as a hard `= true`;
  # the audit plane opts out so an unattended nixpkgs bump cannot rug-pull the
  # Langfuse stack overnight.
  system.autoUpgrade.enable = lib.mkForce false;

  # sops bindings. The module layer (mcp-audit.nix, step-ca.nix) binds its
  # own secrets; the host only declares the decrypt key path and the
  # root-cert sops slot shared with every audit-plane client.
  sops = {
    # Two-stage bootstrap (Plan 01-02, CONVENTIONS §Secrets Layout): on a
    # fresh check-out only the `.yaml.example` template exists; the real
    # encrypted file lands after `ssh-to-age` publishes the host pubkey to
    # `.sops.yaml` and Evelyn runs `sops -e -i` on the populated template.
    # Build-time file-existence validation must be OFF until that runbook
    # step completes; Plan 01-09 flips this back to the default (`true`)
    # once the real file is committed.
    validateSopsFiles = false;
    defaultSopsFile = ../../secrets/mcp-audit.yaml;
    secrets = {
      "step-ca-root" = {
        key = "step_ca_root_cert";
        path = "/run/secrets/step-ca-root";
        owner = "root";
        group = "root";
        mode = "0444";
      };
      # NATS client credentials for Vector's NATS source+sink. Populated after
      # the NATS cluster is bootstrapped (Plan 01-09). Until then the file is
      # materialized with REPLACE_ME content; vector.service has
      # ConditionPathExists=/run/secrets/nats-client.creds so it stays inactive
      # (not crash-looping) until real creds are substituted and a rebuild runs.
      "nats-client-creds" = {
        key = "nats_client_creds";
        path = "/run/secrets/nats-client.creds";
        owner = "vector";
        group = "vector";
        mode = "0400";
      };
    };
  };

  # --- Vector audit client (publish side — D-07) ---
  # mcp-audit also runs a Vector client that forwards its own journald into
  # the NATS cluster, so operator activity on this box is captured by the
  # same audit pipeline it hosts.
  services.mcpVectorAuditClient.enable = true;
  services.mcpVectorAuditClient.lxcIp = lxcIp;
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

  # --- Baseline Prom exporters + D-17 narrow carve-out ---
  services.mcpPromExporters.enable = true;
  services.mcpPromExporters.promSourceIp = promSourceIp;
  # node_exporter (9100) + Vector's prometheus_exporter sink (9598).
  # Langfuse web/worker and Postgres/ClickHouse/Redis are not scraped from
  # outside the box in this phase; add targeted exporters in Phase 2 if
  # observability expands.
  services.mcpPromExporters.exporterPorts = [
    9100
    9598
  ];

  # --- D-11 declarative nftables ---
  # Rule set:
  #   - 22/tcp   (SSH)        ← sshAllowlist (LAN; tighten in Phase 2)
  #   - 8443/tcp (step-ca)    ← acmeAllowlist (audit-plane peers only)
  #
  # Deliberately absent:
  #   - 3000/tcp (Langfuse web UI) — access via SSH tunnel only; no LAN reach
  #   - 4222/6222 — mcp-audit is a NATS CONSUMER; the ingest service dials out
  #   - any rule referencing hermesIp — AUDIT-03 invariant (verified by
  #     the `assert-no-hermes-reach` flake-check)
  #
  # Prom ports (9100, 9598) are opened by modules/mcp-prom-exporters.nix
  # in its own table, scoped to promSourceIp.
  networking.nftables.tables.mcp-audit-ingress = {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority 0;
        ip saddr ${sshAllowlist} tcp dport 22 accept
        ip saddr { ${lib.concatStringsSep ", " acmeAllowlist} } tcp dport 8443 accept
        # ACME HTTP-01 challenge: step-ca reaches back to each audit-plane
        # host's :80 to verify cert ownership. Scoped to those peers only.
        ip saddr { ${lib.concatStringsSep ", " acmeAllowlist} } tcp dport 80 accept
      }
    '';
  };

  # --- D-13 AD DNS + /etc/hosts bootstrap fallback ---
  # AD domain controllers are authoritative for samesies.gay. systemd-resolved
  # fronts them; if AD is down during cert-bootstrap (Pitfall 9) /etc/hosts
  # still resolves ca.samesies.gay + peers for step-ca and the NATS consumer.
  networking.nameservers = [
    "10.0.1.30"
    "10.0.1.31"
    "10.0.1.32"
  ];
  services.resolved.enable = true;
  services.resolved.domains = [ "samesies.gay" ];
  networking.extraHosts = ''
    10.0.120.20 mcp-audit.samesies.gay ca.samesies.gay
    10.0.120.21 mcp-nats01.samesies.gay
    10.0.120.22 mcp-nats02.samesies.gay
    10.0.120.23 mcp-nats03.samesies.gay
  '';
}
