#!/usr/bin/env bash
# tests/audit03-nft-assert.sh
# Source: AUDIT-03 / CONTEXT D-11 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# Reads the live kernel nftables ruleset on STAGE_HOST and asserts no
# accept rule sources from HERMES_IP. Complements the eval-time
# flake-check assert-no-hermes-reach by scanning the runtime ruleset
# (detects drift if someone hand-edits rules on the box).
set -euo pipefail

: "${STAGE_HOST:=mcp-audit.samesies.gay}"
: "${HERMES_IP:=10.0.1.91}"

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$STAGE_HOST" true 2>/dev/null; then
  echo "skip: $STAGE_HOST unreachable" >&2
  exit 0
fi

ruleset=$(ssh "$STAGE_HOST" sudo nft list ruleset 2>/dev/null || echo "")
if [[ -z "$ruleset" ]]; then
  echo "FAIL: empty ruleset (is nftables enabled on $STAGE_HOST?)" >&2
  exit 1
fi

# Match mcp-*/default.nix convention: saddr + hermes IP + accept on same line
# (or saddr containing the literal hermes IP in a set).
if echo "$ruleset" | grep -nF "$HERMES_IP" | grep -qE 'accept|saddr'; then
  echo "FAIL: $STAGE_HOST nftables references $HERMES_IP in accept/saddr context" >&2
  echo "$ruleset" | grep -nF "$HERMES_IP" >&2
  exit 1
fi

echo "OK: $STAGE_HOST nftables has no accept/saddr rule referencing $HERMES_IP"
exit 0
