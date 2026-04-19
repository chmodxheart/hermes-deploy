# ROADMAP.md — Phase 1 close diff (D-15)

> Source: `.planning/phases/01-audit-substrate/01-CONTEXT.md` §D-15.
> Applied by `/gsd-transition` after Phase 1 verification.
> Target file: `.planning/ROADMAP.md`

## Context

The architectural pivot to a NATS substrate (vs. the original
direct-OTLP-to-Langfuse plan) materially changes what Phase 1 ships.
The existing Phase 1 goal and success criteria still describe the
pre-pivot scope; this diff expands the goal to match what was actually
built and adds four NATS-focused success criteria so Phase 2's
fail-closed-on-audit-unreachable posture has concrete invariants to
verify.

## Unified diff

```diff
--- a/.planning/ROADMAP.md
+++ b/.planning/ROADMAP.md
@@
-- [ ] **Phase 1: Audit substrate** - Stand up `mcp-audit` LXC with Langfuse v3, OTel collector, mTLS journald-remote, ClickHouse TTL, one-way nftables
+- [ ] **Phase 1: Audit substrate** - Stand up the audit substrate: 3-node NATS/JetStream cluster (R3, account JWT, mTLS via step-ca) plus `mcp-audit` LXC (Langfuse v3, OTLP→Langfuse bridge, ClickHouse TTL, one-way nftables posture)
@@
 ### Phase 1: Audit substrate
-**Goal**: Stand up the observability sink that every subsequent component emits to, so the gateway's fail-closed-on-writes-when-audit-unreachable posture has something to fail against from day one.
+**Goal**: Stand up the audit substrate — a durable, highly-available event fabric (NATS/JetStream cluster) plus its sink (Langfuse v3) — so every subsequent component publishes via the same substrate and the gateway's fail-closed-on-writes-when-audit-unreachable posture has something to fail against from day one.
 **Depends on**: Nothing (first phase)
 **Requirements**: AUDIT-01, AUDIT-02, AUDIT-03, AUDIT-04, AUDIT-05, FOUND-06
 **Success Criteria** (what must be TRUE):
@@
   6. A PBS restore of `mcp-audit` to a staging ID does NOT contain `/run`, `/var/run`, `/proc`, `/sys`, `/dev`, `/tmp`, or `/var/cache`, and the restored host requires sops re-decrypt to boot
+  7. 3-node NATS cluster is healthy; R3 stream `AUDIT_OTLP` survives loss of one Proxmox node (leader election completes within 10s, no messages dropped)
+  8. Anonymous NATS publish is rejected (`allow_anonymous = false`); only signed account JWT credentials are accepted
+  9. An OTLP span published via Vector on any audit-plane LXC arrives in Langfuse within 2s end-to-end (NATS → `langfuse-nats-ingest` → Langfuse OTLP)
+  10. `systemctl restart nats` on any single LXC causes zero dropped messages (JetStream buffers; durable consumer acks resume post-restart)
```

## Plan checkbox flips (separate edit, also applied by `/gsd-transition`)

Every `- [ ]` on lines 37-45 that points at a Phase-1 plan number
whose phase-close summary exists should flip to `- [x]`. Phase 1 ships
9 completed plans (01-01 through 01-09); after verification all 9
become `[x]`.
