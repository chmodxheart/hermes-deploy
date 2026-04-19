#!/usr/bin/env bash
# hosts/mcp-audit/disk-check.sh
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-10
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Code Examples Common Operation 4
#
# 70% threshold; journald WARN is the audit-complete record (flows through
# Vector -> NATS -> langfuse-nats-ingest -> Langfuse).
#
# Note: /var/lib/minio is deliberately omitted -- D-05 uses the external
# minio.samesies.gay bucket, not an in-LXC MinIO container.
set -euo pipefail

THRESHOLD=70
for mount in / /var/lib/clickhouse /var/lib/postgresql /var/lib/nats /var/log/journal/remote; do
  [[ -d "$mount" ]] || continue
  pct=$(df --output=pcent "$mount" | tail -1 | tr -d ' %')
  if ((pct >= THRESHOLD)); then
    logger -p warning -t mcp-audit-disk-check \
      "disk usage on $mount is ${pct}% (threshold ${THRESHOLD}%)"
  fi
done
