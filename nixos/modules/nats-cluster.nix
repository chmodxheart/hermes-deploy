# modules/nats-cluster.nix
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-02, D-03, D-04
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pattern 1 (lines 280-366)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pattern 2 (lines 416-437)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P9 (cert-bootstrap ordering)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P10 (validateConfig safe)
# Source: .planning/phases/01-audit-substrate/01-PATTERNS.md §modules/nats-cluster.nix
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Anti-Patterns (anonymous publishers forbidden)
#
# Reusable services.nats wrapper. Consumed by every mcp-nats-* host (Plan
# 01-06). Builds: JetStream R3 + mTLS (step-ca-issued server cert) + JWT
# "full" resolver + cluster routes + cert-bootstrap oneshot with 12h
# renewal timer.
#
# Invariants (enforced by assertions + absence-of-option):
#   * D-03: anonymous NATS publish is rejected. The anonymous-publisher
#     toggle is deliberately absent from the rendered config. An assertion
#     forbids an account literally named "anonymous" in accountJwts.
#     Plan 01-07 adds a flake-check grepping the rendered settings for
#     the anonymous-enable toggle as defense-in-depth.
#   * Pitfall 9: nats-server-cert.service is required BEFORE nats.service;
#     ExecStartPre waits for step-ca /health before requesting a cert.
#   * D-04: step-ca issues 24h certs; the renewal timer fires every 12h.
#
# Deliberately NOT in this module (host-module / consumer-plan concern):
#   * Firewall rules / nftables carve-outs (D-11 per-host in Plan 01-06).
#   * JetStream stream creation (separate oneshot in mcp-audit Plan 01-08).
#   * Per-host sops bindings for the client .creds blob (host-level).
#   * system_account public key when null (I-2: omitted so Wave 3
#     `nix flake check` evaluates cleanly before the Plan 01-09 nsc
#     bootstrap threads the real value into secrets/nats-operator.yaml).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.mcpNatsCluster;
  # Peers excluding self — routes point at the other cluster members only.
  peers = lib.filter (p: p != cfg.serverName) cfg.clusterPeers;
  # step-ca /health probe script. Loops up to 120s so a fresh-boot race
  # with step-ca-cert-bootstrap / step-ca.service is handled gracefully
  # (Pitfall 9). Returns 0 once the CA answers; hard-fails otherwise.
  waitForStepCa = pkgs.writeShellScript "wait-for-step-ca" ''
    set -euo pipefail
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -fsSk "${cfg.caUrl}/health" >/dev/null 2>&1; then
        exit 0
      fi
      sleep 2
    done
    echo "step-ca not reachable after 120s" >&2
    exit 1
  '';
  # Request-or-renew the NATS server TLS cert against step-ca's ACME
  # provisioner (D-04, 24h certs). Runs as the `nats` user so the output
  # files land with the right ownership in /run/nats-certs (tmpfiles dir).
  natsCertRequest = pkgs.writeShellScript "nats-cert-request" ''
    set -euo pipefail
    ${pkgs.step-cli}/bin/step ca certificate \
      "${cfg.serverName}.samesies.gay" \
      /run/nats-certs/server.crt \
      /run/nats-certs/server.key \
      --provisioner acme \
      --ca-url ${cfg.caUrl} \
      --root /run/secrets/step-ca-root \
      --force
  '';
