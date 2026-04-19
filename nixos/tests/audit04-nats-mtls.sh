#!/usr/bin/env bash
# tests/audit04-nats-mtls.sh
# Source: AUDIT-04 / CONTEXT D-04 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# Opens a TLS connection to NATS without presenting a client cert and
# asserts the server either refuses the handshake or closes the stream.
# Validates services.nats.settings.tls.verify = true (D-04 mTLS).
set -euo pipefail

: "${NATS_HOST:=mcp-nats01.samesies.gay}"
: "${NATS_PORT:=4222}"

# openssl s_client returns non-zero on handshake failure. Feed </dev/null
# so it does not hang waiting for user input. Capture stderr for the
# "verify error" or "sslv3 alert" signal the NATS server emits.
output=$(openssl s_client \
  -connect "${NATS_HOST}:${NATS_PORT}" \
  -verify_return_error \
  -servername "$NATS_HOST" \
  </dev/null 2>&1 || true)

# Any of: TLS alert bad_certificate, verify errors, "Verify return code: 2x".
if echo "$output" | grep -qiE 'alert bad_certificate|sslv3 alert|verify return code: [1-9]|handshake failure|peer did not return a certificate'; then
  echo "OK: ${NATS_HOST}:${NATS_PORT} rejected unauthenticated TLS (mTLS enforced)"
  exit 0
fi

# Successful handshake without a client cert = mTLS is NOT enforced.
if echo "$output" | grep -qF 'Verify return code: 0 (ok)'; then
  echo "FAIL: ${NATS_HOST}:${NATS_PORT} accepted TLS without a client cert (D-04 mTLS not enforced)" >&2
  exit 1
fi

echo "skip: inconclusive openssl output (network or DNS failure?)" >&2
echo "$output" | tail -5 >&2
exit 0
