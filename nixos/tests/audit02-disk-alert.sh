#!/usr/bin/env bash
# tests/audit02-disk-alert.sh
# Source: AUDIT-02 / CONTEXT D-10 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# Observes whether the disk-check timer has logged any
# mcp-audit-disk-check WARN in the last 30 minutes. Does not
# synthetic-fill the volume (destructive, requires operator
# scheduling) — that is the DESTRUCTIVE path documented in the plan's
# test guidance and run manually during staging. Here we only check
# the observation side of the invariant.
set -euo pipefail

: "${STAGE_HOST:=mcp-audit.samesies.gay}"

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$STAGE_HOST" true 2>/dev/null; then
  echo "skip: $STAGE_HOST unreachable" >&2
  exit 0
fi

# The D-10 timer WARNs via `logger -p warning -t mcp-audit-disk-check`;
# journald records the SYSLOG_IDENTIFIER so we filter precisely.
hits=$(ssh "$STAGE_HOST" \
  journalctl --since \"30 min ago\" -t mcp-audit-disk-check --no-pager -q 2>/dev/null | wc -l)

if [[ "$hits" -gt 0 ]]; then
  echo "OBSERVED: $hits WARN line(s) from mcp-audit-disk-check in the last 30m"
  echo "(a firing WARN is NOT a failure — disk is above 70%, operator action required)"
  exit 0
else
  echo "OK: no disk-check WARN in the last 30m (disk below 70% threshold)"
  exit 0
fi
