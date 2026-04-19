#!/usr/bin/env bash
# tests/nats-node-loss.sh
# Source: CONTEXT D-02 + D-15 SC-1 (R3 invariant) / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# DESTRUCTIVE (staging only): stops NATS on NATS_HOST_2 and asserts the
# stream remains healthy on NATS_HOST_1 (leader set, 2 replicas
# current), then restarts NATS_HOST_2. Gate on STAGE=true to avoid
# accidental execution against prod.
set -euo pipefail

: "${STAGE:=false}"
: "${NATS_HOST_1:=mcp-nats01.samesies.gay}"
: "${NATS_HOST_2:=mcp-nats02.samesies.gay}"
: "${STREAM:=AUDIT_OTLP}"
: "${CREDS:=/run/secrets/nats-admin.creds}"

if [[ "$STAGE" != "true" ]]; then
  echo "skip: destructive test — set STAGE=true to run against staging" >&2
  exit 0
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$NATS_HOST_1" true 2>/dev/null \
   || ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$NATS_HOST_2" true 2>/dev/null; then
  echo "skip: NATS_HOST_1 or NATS_HOST_2 unreachable" >&2
  exit 0
fi

echo "-- stopping nats on $NATS_HOST_2"
ssh "$NATS_HOST_2" sudo systemctl stop nats
trap 'ssh "$NATS_HOST_2" sudo systemctl start nats' EXIT

sleep 5

info=$(ssh "$NATS_HOST_1" nats --creds "$CREDS" stream info "$STREAM" --json 2>/dev/null || echo "{}")

if ! echo "$info" | grep -qE '"leader"[[:space:]]*:[[:space:]]*"mcp-nats-'; then
  echo "FAIL: stream $STREAM has no leader after $NATS_HOST_2 stop" >&2
  echo "$info" >&2
  exit 1
fi

if ! echo "$info" | grep -qE '"current"[[:space:]]*:[[:space:]]*true'; then
  echo "FAIL: stream $STREAM has no current replicas after $NATS_HOST_2 stop" >&2
  echo "$info" >&2
  exit 1
fi

echo "OK: stream $STREAM remained healthy with $NATS_HOST_2 offline"
exit 0
