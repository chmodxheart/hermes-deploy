#!/usr/bin/env bash
# tests/audit03-hermes-probe.sh
# Source: AUDIT-03 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# Live-traffic check of the D-11 one-way posture: from the hermes LXC,
# attempt to dial the audit plane's NATS client port and expect
# connection refused/timeout (not established). The firewall flake-check
# (assert-no-hermes-reach) already verifies the declarative side; this
# probe catches kernel/runtime drift. NATS 4222 is the load-bearing port
# — hermes publishing to NATS would violate D-11.
set -euo pipefail

: "${HERMES_HOST:=hermes.samesies.gay}"
: "${TARGET_HOST:=mcp-nats01.samesies.gay}"
: "${TARGET_PORT:=4222}"

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$HERMES_HOST" true 2>/dev/null; then
  echo "skip: $HERMES_HOST unreachable" >&2
  exit 0
fi

# /dev/tcp probe times out in ~3s on closed port; we want that.
# TARGET_HOST/PORT are intentionally expanded client-side before SSH.
# shellcheck disable=SC2029
if ssh "$HERMES_HOST" \
     "timeout 3 bash -c '</dev/tcp/${TARGET_HOST}/${TARGET_PORT}' 2>&1" >/dev/null; then
  echo "FAIL: TCP connect from $HERMES_HOST -> ${TARGET_HOST}:${TARGET_PORT} SUCCEEDED (D-11 one-way posture violated)" >&2
  exit 1
fi

echo "OK: TCP connect from $HERMES_HOST -> ${TARGET_HOST}:${TARGET_PORT} refused/timed out"
exit 0
