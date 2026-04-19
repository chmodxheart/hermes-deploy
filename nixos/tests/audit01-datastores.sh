#!/usr/bin/env bash
# tests/audit01-datastores.sh
# Source: AUDIT-01 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# Asserts postgresql, clickhouse, and redis-langfuse are active on the
# audit-sink host. Skips cleanly when STAGE_HOST is unreachable.
set -euo pipefail

: "${STAGE_HOST:=mcp-audit.samesies.gay}"

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$STAGE_HOST" true 2>/dev/null; then
  echo "skip: $STAGE_HOST unreachable" >&2
  exit 0
fi

# redis-langfuse is the NAMED instance from services.redis.servers.langfuse
# (P4 — nixpkgs materialises the unit as redis-<name>.service).
units=(postgresql.service clickhouse.service redis-langfuse.service)
fail=0
for unit in "${units[@]}"; do
  # $unit is intentionally expanded client-side before SSH.
  # shellcheck disable=SC2029
  if state=$(ssh "$STAGE_HOST" systemctl is-active "$unit" 2>/dev/null); then
    echo "OK: $unit is $state"
  else
    echo "FAIL: $unit is ${state:-unknown}" >&2
    fail=1
  fi
done
exit "$fail"
