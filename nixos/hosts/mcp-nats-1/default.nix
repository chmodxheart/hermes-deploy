# hosts/mcp-nats-1/default.nix
# Source: .planning/phases/01-audit-substrate/01-06-PLAN.md Task 1 (canonical shape)
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-02 D-03 D-04 D-11 D-13 D-14 D-16 D-17
# Source: .planning/phases/01-audit-substrate/01-PATTERNS.md §hosts/mcp-nats-{1,2,3}/default.nix
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P5 (declarative nftables only)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P9 (cert-bootstrap ordering)
#
# First NATS cluster member. Near-identical to mcp-nats-2/3 (PATTERNS.md
# "copy+rename; do not over-DRY"). The three hosts differ only in
# `serverName`, `lxcIp`, and `sops.defaultSopsFile`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Host-identity bindings. Plan 01-06 per-host rename target.
  lxcIp = "10.0.2.11";
  # Hermes source address. Appears only in this let-binding — never in an
  # accept rule below. That absence IS the AUDIT-03 / D-11 invariant; Plan
  # 01-07's `assert-no-hermes-reach` flake-check greps the rendered ruleset
  # and asserts zero matches for this string.
  hermesIp = "10.0.1.91";
  # D-17 narrow Prom carve-out. FIXME(Plan 01-09): substitute real Cilium
  # egress gateway IP before production rebuild; this placeholder is in the
  # common Cilium pod-CIDR range but is not verified against live infra.
  promSourceIp = "10.42.0.14";
  # Full audit-plane allowlist for NATS client port 4222. Includes the three
  # NATS peers plus mcp-audit (the subscribe-side consumer). hermesIp is
  # deliberately absent — D-11 one-way posture (hermes publishes OTel via the
  # Vector client on its OWN box; it never dials 4222 from the hermes LXC).
  auditPlaneAllowlist = [
    "10.0.2.10"
    "10.0.2.11"
    "10.0.2.12"
    "10.0.2.13"
  ];
  # Cluster port 6222 is peer-only. Self-filter so we never accept a route
  # from our own IP — that would be a misconfiguration, not a legitimate
  # cluster member.
  clusterPeerIps = lib.filter (ip: ip != lxcIp) auditPlaneAllowlist;
  # FIXME(Plan 01-09 / T-06-03): tighten to Evelyn's workstation IP once the
  # nats-bring-up runbook confirms the admin source. LAN-wide 10.0.1.0/24 is
  # acceptable for the bootstrap window; fail2ban (common.nix) caps probe cost.
  sshAllowlist = "10.0.1.0/24";
