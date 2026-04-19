#!/usr/bin/env bash
# tests/audit02-prom-alert.sh
# Source: CONTEXT D-10 secondary path (Prom mirror) / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# Queries Prometheus for the MCPAuditDiskHigh alert rule. Success
# semantics: the rule must EXIST (visible via /api/v1/rules); whether
# it is currently firing is separate (a firing alert is not a test
# failure — it is a real disk-high condition).
set -euo pipefail

: "${PROM_API_URL:=https://prometheus.samesies.gay/api/v1}"
: "${PROM_TOKEN:=REPLACE_ME}"

if [[ "$PROM_TOKEN" == "REPLACE_ME" ]]; then
  echo "skip: PROM_TOKEN not set (export the Prometheus bearer token to run)" >&2
  exit 0
fi

body=$(curl -fsS -H "Authorization: Bearer $PROM_TOKEN" \
  "$PROM_API_URL/rules" 2>/dev/null || echo "")

if [[ -z "$body" ]]; then
  echo "skip: unable to reach $PROM_API_URL/rules" >&2
  exit 0
fi

if echo "$body" | grep -qF 'MCPAuditDiskHigh'; then
  echo "OK: MCPAuditDiskHigh rule is registered on $PROM_API_URL"
  exit 0
fi

echo "FAIL: MCPAuditDiskHigh rule not found in $PROM_API_URL/rules" >&2
exit 1
