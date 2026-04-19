#!/usr/bin/env bash
# scripts/add-host.sh <hostname>
#
# One-shot per-host setup. Generates a dedicated age keypair, inserts
# the pubkey into nixos/.sops.yaml, stashes the privkey in the
# sops-encrypted nixos/secrets/host-sops-keys.yaml, and re-encrypts the
# host's secrets file for the new recipient.
#
# Idempotent: refuses to clobber an existing real age key in .sops.yaml.
#
# Prereqs on PATH: age, age-keygen, sops, python3, jq.
# Prereqs in env: SOPS_AGE_KEY_FILE (or default $HOME/.config/sops/age/keys.txt).

set -euo pipefail

hostname="${1:?Usage: $0 <hostname> (e.g. mcp-audit, mcp-nats-1)}"

# --- sanity -----------------------------------------------------------

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
nixos_root="$repo_root/nixos"

[[ -f "$nixos_root/flake.nix" && -f "$nixos_root/.sops.yaml" ]] || {
  echo "error: expected NixOS files under $nixos_root" >&2
  exit 1
}

cd "$nixos_root"

for bin in age age-keygen sops python3 jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: '$bin' not on PATH (try: nix shell nixpkgs#{age,sops,python3,jq})" >&2
    exit 1
  }
done

: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
[[ -r "$SOPS_AGE_KEY_FILE" ]] || {
  echo "error: workstation age key not readable at $SOPS_AGE_KEY_FILE" >&2
  echo "       (set SOPS_AGE_KEY_FILE or run 'age-keygen -o \$HOME/.config/sops/age/keys.txt')" >&2
  exit 1
}
export SOPS_AGE_KEY_FILE

# Refuse to clobber a real key
if grep -qE "^\s+- &${hostname} age1[0-9a-z]{58}" .sops.yaml; then
  echo "error: $hostname already has a real age key in .sops.yaml — refusing to overwrite" >&2
  echo "       (to rotate, delete the anchor line and the host's entry in secrets/host-sops-keys.yaml first)" >&2
  exit 1
fi

# --- generate keypair (in tmpfs, shredded on exit) --------------------

tmp=$(mktemp -d)
# shellcheck disable=SC2064
trap "shred -u \"$tmp/key.age\" 2>/dev/null || true; rm -rf \"$tmp\"" EXIT

age-keygen -o "$tmp/key.age" 2>/dev/null
pubkey=$(age-keygen -y "$tmp/key.age")
echo "generated: $pubkey"

# --- .sops.yaml: insert pubkey ----------------------------------------

if grep -qF "REPLACE_ME_AGE_${hostname}" .sops.yaml; then
  # Phase-1 placeholder slot — just fill it in
  python3 - "$hostname" "$pubkey" <<'PY'
import sys, pathlib
host, pub = sys.argv[1], sys.argv[2]
p = pathlib.Path(".sops.yaml")
p.write_text(p.read_text().replace(f"REPLACE_ME_AGE_{host}", pub))
PY
  echo "updated: .sops.yaml (filled placeholder for $hostname)"
else
  # Fresh host — append anchor under keys: and a new creation_rule block
  python3 - "$hostname" "$pubkey" <<'PY'
import sys, pathlib, re
host, pub = sys.argv[1], sys.argv[2]
p = pathlib.Path(".sops.yaml")
lines = p.read_text().splitlines()

# Insert "  - &<host> <pub>" after the last existing anchor under keys:
in_keys, last_key_idx = False, -1
for i, line in enumerate(lines):
    if line.startswith("keys:"):
        in_keys = True
    elif in_keys and line.startswith("creation_rules:"):
        break
    if in_keys and re.match(r"\s*- &", line):
        last_key_idx = i
if last_key_idx < 0:
    raise SystemExit("error: no existing key anchor found under keys:")
lines.insert(last_key_idx + 1, f"  - &{host} {pub}")

# Append new creation_rule block
lines.extend([
    f"  - path_regex: secrets/{host}\\.ya?ml$",
    f"    key_groups:",
    f"      - age:",
    f"          - *evelyn",
    f"          - *{host}",
])
p.write_text("\n".join(lines) + "\n")
PY
  echo "updated: .sops.yaml (added new anchor + creation_rule for $hostname)"
fi

# --- secrets/host-sops-keys.yaml: stash privkey -----------------------

privkey_json=$(jq -Rs . < "$tmp/key.age")

if [[ -f secrets/host-sops-keys.yaml ]]; then
  # Existing sops file — inject new key via `sops set`
  sops set secrets/host-sops-keys.yaml "[\"${hostname}\"]" "$privkey_json"
  echo "updated: secrets/host-sops-keys.yaml (added entry for $hostname)"
else
  # First host — write plaintext at the target path so sops matches the
  # creation_rule in .sops.yaml (sops keys on the *input* path), then
  # encrypt in place.
  cat > secrets/host-sops-keys.yaml <<EOF
# Dedicated age identities per audit-plane LXC.
# Decryptable only by the workstation key (see .sops.yaml).
# Consumed by repo-root scripts/bootstrap-host.sh to seed /var/lib/sops-nix/key.txt.

${hostname}: |
$(sed 's/^/  /' "$tmp/key.age")
EOF
  sops --encrypt --in-place secrets/host-sops-keys.yaml
  echo "created: secrets/host-sops-keys.yaml (first host)"
fi

# --- re-key the host's own secrets yaml -------------------------------

host_secrets="secrets/${hostname}.yaml"
if [[ -f "$host_secrets" ]]; then
  if grep -q "^sops:" "$host_secrets" 2>/dev/null; then
    sops updatekeys --yes "$host_secrets"
    echo "updated: $host_secrets (re-encrypted for $hostname recipient)"
  else
    echo "note: $host_secrets is plaintext — skipping sops updatekeys"
    echo "      after you populate real values, run: sops -e -i $host_secrets"
  fi
else
  echo "note: $host_secrets does not exist yet (cp the .example, populate, then 'sops -e -i')"
fi

# --- done -------------------------------------------------------------

cat <<EOF

OK: $hostname configured.

Next:
  1. (if $host_secrets is plaintext) populate real values, then:
       sops -e -i $host_secrets
  2. git add .sops.yaml secrets/host-sops-keys.yaml $host_secrets
  3. git commit -m "feat: bootstrap age identity for $hostname"
  4. cd "$repo_root/terraform" && terraform apply

EOF
