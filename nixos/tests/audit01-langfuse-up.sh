#!/usr/bin/env bash
# tests/audit01-langfuse-up.sh
# Source: AUDIT-01 / CONTEXT D-15 SC-1 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# SSH port-forwards Langfuse web (3000) and asserts /api/public/health
# returns HTTP 200. Skips cleanly (exit 0) when STAGE_HOST is unreachable
# so CI in a no-host workspace passes.
set -euo pipefail

: "${STAGE_HOST:=mcp-audit.samesies.gay}"
: "${TUNNEL_PORT:=13000}"

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$STAGE_HOST" true 2>/dev/null; then
  echo "skip: $STAGE_HOST unreachable" >&2
  exit 0
fi

ssh -f -N -o ExitOnForwardFailure=yes -L "${TUNNEL_PORT}:127.0.0.1:3000" "$STAGE_HOST"
trap 'pkill -f "ssh -f -N .* ${TUNNEL_PORT}:127.0.0.1:3000" 2>/dev/null || true' EXIT

code=""
for _ in $(seq 1 15); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${TUNNEL_PORT}/api/public/health" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    echo "OK: langfuse /api/public/health -> 200"
    exit 0
  fi
  sleep 2
done

echo "FAIL: langfuse /api/public/health last=${code}" >&2
exit 1
