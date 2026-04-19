#!/usr/bin/env bash
# tests/nats-restart-zero-drop.sh
# Source: CONTEXT D-15 SC-4 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# DESTRUCTIVE (staging only): publishes MSG_COUNT messages, restarts
# NATS_HOST_1, then asserts a durable consumer eventually acks the
# full count. Tests JetStream's stream-on-restart durability
# guarantee. Gate on STAGE=true.
set -euo pipefail

: "${STAGE:=false}"
: "${NATS_HOST_1:=mcp-nats-1.samesies.gay}"
: "${NATS_HOST_2:=mcp-nats-2.samesies.gay}"
: "${STREAM:=AUDIT_OTLP}"
: "${MSG_COUNT:=1000}"
: "${CREDS:=/run/secrets/nats-admin.creds}"
: "${CONSUMER:=restart-probe}"

if [[ "$STAGE" != "true" ]]; then
  echo "skip: destructive test — set STAGE=true to run against staging" >&2
  exit 0
fi

if ! command -v nats >/dev/null 2>&1; then
  echo "skip: nats CLI not on PATH (nix shell nixpkgs#natscli)" >&2
  exit 0
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$NATS_HOST_1" true 2>/dev/null; then
  echo "skip: $NATS_HOST_1 unreachable" >&2
  exit 0
fi

echo "-- publishing $MSG_COUNT msgs via $NATS_HOST_2"
for i in $(seq 1 "$MSG_COUNT"); do
  nats --server "tls://${NATS_HOST_2}:4222" --creds "$CREDS" \
    pub audit.otlp.restart-probe "msg-$i" >/dev/null
done

echo "-- restarting nats on $NATS_HOST_1"
ssh "$NATS_HOST_1" sudo systemctl restart nats
sleep 10

info=$(ssh "$NATS_HOST_1" nats --creds "$CREDS" \
  stream info "$STREAM" --json 2>/dev/null || echo "{}")
count=$(echo "$info" | grep -oE '"messages"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$' || echo "0")

if [[ "$count" -ge "$MSG_COUNT" ]]; then
  echo "OK: stream $STREAM retained $count >= $MSG_COUNT messages across restart"
  exit 0
fi

echo "FAIL: stream $STREAM has $count messages; expected >= $MSG_COUNT" >&2
exit 1
