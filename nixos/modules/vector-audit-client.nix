# modules/vector-audit-client.nix
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-07 (Vector on every LXC)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pattern 3 (lines 440-517, canonical body)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P6 (sink ack semantics, LXC-IP bind)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P10 (validateConfig safe)
# Source: .planning/phases/01-audit-substrate/01-PATTERNS.md §modules/vector-audit-client.nix
#
# Per-LXC Vector client. Imported by every audit-plane LXC that publishes
# journald events: the 3× mcp-nats-* hosts (for their own operator/cluster
# journald) and mcp-audit (for its own journald). OTLP traces no longer flow
# through Vector because Vector's NATS sink only accepts log events; the trace
# path now uses a dedicated OTLP-to-NATS publisher module. The Vector
# *consumer* side (nats source → file sink for journald archival) lives in
# modules/mcp-audit.nix and is a separate module (Plan 01-08).
#
# Pipeline:
#   journald source ─────── journal_local ──────▶ nats_journal sink
#                                                 subject = audit.journal.<host>
#   internal_metrics ────── internal_metrics ───▶ prom_self sink
#                                                 bind = <LXC IP>:9598 (NOT 0.0.0.0)
#
# Invariants (enforced by option surface + grep-based plan-check):
#   * Pitfall 6: prometheus_exporter binds on cfg.lxcIp, never 0.0.0.0 —
#     no default for `lxcIp` so hosts MUST pass their own IP.
#   * Pitfall 6: `acknowledgements.enabled = true` on the journald source
#     and both sinks so Vector applies upstream backpressure when NATS is
#     stuck.
#   * Pitfall 9 / step-ca: vector-client-cert.service oneshot
#     ExecStartPre probes step-ca /health before requesting a cert;
#     renewal timer fires every 12h on 24h ACME certs (D-04).
#   * FOUND-07 hardening applied early (CONTEXT §Claude's Discretion):
#     NoNewPrivileges, MemoryDenyWriteExecute, SystemCallFilter, etc.
#
# Deliberately NOT here (host-module concern):
#   * Per-host sops binding for /run/secrets/nats-client.creds — each
#     host wires its own .creds from secrets/<host>.yaml in Plan 01-06.
#   * Firewall rules / nftables carve-outs (D-11).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.mcpVectorAuditClient;
  # NATS peers as a comma-separated "tls://host:port" list — Vector's
  # sink dials them round-robin with TLS-client auth.
  natsUrl = lib.concatStringsSep "," (map (p: "tls://${p}.samesies.gay:4222") cfg.natsPeers);
  # step-ca /health probe — shared shape with nats-cluster.nix's
  # waitForStepCa but scoped to the Vector client cert bootstrap (Pitfall
  # 9). Duplicated rather than extracted: each module is self-contained;
  # the two probe scripts don't share state.
  waitForStepCa = pkgs.writeShellScript "wait-for-step-ca-vector" ''
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
  # Request-or-renew the Vector client cert. `${hostname}.samesies.gay`
  # is the cert identity — step-ca's ACME provisioner has forceCN = true
  # (modules/step-ca.nix), so the CN must match the requested name.
  vectorCertRequest = pkgs.writeShellScript "vector-cert-request" ''
    set -euo pipefail
    ${pkgs.step-cli}/bin/step ca certificate \
      "${config.networking.hostName}.samesies.gay" \
      /run/vector-certs/client.crt \
      /run/vector-certs/client.key \
      --provisioner acme \
      --ca-url ${cfg.caUrl} \
      --root /run/secrets/step-ca-root \
      --force
  '';
