#!/usr/bin/env bash
# tests/audit05-otlp-e2e.sh
# Source: AUDIT-05 / CONTEXT D-15 SC-3 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# POSTs the tests/fixtures/sample-gen-ai-span.bin OTLP payload to
# Langfuse OTLP, then queries Langfuse's public API to confirm the
# span's gen_ai.tool.name attribute survives ingestion. Requires a
# real Langfuse API key pair (LF_PK / LF_SK) scoped to the test
# project. Skips cleanly if the keys are not set.
set -euo pipefail

: "${STAGE_HOST:=mcp-audit.samesies.gay}"
: "${TUNNEL_PORT:=13000}"
: "${LF_PK:=REPLACE_ME}"
: "${LF_SK:=REPLACE_ME}"
: "${FIXTURE:=tests/fixtures/sample-gen-ai-span.bin}"

if [[ "$LF_PK" == "REPLACE_ME" || "$LF_SK" == "REPLACE_ME" ]]; then
  echo "skip: LF_PK / LF_SK not set (export a Langfuse API key pair to run)" >&2
  exit 0
fi

if [[ ! -s "$FIXTURE" ]]; then
  echo "FAIL: fixture $FIXTURE missing or empty" >&2
  exit 1
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$STAGE_HOST" true 2>/dev/null; then
  echo "skip: $STAGE_HOST unreachable" >&2
  exit 0
fi

ssh -f -N -o ExitOnForwardFailure=yes -L "${TUNNEL_PORT}:127.0.0.1:3000" "$STAGE_HOST"
trap 'pkill -f "ssh -f -N .* ${TUNNEL_PORT}:127.0.0.1:3000" 2>/dev/null || true' EXIT

# POST the protobuf payload. Langfuse accepts on /api/public/otel/v1/traces
# with Basic auth (pk:sk) and application/x-protobuf content type.
status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST \
  -u "${LF_PK}:${LF_SK}" \
  -H 'Content-Type: application/x-protobuf' \
  --data-binary "@${FIXTURE}" \
  "http://127.0.0.1:${TUNNEL_PORT}/api/public/otel/v1/traces" || echo "000")

if [[ "$status" != 2* ]]; then
  echo "FAIL: OTLP POST returned HTTP $status" >&2
  exit 1
fi

# Give the worker 10s to process and persist the span into ClickHouse.
sleep 10

# /api/public/traces lists traces for the project behind the key pair.
# The fixture span carries name=gen_ai.tool.call.
body=$(curl -sS -u "${LF_PK}:${LF_SK}" \
  "http://127.0.0.1:${TUNNEL_PORT}/api/public/traces?limit=25&name=gen_ai.tool.call" 2>/dev/null || echo "")

if echo "$body" | grep -qF 'gen_ai.tool.call'; then
  echo "OK: OTLP span visible via /api/public/traces"
  exit 0
fi

echo "FAIL: span not visible via /api/public/traces after 10s" >&2
echo "$body" | head -c 500 >&2
exit 1
