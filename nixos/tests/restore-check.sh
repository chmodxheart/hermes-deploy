#!/usr/bin/env bash
# tests/restore-check.sh
# Source: FOUND-06 / CONTEXT D-12 / VALIDATION.md §Wave 0 Requirements
# Source: .planning/phases/01-audit-substrate/01-09-PLAN.md Wave 5
#
# DESTRUCTIVE (staging only): restores the most recent PBS snapshot
# of SRC_VMID into STAGE_VMID and asserts the excluded paths from
# modules/pbs-excludes.nix are empty in the restored filesystem. Also
# scans for common plaintext-secret markers to guard against a
# misconfigured exclude list. Gate on STAGE=true.
set -euo pipefail

: "${STAGE:=false}"
: "${STAGE_VMID:=99999}"
: "${SRC_VMID:?SRC_VMID required (the prod VMID to restore from)}"
: "${SNAPSHOT:=latest}"
: "${PBS_STORE:=pbs}"

if [[ "$STAGE" != "true" ]]; then
  echo "skip: destructive test — set STAGE=true to run against staging" >&2
  exit 0
fi

if ! command -v pct >/dev/null 2>&1 || ! command -v pvesm >/dev/null 2>&1; then
  echo "skip: pct/pvesm not on PATH (run on a Proxmox node)" >&2
  exit 0
fi

echo "-- restoring $SRC_VMID @ $SNAPSHOT -> $STAGE_VMID"
pct restore "$STAGE_VMID" \
  "${PBS_STORE}:backup/ct/${SRC_VMID}/${SNAPSHOT}" \
  --force 1 --start 0

# Mount the restored rootfs for offline inspection.
mount_point=$(pct mount "$STAGE_VMID" | awk '/mounted/{print $NF}')
trap 'pct unmount "$STAGE_VMID" 2>/dev/null || true; pct destroy "$STAGE_VMID" --force 1 2>/dev/null || true' EXIT

# D-12 excluded path set (FOUND-06 baseline from modules/pbs-excludes.nix).
excludes=(run var/run proc sys dev tmp var/cache run/secrets)

fail=0
for p in "${excludes[@]}"; do
  path="${mount_point}/${p}"
  if [[ -d "$path" ]] && [[ "$(find "$path" -mindepth 1 -print -quit 2>/dev/null || true)" != "" ]]; then
    echo "FAIL: excluded path $path is populated in restore" >&2
    fail=1
  fi
done

# Belt-and-suspenders: plaintext secret markers. Any match means
# /run/secrets or similar was captured despite the exclude.
if grep -rIl 'BEGIN OPENSSH PRIVATE KEY\|age-encryption\|LANGFUSE_PUBLIC_KEY' \
     "$mount_point" 2>/dev/null | head -5; then
  echo "FAIL: plaintext secret markers found in restore" >&2
  fail=1
fi

if [[ "$fail" == "0" ]]; then
  echo "OK: restored filesystem respects D-12 excludes; no plaintext secrets detected"
fi
exit "$fail"