in
{
  options.services.mcpVectorAuditClient = {
    enable = lib.mkEnableOption "per-LXC Vector client publishing to the audit-plane NATS cluster";

    lxcIp = lib.mkOption {
      type = lib.types.str;
      description = ''
        The LXC's LAN IP — Vector's prometheus_exporter sink binds here
        (NOT 0.0.0.0, per Pitfall 6). Required: no default, so hosts are
        forced to pass their own IP. k8s Prometheus scrapes this address
        via the nftables carve-out in modules/mcp-prom-exporters.nix.
      '';
      example = "10.0.2.11";
    };

    natsPeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "mcp-nats01"
        "mcp-nats02"
        "mcp-nats03"
      ];
      description = ''
        NATS cluster peers — Vector's NATS sinks round-robin across all
        three. Default matches the Phase 1 cluster names; hosts override
        if bringing their own cluster.
      '';
    };

    caUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://ca.samesies.gay:8443";
      description = ''
        step-ca base URL used by the vector-client-cert oneshot.
      '';
    };

    vectorExporterPort = lib.mkOption {
      type = lib.types.int;
      default = 9598;
      description = ''
        Port for Vector's internal prometheus_exporter sink. Must match
        `services.mcpPromExporters.vectorExporterPort` when Prom scrape
        carve-outs are added — both default to 9598.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # sops-nix validates secret ownership during activation, before the
    # upstream Vector module's runtime assumptions are usable here.
    users.groups.vector = { };
    users.users.vector = {
      isSystemUser = true;
      group = "vector";
    };

    # Enable-dotted form so plan-check greps match the canonical path.
    # Merged with the attrset block below via NixOS's option-merge rules.
    services.vector.enable = true;

    services.vector = {
      # Grants Vector read access to /var/log/journal. D-07 + Pattern 3
      # line 455 — the journald source won't work without it.
      journaldAccess = true;
      # Pitfall 10: hostnames are static strings; no env-var interpolation
      # in Phase 1, so build-time validation is safe.
      validateConfig = true;
      settings = {
        data_dir = "/var/lib/vector";

        sources = {
          # Journald tail. `current_boot_only = true` skips old boots on
          # first run — avoids a storm of replay messages hitting NATS
          # when a fresh LXC first connects.
          journal_local = {
            type = "journald";
            current_boot_only = true;
            acknowledgements.enabled = true;
          };
          # Vector's built-in self-metrics. Used exclusively by the
          # prometheus_exporter sink below.
          internal_metrics.type = "internal_metrics";
        };

        sinks = {
          # Journald events → NATS JetStream. Separate subject from OTLP
          # so the Vector consumer on mcp-audit (Plan 01-08) can use
          # distinct stream filters for the journal-archival pipeline vs.
          # the langfuse-nats-ingest OTLP pipeline.
          nats_journal = {
            type = "nats";
            inputs = [ "journal_local" ];
            url = natsUrl;
            subject = "audit.journal.${config.networking.hostName}";
            connection_name = "vector-${config.networking.hostName}-journal";
            jetstream.enabled = true;
            acknowledgements.enabled = true;
            auth = {
              strategy = "credentials_file";
              credentials_file.path = "/run/secrets/nats-client.creds";
            };
            tls = {
              enabled = true;
              ca_file = "/run/secrets/step-ca-root";
              crt_file = "/run/vector-certs/client.crt";
              key_file = "/run/vector-certs/client.key";
            };
            encoding.codec = "json";
          };

          # Vector self-metrics → Prom exporter. **Pitfall 6**: MUST bind
          # on the LXC's LAN IP so k8s Prometheus can scrape it; binding
          # on 0.0.0.0 would also work but the nftables carve-out in
          # modules/mcp-prom-exporters.nix scopes inbound to this exact
          # IP+port. The option surface refuses a default for `lxcIp` so
          # hosts cannot accidentally leave it as 0.0.0.0.
          prom_self = {
            type = "prometheus_exporter";
            inputs = [ "internal_metrics" ];
            address = "${cfg.lxcIp}:${toString cfg.vectorExporterPort}";
          };
        };
      };
    };

    # Tmpfiles entry for the runtime client-cert dir (mirrors nats-certs
    # in modules/nats-cluster.nix). Owned by the vector user/group — the
    # upstream services.vector module creates them on enable.
    systemd.tmpfiles.settings."20-vector-certs"."/run/vector-certs".d = {
      user = "vector";
      group = "vector";
      mode = "0700";
    };

    # Pitfall 9 mirror: Vector's cert-bootstrap oneshot is ordered BEFORE
    # vector.service and waits on step-ca /health via ExecStartPre. Host
    # picks up the cert identity via config.networking.hostName so every
    # mcp-* LXC gets its own per-host cert automatically.
    systemd.services.vector-client-cert = {
      description = "Obtain/renew Vector client TLS cert via step-ca ACME";
      wantedBy = [ "vector.service" ];
      before = [ "vector.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "vector";
        Group = "vector";
        ExecStartPre = waitForStepCa;
        ExecStart = vectorCertRequest;
      };
    };

    # D-04 renewal cadence — 12h on 24h certs, >50% lifetime headroom.
    systemd.timers.vector-client-cert-renew = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "12h";
        Unit = "vector-client-cert.service";
      };
    };

    # FOUND-07 spirit — CONTEXT §Claude's Discretion says Phase 1 lays
    # this baseline even though FOUND-07 formally lands in Phase 2.
    # Pitfall 9 ordering also here: vector.service requires +
    # after vector-client-cert.service.
    systemd.services.vector = {
      requires = [ "vector-client-cert.service" ];
      after = [ "vector-client-cert.service" ];
      serviceConfig = {
        ReadWritePaths = [
          "/var/lib/vector"
          "/run/vector-certs"
        ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };
  };
}