in
{
  options.services.mcpNatsCluster = {
    enable = lib.mkEnableOption "mcp NATS cluster member";

    serverName = lib.mkOption {
      type = lib.types.str;
      example = "mcp-nats01";
      description = ''
        Short server name — matches the hostname of this LXC. Used both as
        the NATS `server_name` and to filter self out of the cluster route
        list (so we don't dial our own 6222).
      '';
    };

    clusterName = lib.mkOption {
      type = lib.types.str;
      default = "mcp-audit-cluster";
      description = ''
        NATS cluster name. All three mcp-nats-* members share this.
      '';
    };

    clusterPeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [
        "mcp-nats01"
        "mcp-nats02"
        "mcp-nats03"
      ];
      description = ''
        All cluster peers including self — the module filters self out when
        rendering `cluster.routes`. Names are resolved via samesies.gay AD
        DNS (D-13).
      '';
    };

    systemAccountPublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Public NKey of the NATS system account (sourced from
        secrets/nats-operator.yaml :: nats_system_account_public_key).
        Nullable so Wave 3 `nix flake check` passes before Plan 01-09 nsc
        bootstrap populates the real value — when null, the
        `system_account` config line is omitted entirely (I-2 pattern).
      '';
    };

    accountJwts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        resolver_preload: attrset of account-name -> JWT string. Empty by
        default; the canonical Phase 1 flow uses the file-based `full`
        resolver backed by /var/lib/nats/jwt (populated by the
        nats-jwt-sync.service oneshot in modules/nats-accounts.nix).
        Hosts that prefer an in-config preload can populate this attrset
        via builtins.readFile on sops-exposed paths at host level.
      '';
    };

    caUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://ca.samesies.gay:8443";
      description = ''
        step-ca base URL used by the cert-bootstrap oneshot. Health probe
        hits ${"$"}{caUrl}/health before the cert request runs.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # D-03 guard: an account literally named "anonymous" in resolver_preload
    # would be a trivial foot-gun. Fail the build, do not silently accept.
    # Plan 01-07 adds a second-layer flake-check grepping the rendered
    # config for the anonymous-enable toggle as a defense-in-depth assertion.
    assertions = [
      {
        assertion = !(cfg.accountJwts ? anonymous);
        message = "mcpNatsCluster: an 'anonymous' account is never allowed (D-03)";
      }
    ];

    # Dotted-form enable + jetstream toggles — written explicitly so plan
    # gates + future flake-check greps can match the canonical NixOS option
    # path. NixOS merges these with the attrset form below; no conflict.
    services.nats.enable = true;
    services.nats.jetstream = true;

    services.nats = {
      serverName = cfg.serverName;
      port = 4222;
      dataDir = "/var/lib/nats";
      # Pitfall 10: hostnames are static strings; `vector`-style env-var
      # interpolation is absent, so the build-time validator is safe. When
      # systemAccountPublicKey is still null (pre-Plan-01-09) the validator
      # would reject the omitted system_account key, so we gate it on the
      # pubkey being populated (I-2).
      validateConfig = cfg.systemAccountPublicKey != null;
      settings = {
        # Cluster routes — peers only. 0.0.0.0:6222 because the nftables
        # carve-out (Plan 01-06 host module) restricts inbound to sibling
        # NATS LXC IPs on 6222.
        cluster = {
          name = cfg.clusterName;
          listen = "0.0.0.0:6222";
          routes = map (p: "nats://${p}.samesies.gay:6222") peers;
        };

        # JetStream persistent storage (D-02: file-backed on Ceph RBD).
        # Sizing matches CONTEXT §Specifics: 30G on-disk budget with
        # 2G in-memory buffer. `store_dir` uses lib.mkForce because the
        # upstream NixOS services.nats module sets it to `cfg.dataDir` by
        # default; we override to a jetstream/ subdir so the JWT resolver
        # (`dir = "/var/lib/nats/jwt"`) and jetstream data don't collide
        # under the same root.
        jetstream = {
          store_dir = lib.mkForce "/var/lib/nats/jetstream";
          max_mem = "2G";
          max_file = "30G";
        };

        # Monitor endpoint scraped by services.prometheus.exporters.nats
        # (wired by modules/mcp-prom-exporters.nix + host extension).
        http_port = 8222;

        # mTLS — server cert issued by step-ca (24h, renewed 12h). Client
        # cert verification is ON (D-03: no anonymous; clients authenticate
        # via NKey/JWT-in-creds, and TLS identity is independently checked).
        tls = {
          cert_file = "/run/nats-certs/server.crt";
          key_file = "/run/nats-certs/server.key";
          ca_file = "/run/secrets/step-ca-root";
          verify = true;
        };

        # JWT "full" resolver — each server stores JWTs on disk and syncs
        # cluster-wide via the system account. File-based means
        # modules/nats-accounts.nix's nats-jwt-sync.service drops JWT files
        # into /var/lib/nats/jwt and the server reads them at start.
        operator = "/run/secrets/nats-operator-jwt";
        resolver = {
          type = "full";
          dir = "/var/lib/nats/jwt";
          allow_delete = false;
          interval = "2m";
          limit = 1000;
        };
        resolver_preload = cfg.accountJwts;
      }
      # system_account is omitted entirely when the pubkey is unset — the
      # NATS validator rejects an empty/null system_account string, and a
      # flake-eval before nsc bootstrap (Wave 3, Plan 01-09) has no real
      # value yet. Once the pubkey lands in secrets/nats-operator.yaml the
      # host module threads it through and this attrset merges in.
      // lib.optionalAttrs (cfg.systemAccountPublicKey != null) {
        system_account = cfg.systemAccountPublicKey;
      };
    };

    # Tmpfiles entry for the runtime cert dir — created before nats user
    # exists-check, so we can't reference `config.users.users.nats` here.
    # The nixpkgs services.nats module creates the `nats` user/group.
    systemd.tmpfiles.settings."20-nats-certs"."/run/nats-certs".d = {
      user = "nats";
      group = "nats";
      mode = "0700";
    };

    # Pitfall 9: NATS must NOT start before the cert files exist. This
    # oneshot provisions them via step-ca ACME; the ExecStartPre script
    # refuses to proceed until step-ca answers /health.
    systemd.services.nats-server-cert = {
      description = "Obtain/renew NATS server TLS cert via step-ca ACME";
      wantedBy = [ "nats.service" ];
      before = [ "nats.service" ];
      # Wait for network so the step-ca health check can reach the CA.
      # Actual step-ca readiness is enforced by the ExecStartPre probe loop
      # (Pitfall 9) — a systemd-level `after = step-ca.service` would only
      # help on the co-located mcp-audit host and would need conditional
      # wiring; the probe loop is universal.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "nats";
        Group = "nats";
        ExecStartPre = waitForStepCa;
        ExecStart = natsCertRequest;
      };
    };

    # D-04 renewal cadence — 12h on 24h certs gives >50% lifetime headroom.
    systemd.timers.nats-server-cert-renew = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "12h";
        Unit = "nats-server-cert.service";
      };
    };

    # Pitfall 9 ordering: nats.service requires AND is ordered after the
    # cert-bootstrap oneshot. ReadWritePaths augments the upstream module's
    # defaults so NATS can open jetstream/ + jwt/ + the cert tmpfiles dir.
    systemd.services.nats = {
      requires = [ "nats-server-cert.service" ];
      after = [ "nats-server-cert.service" ];
      serviceConfig.ReadWritePaths = [
        "/var/lib/nats"
        "/var/lib/nats/jetstream"
        "/var/lib/nats/jwt"
        "/run/nats-certs"
      ];
    };
  };
}
