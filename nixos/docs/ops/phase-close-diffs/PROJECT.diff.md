# PROJECT.md — Phase 1 close diff (D-15)

> Source: `.planning/phases/01-audit-substrate/01-CONTEXT.md` §D-15.
> Applied by `/gsd-transition` after Phase 1 verification.
> Target file: `.planning/PROJECT.md`

## Context

Two Key Decisions rows document choices that shaped Phase 1's
architecture and will shape every subsequent phase's assumptions.
They deserve a first-class entry in the decision table so future
readers don't have to reverse-engineer them from the audit-substrate
plan artifacts.

## Unified diff

```diff
--- a/.planning/PROJECT.md
+++ b/.planning/PROJECT.md
@@
 ## Key Decisions
 
 | Decision | Rationale | Outcome |
 |----------|-----------|---------|
+| NATS/JetStream is the audit substrate | Durability and HA of a message bus beat direct-HTTP-to-Langfuse for fail-closed posture; R3 stream + durable consumer means audit ingest survives a Langfuse outage without losing events. Dogfooding Synadia's product. Forward-compatible with future delegation / review-pipeline fabrics (agent-to-agent coordination over subject hierarchies, not custom RPC) | — Pending |
+| k8s Prometheus + Grafana scrape the audit plane for ops metrics; Langfuse remains the audit record | Separation of metrics-plane (how healthy is the substrate?) from audit-plane (what did agents do?). Prom dashboards are for oncall; Langfuse is for compliance and incident forensics. Prevents Langfuse ClickHouse from being weaponised as a metrics TSDB | — Pending |
 | One LXC per MCP, no co-location | LXC overhead is negligible on cluster; uniformity wins (PBS, NixOS template, observability); "trusted" MCPs can still emit attacker-controlled data | — Pending |
```

After Phase 1 verification, flip both new rows' `Outcome` columns
from `— Pending` to `— Implemented` (with a brief pointer to the
carrying artifact, e.g. `— Implemented (modules/nats-cluster.nix,
modules/mcp-audit.nix)`).
