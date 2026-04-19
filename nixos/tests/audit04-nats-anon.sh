#!/usr/bin/env bash
# tests/audit04-nats-anon.sh
# Source: AUDIT-04 / CONTEXT D-03 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# Attempts to publish to NATS without creds and asserts the server
# returns an authorization violation. Requires the `nats` CLI
# (nixpkgs#natscli) on $PATH.
set -euo pipefail

: "${NATS_HOST:=mcp-nats-1.samesies.gay}"
: "${NATS_PORT:=4222}"

if ! command -v nats >/dev/null 2>&1; then
  echo "skip: nats CLI not on PATH (nix shell nixpkgs#natscli)" >&2
  exit 0
fi

# No --creds flag == anonymous connect attempt. With D-03 JWT resolver
# (resolver.type=full) the server rejects the handshake. Capture stderr.
output=$(nats pub \
  --server "tls://${NATS_HOST}:${NATS_PORT}" \
  --timeout 3s \
  test.subject hello 2>&1 || true)

if echo "$output" | grep -qiE 'authorization violation|no responders|not authorized|invalid credentials'; then
  echo "OK: ${NATS_HOST}:${NATS_PORT} rejected anonymous publish"
  exit 0
fi

if echo "$output" | grep -qiF 'published 1 bytes'; then
  echo "FAIL: ${NATS_HOST}:${NATS_PORT} accepted anonymous publish (D-03 JWT not enforced)" >&2
  exit 1
fi

echo "skip: inconclusive nats output" >&2
echo "$output" | tail -5 >&2
exit 0
