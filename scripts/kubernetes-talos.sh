#!/usr/bin/env bash
# scripts/kubernetes-talos.sh [command]
#
# Safe operator wrapper for the external clustertool Talos/Flux source. This repo
# references clustertool for browsing and verification; durable cluster changes
# still belong in clustertool and Flux.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$script_dir/.." && pwd)"
readonly REPO_ROOT

CLUSTERTOOL_REPO="${CLUSTERTOOL_REPO:-$REPO_ROOT/external/clustertool}"
command_name="${1:-help}"

usage() {
  cat <<'USAGE'
Usage: scripts/kubernetes-talos.sh <command>

Commands:
  repo-path      Print the selected clustertool repo path.
  static         Check the referenced source tree and encrypted metadata only.
  verify         Run static checks, then optional read-only live checks.
  live           Run read-only Flux, Kubernetes, and Talos status checks.
  flux-status    Run read-only Flux status checks when flux is available.
  talos-status   Run read-only Talos health checks when talosctl is available.
  help           Show this help.

Environment:
  CLUSTERTOOL_REPO  Defaults to this repo's external/clustertool submodule.

This wrapper never decrypts SOPS files and does not implement mutating cluster
commands. Durable Kubernetes changes remain clustertool-owned through Git/Flux.
USAGE
}

require_command() {
  local binary="${1:?binary required}"

  command -v "$binary" >/dev/null 2>&1 || {
    echo "error: '$binary' not on PATH" >&2
    exit 1
  }
}

have_command() {
  local binary="${1:?binary required}"

  command -v "$binary" >/dev/null 2>&1
}

require_path() {
  local path="${1:?path required}"

  [[ -e "$path" ]] || {
    echo "error: required clustertool path missing: $path" >&2
    echo "       Refresh the external/clustertool submodule and retry." >&2
    exit 1
  }
}

has_context() {
  local binary="${1:?binary required}"

  "$binary" config current-context >/dev/null 2>&1
}

check_static_paths() {
  require_path "$CLUSTERTOOL_REPO/AGENTS.md"
  require_path "$CLUSTERTOOL_REPO/.sops.yaml"
  require_path "$CLUSTERTOOL_REPO/clusters/main/clusterenv.yaml"
  require_path "$CLUSTERTOOL_REPO/clusters/main/talos"
  require_path "$CLUSTERTOOL_REPO/clusters/main/kubernetes"
}

check_sops_markers() {
  require_command python3

  CLUSTERTOOL_REPO="$CLUSTERTOOL_REPO" python3 - <<'PY'
from pathlib import Path
import os
import sys

repo = Path(os.environ["CLUSTERTOOL_REPO"])
checks = [
    repo / "clusters/main/clusterenv.yaml",
    repo / "clusters/main/talos/generated/talsecret.yaml",
]
checks.extend((repo / "clusters/main").rglob("*.secret.yaml"))

missing = []
for path in sorted(set(checks)):
    if not path.exists():
        missing.append(f"missing encrypted file: {path}")
        continue

    found = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == "sops:":
            found = True
            break
    if not found:
        missing.append(f"missing top-level sops marker: {path}")

if missing:
    for item in missing:
        print(f"error: {item}", file=sys.stderr)
    sys.exit(1)

print(f"OK: checked SOPS metadata on {len(set(checks))} encrypted files")
PY
}

check_yaml_when_available() {
  require_command python3

  CLUSTERTOOL_REPO="$CLUSTERTOOL_REPO" python3 - <<'PY'
from pathlib import Path
import os
import sys

try:
    import yaml
except ImportError:
    print("SKIP: PyYAML not available")
    sys.exit(0)

repo = Path(os.environ["CLUSTERTOOL_REPO"])
yaml_files = [repo / "clusters/main/clusterenv.yaml"]
yaml_files.extend((repo / "clusters/main/kubernetes").rglob("*.yaml"))
yaml_files.extend((repo / "clusters/main/talos").rglob("*.yaml"))

for path in sorted(set(yaml_files)):
    with path.open("r", encoding="utf-8") as handle:
        list(yaml.safe_load_all(handle))

print(f"OK: parsed {len(set(yaml_files))} YAML files with PyYAML")
PY
}

run_static() {
  check_static_paths
  check_sops_markers
  check_yaml_when_available
  echo "OK: static clustertool checks passed"
}

flux_status() {
  if ! have_command flux; then
    echo "SKIP: flux unavailable"
    return 0
  fi

  flux get kustomizations -A || echo "SKIP: flux kustomization context unavailable"
  flux get helmreleases -A || echo "SKIP: flux helmrelease context unavailable"
}

kubectl_status() {
  if ! have_command kubectl; then
    echo "SKIP: kubectl unavailable"
    return 0
  fi

  if ! has_context kubectl; then
    echo "SKIP: kubectl context unavailable"
    return 0
  fi

  kubectl get nodes || echo "SKIP: kubectl cluster access unavailable"
}

talos_status() {
  if ! have_command talosctl; then
    echo "SKIP: talosctl unavailable"
    return 0
  fi

  talosctl health || echo "SKIP: talosctl context unavailable"
}

run_live() {
  flux_status
  kubectl_status
  talos_status
}

case "$command_name" in
  repo-path)
    printf '%s\n' "$CLUSTERTOOL_REPO"
    ;;
  static)
    run_static
    ;;
  verify)
    run_static
    run_live
    ;;
  live)
    run_live
    ;;
  flux-status)
    flux_status
    ;;
  talos-status)
    talos_status
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
