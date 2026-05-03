#!/usr/bin/env bash
# scripts/home-manager.sh [command] [target]
#
# Operator wrapper for the external Home Manager flake. This repo references the
# Home Manager source; it does not copy workstation state or decrypt secrets.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$script_dir/.." && pwd)"
# shellcheck disable=SC2034 # Kept for parity with repo-root resolving operator scripts.
readonly REPO_ROOT

HOME_MANAGER_REPO="${HOME_MANAGER_REPO:-$HOME/repo/home-manager}"
DEFAULT_TARGET="wsl-desktop"

command_name="${1:-help}"
target="${2:-$DEFAULT_TARGET}"

usage() {
  cat <<'USAGE'
Usage: scripts/home-manager.sh <command> [target]

Commands:
  repo-path      Print the selected Home Manager repo path.
  verify         Check repo, target, encrypted secrets file, and local age key.
  build          Run home-manager build for the target.
  switch         Run home-manager switch for the target.
  news           Run home-manager news for the target.
  edit-secrets   Open the encrypted Home Manager secrets file with sops.
  help           Show this help.

Environment:
  HOME_MANAGER_REPO  Defaults to $HOME/repo/home-manager.
USAGE
}

require_command() {
  local binary="${1:?binary required}"

  command -v "$binary" >/dev/null 2>&1 || {
    echo "error: '$binary' not on PATH" >&2
    exit 1
  }
}

require_repo() {
  [[ -f "$HOME_MANAGER_REPO/flake.nix" ]] || {
    echo "error: HOME_MANAGER_REPO does not contain flake.nix: $HOME_MANAGER_REPO" >&2
    echo "       Set HOME_MANAGER_REPO=/path/to/home-manager and retry." >&2
    exit 1
  }
}

verify_target() {
  local target_name="${1:?target required}"
  local flake_json

  require_command nix
  require_repo

  flake_json="$(nix flake show --json "$HOME_MANAGER_REPO")"
  FLAKE_JSON="$flake_json" python3 - "$target_name" <<'PY'
import json
import os
import sys

target = sys.argv[1]
data = json.loads(os.environ["FLAKE_JSON"])
home_configurations = data.get("homeConfigurations", {})
children = home_configurations.get("children", {})

if target in home_configurations or target in children:
    sys.exit(0)

print(f"error: Home Manager target not found: {target}", file=sys.stderr)
print("       Expected homeConfigurations.<target> in HOME_MANAGER_REPO.", file=sys.stderr)
sys.exit(1)
PY
}

verify_secrets_boundary() {
  local secrets_file="$HOME_MANAGER_REPO/secrets/secrets.yaml"
  local age_key_file="$HOME/.config/sops/age/keys.txt"

  [[ -f "$secrets_file" ]] || {
    echo "error: encrypted Home Manager secrets file missing: $secrets_file" >&2
    echo "       Create it in HOME_MANAGER_REPO and keep it SOPS-encrypted." >&2
    exit 1
  }

  [[ -f "$age_key_file" ]] || {
    echo "error: local SOPS age key missing: $age_key_file" >&2
    echo "       Restore the private key locally; do not commit it to this repo." >&2
    exit 1
  }
}

run_home_manager() {
  local subcommand="${1:?subcommand required}"

  require_command home-manager
  require_repo
  home-manager "$subcommand" --flake "$HOME_MANAGER_REPO#$target"
}

case "$command_name" in
  repo-path)
    printf '%s\n' "$HOME_MANAGER_REPO"
    ;;
  verify)
    require_command python3
    verify_target "$target"
    verify_secrets_boundary
    echo "OK: $target is available from $HOME_MANAGER_REPO"
    ;;
  build)
    run_home_manager build
    ;;
  switch)
    run_home_manager switch
    ;;
  news)
    run_home_manager news
    ;;
  edit-secrets)
    require_command sops
    require_repo
    sops "$HOME_MANAGER_REPO/secrets/secrets.yaml"
    ;;
  help | --help | -h)
    usage
    ;;
  *)
    echo "error: unknown command: $command_name" >&2
    usage >&2
    exit 1
    ;;
esac