in
{
  imports = [
    ../../modules/mcp-otel.nix
    ../../modules/nats-cluster.nix
    ../../modules/nats-accounts.nix
    ../../modules/vector-audit-client.nix
    ../../modules/mcp-prom-exporters.nix
    ../../modules/pbs-excludes.nix
  ];

  system.stateVersion = "25.11";

  # FOUND-05 (formally Phase 2) applied early per CONTEXT §code_context:
  # common.nix ships auto-upgrade enabled (hard `= true`, not mkDefault); the
  # audit plane disables it with mkForce so an unattended nixpkgs input bump
  # cannot rug-pull the cluster overnight.
  system.autoUpgrade.enable = lib.mkForce false;

  # sops bindings. defaultSopsFile is the per-host yaml (host key decrypts
  # it); nats-accounts.nix separately binds the shared operator file.
  #
  # The nats_server_cert / vector_client_cert / *_key slots in
  # secrets/mcp-nats-1.yaml are REPLACE_ME_POPULATED_AT_BOOTSTRAP — the
  # cert-bootstrap oneshots in modules/nats-cluster.nix +
  # modules/vector-audit-client.nix WRITE the real certs into
  # /run/{nats,vector}-certs/ at activation time, so they are deliberately
  # NOT surfaced via sops.secrets.* here.
  sops = {
    # Two-stage bootstrap (Plan 01-02, CONVENTIONS §Secrets Layout): on a
    # fresh check-out only the `.yaml.example` templates exist; the real
    # encrypted files land after `ssh-to-age` publishes the host pubkey to
    # `.sops.yaml` and Evelyn runs `sops -e -i` on the populated templates.
    # Build-time file-existence validation must be OFF until that runbook
    # step completes; `nix flake check` on a clean clone otherwise throws
    # on missing `secrets/mcp-nats-*.yaml` / `secrets/nats-operator.yaml`.
    # Plan 01-09 flips this back to the default (`true`) once the real
    # files are committed.
    validateSopsFiles = false;
    defaultSopsFile = ../../secrets/mcp-nats-1.yaml;
    secrets = {
      "step-ca-root" = {
        key = "step_ca_root_cert";
        path = "/run/secrets/step-ca-root";
        owner = "root";
        group = "root";
        mode = "0444";
      };
      "nats-client-creds" = {
        key = "nats_client_creds";
        path = "/run/secrets/nats-client.creds";
        owner = "vector";
        group = "vector";
        mode = "0400";
      };
    };
  };

  # --- NATS cluster member (D-02, D-03, D-04) ---
  services.mcpNatsCluster.enable = true;
  services.mcpNatsCluster.serverName = "mcp-nats-1";
  services.mcpNatsCluster.clusterPeers = [
    "mcp-nats-1"
    "mcp-nats-2"
    "mcp-nats-3"
  ];
  # I-2 nullable pattern — module default is null so Wave 3 `nix flake check`
  # evaluates cleanly. Plan 09-02 runbook step replaces the commented line
  # with the literal pubkey from secrets/nats-operator.yaml ::
  # nats_system_account_public_key after the nsc bootstrap runs.
  # services.mcpNatsCluster.systemAccountPublicKey = "<set by Plan 09 nsc bootstrap>";
  services.mcpNatsCluster.caUrl = "https://ca.samesies.gay:8443";

  # --- NATS accounts + operator JWT sops bindings (D-03) ---
  services.mcpNatsAccounts.enable = true;

  # --- Vector audit client (D-07) ---
  services.mcpVectorAuditClient.enable = true;
  services.mcpVectorAuditClient.lxcIp = lxcIp;

  # --- Baseline Prom exporters + D-17 narrow carve-out ---
  services.mcpPromExporters.enable = true;
  services.mcpPromExporters.promSourceIp = promSourceIp;
  # node_exporter (9100) + Vector's prometheus_exporter sink (9598) +
  # nats-exporter (7777, scraping local http_port 8222).
  services.mcpPromExporters.exporterPorts = [
    9100
    9598
    7777
  ];

  # nats-exporter — scrapes the local NATS monitor endpoint (http_port 8222
  # from modules/nats-cluster.nix) and re-exposes Prom-format metrics on
  # :7777 for k8s Prometheus.
  services.prometheus.exporters.nats = {
    enable = true;
    openFirewall = false;
    listenAddress = "0.0.0.0";
    port = 7777;
    url = "http://127.0.0.1:8222";
  };

  # --- PBS excludes (FOUND-06) ---
  # Default list from modules/pbs-excludes.nix plus NATS-specific scratch.
  services.mcpAuditPbs.excludePaths = [
    "/run"
    "/var/run"
    "/proc"
    "/sys"
    "/dev"
    "/tmp"
    "/var/cache"
    "/run/secrets"
    "/var/lib/nats/jetstream/tmp"
  ];

  # --- D-11 declarative nftables (one-way-to-hermes posture) ---
  # Rule set:
  #   - 4222/tcp (NATS TLS)  ← whole audit-plane allowlist (including peers
  #                             so cluster members can round-robin via 4222
  #                             for their own ad-hoc client work)
  #   - 6222/tcp (cluster)   ← OTHER TWO NATS peers only (self filtered)
  #   - 22/tcp   (SSH)       ← sshAllowlist (LAN; tighten in Phase 2)
  # Absent: any accept rule for hermesIp. Plan 01-07's
  # `assert-no-hermes-reach` flake-check greps the rendered ruleset for the
  # hermesIp let-binding value and asserts zero matches.
  networking.nftables.tables.nats-ingress = {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority 0;
        ip saddr { ${lib.concatStringsSep ", " auditPlaneAllowlist} } tcp dport 4222 accept
        ip saddr { ${lib.concatStringsSep ", " clusterPeerIps} } tcp dport 6222 accept
        ip saddr ${sshAllowlist} tcp dport 22 accept
      }
    '';
  };

  # --- D-13 AD DNS + /etc/hosts bootstrap fallback ---
  # AD domain controllers are authoritative for samesies.gay. systemd-resolved
  # fronts them; if AD is down during cert-bootstrap (Pitfall 9) /etc/hosts
  # still resolves ca.samesies.gay + peers for the step-ca ACME request.
  networking.nameservers = [
    "10.0.1.30"
    "10.0.1.31"
    "10.0.1.32"
  ];
  services.resolved.enable = true;
  services.resolved.domains = [ "samesies.gay" ];
  networking.extraHosts = ''
    10.0.2.10 mcp-audit.samesies.gay ca.samesies.gay
    10.0.2.11 mcp-nats-1.samesies.gay
    10.0.2.12 mcp-nats-2.samesies.gay
    10.0.2.13 mcp-nats-3.samesies.gay
  '';
}
