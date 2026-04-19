#!/usr/bin/env bash
# tests/audit02-ttl.sh
# Source: AUDIT-02 / CONTEXT D-09 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# Asserts ClickHouse trace/observation/score/event_log tables carry the
# D-09 TTLs (90 DAY / 90 DAY / 365 DAY / 30 DAY). Skips cleanly when
# STAGE_HOST is unreachable.
set -euo pipefail

: "${STAGE_HOST:=mcp-audit.samesies.gay}"

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$STAGE_HOST" true 2>/dev/null; then
  echo "skip: $STAGE_HOST unreachable" >&2
  exit 0
fi

# (table, expected TTL fragment)
declare -A expected=(
  [traces]="INTERVAL 90 DAY"
  [observations]="INTERVAL 90 DAY"
  [scores]="INTERVAL 365 DAY"
  [event_log]="INTERVAL 30 DAY"
)

fail=0
for table in "${!expected[@]}"; do
  ddl=$(ssh "$STAGE_HOST" \
    clickhouse-client --user langfuse --database langfuse \
      --query "\"SHOW CREATE TABLE $table\"" 2>/dev/null || echo "")
  if echo "$ddl" | grep -qF "${expected[$table]}"; then
    echo "OK: $table carries '${expected[$table]}' TTL"
  else
    echo "FAIL: $table missing '${expected[$table]}' TTL" >&2
    fail=1
  fi
done
exit "$fail"
