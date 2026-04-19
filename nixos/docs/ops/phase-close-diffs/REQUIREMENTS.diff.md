# REQUIREMENTS.md — Phase 1 close diff (D-15)

> Source: `.planning/phases/01-audit-substrate/01-CONTEXT.md` §D-15.
> Applied by `/gsd-transition` after Phase 1 verification.
> Target file: `.planning/REQUIREMENTS.md`

## Context

Two rewrites and 8 additions. AUDIT-03 and AUDIT-04 were written
pre-NATS-pivot (direct OTLP/HTTP + journald-remote + mTLS on
journald-remote); they now need to describe the NATS path actually
shipped. NATS-01..05 codify the cluster as a requirement (it exists
today on the strength of Plans 01-05/06; the cross-phase reference
needs the requirement ID to point at). OBS-01..03 codify the metrics
plane (Prometheus + Grafana) that Phase 1 stood up alongside the
audit plane.

## Unified diff

```diff
--- a/.planning/REQUIREMENTS.md
+++ b/.planning/REQUIREMENTS.md
@@
 ### Audit substrate (mcp-audit)
 
 - [ ] **AUDIT-01** → Phase 1: Dedicated `mcp-audit` LXC running self-hosted Langfuse v3 (web + worker + Postgres-17 + ClickHouse-25.8 + Redis-7.2; MinIO deferred); LXC sized ≥4 cores, ≥8 GB RAM
 - [ ] **AUDIT-02** → Phase 1: ClickHouse `TTL` configured at deploy time on traces/observations/scores/event_log tables (default 90d for traces, 30d for event_log); disk-utilization alert at 70%
-- [ ] **AUDIT-03** → Phase 1: Audit ingress is one-way only — gateway and every MCP push (OTLP/HTTP on 4318, journald-remote on 19532); the hermes LXC and operator workstations have **no** inbound network reach to mcp-audit (verified by nftables ruleset)
-- [ ] **AUDIT-04** → Phase 1: mTLS on the journald-remote ingress (per-MCP client cert; server requires client-cert verify); plain HTTP rejected
-- [ ] **AUDIT-05** → Phase 1: OpenTelemetry GenAI semconv emission from gateway AND every MCP wrapper, via shared `modules/mcp-otel.nix`; `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental` and `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` set declaratively
+- [ ] **AUDIT-03** → Phase 1: Audit ingress is one-way only — gateway and every MCP publish to NATS TLS 4222 with account JWT auth; subject hierarchy `audit.otlp.*` (spans) and `audit.journal.*` (journald). The hermes LXC has **no** inbound network reach to any audit-plane LXC (verified by the `assert-no-hermes-reach` flake-check against every rendered nftables table)
+- [ ] **AUDIT-04** → Phase 1: NATS mTLS via step-ca (24h short-lived certs); anonymous NATS connects are rejected (`allow_anonymous = false`); per-account JWT enforced via `resolver.type = full` (verified by the `nats-no-anonymous` flake-check)
+- [ ] **AUDIT-05** → Phase 1: OpenTelemetry GenAI semconv emission from gateway AND every MCP wrapper, via shared `modules/mcp-otel.nix`; `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental` and `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` set declaratively; `OTEL_EXPORTER_OTLP_ENDPOINT` points at the local Vector client, which forwards over NATS to `langfuse-nats-ingest` on `mcp-audit`
+
+### NATS substrate
+
+- [ ] **NATS-01** → Phase 1: 3-LXC NATS/JetStream cluster (`mcp-nats-1,2,3`), R3 streams, one LXC pinned per Proxmox node; file-backed storage on Ceph; declarative via `modules/nats-cluster.nix`
+- [ ] **NATS-02** → Phase 1: Operator + accounts + users via `nsc`; JWT + NKey auth; declarative `modules/nats-accounts.nix` materialises the operator JWT and resolver.conf at deploy time; `/run/secrets/nats-*.creds` provisioned per consumer/publisher
+- [ ] **NATS-03** → Phase 1: step-ca internal CA (co-located on `mcp-audit`) issues 24h ACME certs; no static TLS certs in the repo; cert-bootstrap oneshots renew automatically
+- [ ] **NATS-04** → Phase 1: `allow_anonymous = false` at the server; pub/sub ACLs per account (vector-publisher can only publish to `audit.>`; langfuse-ingest can only subscribe under the `AuditAccount`); enforced by the resolver block
+- [ ] **NATS-05** → Phase 1: Vector runs on every audit-plane LXC — OTel source + journald source → NATS sinks; certs bootstrapped from step-ca; mTLS client auth required for NATS publish
+
+### Observability plane
+
+- [ ] **OBS-01** → Phase 1: `node_exporter` + service-specific exporters on every audit-plane LXC; k8s Prometheus scrapes over a narrow nftables carve-out (single source IP per `modules/mcp-prom-exporters.nix`)
+- [ ] **OBS-02** → Phase 1: Grafana dashboards committed as code under `docs/ops/grafana/*.json` with provisioning README; one dashboard per data source (NATS JetStream, ClickHouse, Postgres, Langfuse, node metrics, Vector pipeline)
+- [ ] **OBS-03** → Phase 1: Prometheus alerting rule mirrors the Langfuse disk-WARN threshold (70%) for pager-style alerting; the nixos-side journald WARN (`mcp-audit-disk-check`) is the primary signal, the Prom rule is the redundant pager path
 
 ### Gateway (mcp-gateway)
```

## Traceability table addendum

```diff
--- a/.planning/REQUIREMENTS.md
+++ b/.planning/REQUIREMENTS.md
@@
 | 1. Audit substrate | AUDIT-01, AUDIT-02, AUDIT-03, AUDIT-04, AUDIT-05, FOUND-06 | 6 |
+| 1. Audit substrate (NATS) | NATS-01, NATS-02, NATS-03, NATS-04, NATS-05 | 5 |
+| 1. Audit substrate (observability) | OBS-01, OBS-02, OBS-03 | 3 |
```

## Status matrix addendum

```diff
--- a/.planning/REQUIREMENTS.md
+++ b/.planning/REQUIREMENTS.md
@@
 | AUDIT-03 | 1 | Pending |
 | AUDIT-04 | 1 | Pending |
 | AUDIT-05 | 1 | Pending |
+| NATS-01  | 1 | Pending |
+| NATS-02  | 1 | Pending |
+| NATS-03  | 1 | Pending |
+| NATS-04  | 1 | Pending |
+| NATS-05  | 1 | Pending |
+| OBS-01   | 1 | Pending |
+| OBS-02   | 1 | Pending |
+| OBS-03   | 1 | Pending |
```

The `Pending` → `Completed` flip happens after Phase 1 verification
(`/gsd-verify-work`) confirms each requirement is satisfied.
