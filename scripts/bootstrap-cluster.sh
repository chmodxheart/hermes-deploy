#!/usr/bin/env bash
# scripts/bootstrap-cluster.sh
#
# Single-command cluster bring-up. Handles the two-phase bootstrap required
# because mcp-audit hosts step-ca (needed by NATS hosts for cert issuance)
# and later needs NATS credentials (generated after NATS is running).
#
# Phases:
#   1. Pre-flight:   validate all tools and required secrets are present/filled
#   2. mcp-audit-p1: deploy mcp-audit WITHOUT Vector (no NATS creds yet)
#                    step-ca comes up; NATS hosts can now get certs
#   3. NATS cluster: deploy mcp-nats01/02/03 serially
#   4. Readiness:    wait for NATS cluster to be healthy
#   5. mcp-audit-p2: re-deploy mcp-audit WITH Vector (nats_client_creds required)
#
# Phase 5 is skipped with a clear message if nats_client_creds still contains
# a placeholder — the operator must run `nsc`, populate the sops secret, and
# re-run this script (or just `bootstrap-host.sh mcp-audit` with the full
# `mcp-audit` flake target).
#
# Prereqs on PATH: sops, python3, nix, ssh, curl.
# Prereqs in env: SOPS_AGE_KEY_FILE (workstation age key).

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
nixos_root="$repo_root/nixos"
secrets_dir="$nixos_root/secrets"

bootstrap="$script_dir/bootstrap-host.sh"

domain="${MCP_DOMAIN:-samesies.gay}"
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

NATS_HOSTS=(mcp-nats01 mcp-nats02 mcp-nats03)
STEP_CA_URL="https://ca.${domain}:8443/health"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[bootstrap-cluster] $*"; }
ok()   { echo "[bootstrap-cluster] ✓ $*"; }
fail() { echo "[bootstrap-cluster] ✗ $*" >&2; exit 1; }
step() { echo; echo "══════════════════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════════════════"; }

# Decrypt a single key from a sops yaml and print its value.
sops_get() {
  local file="$1" key="$2"
  sops --decrypt "$file" \
    | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('${key}',''), end='')"
}

# Return 0 if a sops key contains no REPLACE_ME placeholder.
sops_key_filled() {
  local file="$1" key="$2"
  local val
  val="$(sops_get "$file" "$key")"
  [[ -n "$val" && "$val" != *REPLACE_ME* ]]
}

wait_for_step_ca() {
  log "waiting for step-ca at $STEP_CA_URL ..."
  local attempts=60
  for _ in $(seq 1 "$attempts"); do
    if curl -sk --max-time 3 "$STEP_CA_URL" | grep -q '"status":"ok"' 2>/dev/null; then
      ok "step-ca is healthy"
      return 0
    fi
    sleep 5
  done
  fail "step-ca did not become healthy after $((attempts * 5))s"
}

wait_for_nats() {
  local host="$1"
  log "waiting for NATS on $host ..."
  local attempts=30
  for _ in $(seq 1 "$attempts"); do
    if ssh -o BatchMode=yes -o ConnectTimeout=3 "root@${host}.${domain}" \
        'systemctl is-active nats.service' 2>/dev/null | grep -q '^active$'; then
      ok "NATS active on $host"
      return 0
    fi
    sleep 5
  done
  fail "NATS did not become active on $host after $((attempts * 5))s"
}

# ---------------------------------------------------------------------------
# Phase 0: Pre-flight
# ---------------------------------------------------------------------------

step "Phase 0: pre-flight checks"

[[ -f "$nixos_root/flake.nix" ]] || fail "not in expected repo structure (missing nixos/flake.nix)"
[[ -f "$SOPS_AGE_KEY_FILE" ]]    || fail "SOPS_AGE_KEY_FILE not found: $SOPS_AGE_KEY_FILE"

for bin in sops python3 nix ssh curl; do
  command -v "$bin" >/dev/null 2>&1 || fail "'$bin' not on PATH"
done

# Verify secrets files exist (not just examples)
for host in mcp-audit mcp-nats01 mcp-nats02 mcp-nats03; do
  f="$secrets_dir/${host}.yaml"
  [[ -f "$f" ]] || fail "missing secrets file: $f  (copy from .example and fill values)"
done
[[ -f "$secrets_dir/nats-operator.yaml" ]] \
  || fail "missing secrets/nats-operator.yaml (run nsc bootstrap first)"

# Verify critical mcp-audit secrets are filled
for key in step_ca_intermediate_pw postgres_password clickhouse_password redis_password; do
  sops_key_filled "$secrets_dir/mcp-audit.yaml" "$key" \
    || fail "mcp-audit.yaml: '$key' still contains a placeholder — fill it before bootstrapping"
done

# Verify nats hosts have their step-ca root populated
for host in mcp-nats01 mcp-nats02 mcp-nats03; do
  sops_key_filled "$secrets_dir/${host}.yaml" "step_ca_root_cert" \
    || fail "$host.yaml: 'step_ca_root_cert' still contains a placeholder — copy PEM from mcp-audit after its first deploy, or re-run this script once mcp-audit is up"
done

ok "all pre-flight checks passed"

# ---------------------------------------------------------------------------
# Phase 1: mcp-audit (without Vector — no NATS creds yet)
# ---------------------------------------------------------------------------

step "Phase 1: mcp-audit (phase-1 config — step-ca, Langfuse, no Vector)"

DEPLOY_USER=root "$bootstrap" mcp-audit mcp-audit-phase1

wait_for_step_ca

ok "mcp-audit phase-1 complete"

# ---------------------------------------------------------------------------
# Phase 2: NATS cluster (serial — each host needs step-ca for cert issuance)
# ---------------------------------------------------------------------------

step "Phase 2: NATS cluster (mcp-nats01 → 02 → 03, serial)"

for host in "${NATS_HOSTS[@]}"; do
  log "bootstrapping $host ..."
  DEPLOY_USER=root "$bootstrap" "$host"
  wait_for_nats "$host"
done

ok "NATS cluster bootstrapped"

# ---------------------------------------------------------------------------
# Phase 3: mcp-audit full config (with Vector) — requires NATS creds
# ---------------------------------------------------------------------------

step "Phase 3: mcp-audit (full config — Vector + NATS)"

if ! sops_key_filled "$secrets_dir/mcp-audit.yaml" "nats_client_creds"; then
  echo
  echo "  SKIPPED: nats_client_creds in secrets/mcp-audit.yaml still contains a placeholder."
  echo
  echo "  To complete the cluster bring-up:"
  echo "    1. Generate Vector's NATS user creds with nsc:"
  echo "         nsc add user -a AUDIT vector-audit --allow-pub 'audit.journal.>' --allow-sub '_INBOX.>'"
  echo "         nsc generate creds -a AUDIT -n vector-audit"
  echo "    2. Paste the output into secrets/mcp-audit.yaml key 'nats_client_creds':"
  echo "         sops $secrets_dir/mcp-audit.yaml"
  echo "    3. Re-run this script (or just: DEPLOY_USER=root $bootstrap mcp-audit)"
  echo
  exit 0
fi

DEPLOY_USER=root "$bootstrap" mcp-audit

ok "mcp-audit full config deployed — Vector is live"
echo
echo "Cluster bring-up complete."
