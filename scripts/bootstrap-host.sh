#!/usr/bin/env bash
# scripts/bootstrap-host.sh <hostname>
#
# Idempotent deploy. On a fresh LXC: extracts the host's age privkey
# from secrets/host-sops-keys.yaml and pushes it to /var/lib/sops-nix/
# on the target via sudo. On an already-configured LXC: skips the key
# push. In both cases, runs `nixos-rebuild switch --target-host`
# against the given host.
#
# Invoked by terraform/main.tf, or directly by the operator.
#
# Prereqs on PATH: sops, python3, nix, ssh.
# Prereqs in env: SOPS_AGE_KEY_FILE (workstation key).

set -euo pipefail

hostname="${1:?Usage: $0 <hostname> [flake-target]}"
# Optional second argument overrides the flake output name. Used by
# bootstrap-cluster.sh to deploy mcp-audit-phase1 (without Vector) before
# NATS creds are available, then mcp-audit (full) once they are.
flake_target="${2:-$hostname}"
domain="${MCP_DOMAIN:-samesies.gay}"
deploy_user="${DEPLOY_USER:-eve}"
deploy_host="${DEPLOY_HOST:-${hostname}.${domain}}"
target="${deploy_user}@${deploy_host}"

# --- sanity -----------------------------------------------------------

# Resolve the monorepo root from this script location so callers can run
# it from either the repo root or `terraform/`.
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
nixos_root="$repo_root/nixos"

[[ -f "$nixos_root/flake.nix" ]] || {
  echo "error: expected NixOS flake at $nixos_root/flake.nix" >&2
  exit 1
}

for bin in sops python3 ssh nix; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: '$bin' not on PATH" >&2
    exit 1
  }
done

if command -v nixos-rebuild >/dev/null 2>&1; then
  rebuild_cmd=(nixos-rebuild)
else
  # Non-NixOS workstations often have `nix` but not `nixos-rebuild` on PATH.
  rebuild_cmd=(nix run nixpkgs#nixos-rebuild --)
fi

: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

# --- wait for SSH reachability (terraform-created LXC takes ~20s) -----

echo "[$hostname] waiting for SSH..."
for _ in $(seq 1 30); do
  if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
       "$target" true 2>/dev/null; then
    break
  fi
  sleep 2
done

ssh -o BatchMode=yes -o ConnectTimeout=3 "$target" true 2>/dev/null || {
  echo "error: $target unreachable after 60s — aborting" >&2
  exit 1
}

# --- push age key if missing ------------------------------------------

if ssh "$target" 'sudo test -s /var/lib/sops-nix/key.txt' 2>/dev/null; then
  echo "[$hostname] /var/lib/sops-nix/key.txt already present — skipping key push"
else
  echo "[$hostname] pushing age key..."
  privkey=$(sops --decrypt "$nixos_root/secrets/host-sops-keys.yaml" \
            | python3 -c 'import sys,yaml; value = yaml.safe_load(sys.stdin)["'"$hostname"'"]; print(next((line.strip() for line in value.splitlines() if line.strip().startswith("AGE-SECRET-KEY-")), ""), end="")')
  if [[ -z "$privkey" || "$privkey" != AGE-SECRET-KEY-* ]]; then
    echo "error: no age key for $hostname in nixos/secrets/host-sops-keys.yaml" >&2
    echo "       (run: $repo_root/scripts/add-host.sh $hostname)" >&2
    exit 1
  fi
  printf '%s\n' "$privkey" | ssh "$target" 'sh -eu -c '\''
    sudo install -d -m 700 -o root -g root /var/lib/sops-nix
    sudo install -m 600 -o root -g root /dev/stdin /var/lib/sops-nix/key.txt
  '\'''
  echo "[$hostname] age key installed at /var/lib/sops-nix/key.txt"
fi

# --- run nixos-rebuild switch -----------------------------------------

echo "[$hostname] running nixos-rebuild switch..."
"${rebuild_cmd[@]}" switch \
  --flake "$nixos_root#${flake_target}" \
  --target-host "$target" \
  --use-remote-sudo \
  --fast

echo "[$hostname] OK: deployed"
