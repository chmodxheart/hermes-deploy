#!/usr/bin/env bash
# scripts/init-secrets.sh [--dry-run] [--force] [target ...]
#
# Generate the bootstrap secrets for the NATS/audit-plane bring-up workflow and
# encrypt them with sops from inside `nixos/` so the existing creation rules
# apply. This intentionally does NOT touch unrelated secrets like hermes.yaml.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/init-secrets.sh [--dry-run] [--force] [target ...]

Generate and encrypt the NATS/bootstrap secret files only:
  - nats-operator
  - mcp-audit
  - mcp-nats01
  - mcp-nats02
  - mcp-nats03

Examples:
  scripts/init-secrets.sh
  scripts/init-secrets.sh --dry-run
  scripts/init-secrets.sh --dry-run --force
  scripts/init-secrets.sh nats-operator mcp-audit
  scripts/init-secrets.sh --force mcp-nats01 mcp-nats02 mcp-nats03

Options:
  --dry-run               Print the planned actions without changing nsc or secrets
  --force                 Overwrite existing target files
  -h, --help              Show this help

Environment overrides:
  NSC_OPERATOR_NAME       Default: mcp-audit-cluster
  NSC_AUDIT_ACCOUNT_NAME  Default: AUDIT
  NSC_SERVICE_URL         Default: nats://mcp-nats01.samesies.gay:4222

Notes:
  - This script generates the values that are locally derivable from `nsc` and
    local randomness. It leaves external/manual inputs as placeholders.
  - `step_ca_root_cert` intentionally remains a placeholder on the first pass.
    After the first mcp-audit bootstrap, fetch `/etc/step-ca/certs/root_ca.crt`,
    paste it into `nixos/secrets/mcp-audit.yaml` and `nixos/secrets/mcp-nats*.yaml`,
    re-encrypt, and redeploy.
  - Existing NSC users are reused as-is. If you previously created users with
    the old `audit.otlp.<host>` publish ACLs, recreate or update them before
    relying on the new `audit.otlp.traces.<host>` path.
EOF
}

dry_run=false
force=false
operator_context_ready=false
declare -a requested=()

while (($# > 0)); do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    --force)
      force=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      requested+=("$1")
      ;;
  esac
  shift
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
nixos_root="$repo_root/nixos"

operator_name="${NSC_OPERATOR_NAME:-mcp-audit-cluster}"
audit_account_name="${NSC_AUDIT_ACCOUNT_NAME:-AUDIT}"
service_url="${NSC_SERVICE_URL:-nats://mcp-nats01.samesies.gay:4222}"

declare -ra default_targets=(
  "nats-operator"
  "mcp-audit"
  "mcp-nats01"
  "mcp-nats02"
  "mcp-nats03"
)

declare -a targets=()
if ((${#requested[@]} == 0)); then
  targets=("${default_targets[@]}")
else
  targets=("${requested[@]}")
fi

for target in "${targets[@]}"; do
  case "$target" in
    nats-operator|mcp-audit|mcp-nats01|mcp-nats02|mcp-nats03)
      ;;
    *)
      echo "error: unsupported target '$target'" >&2
      exit 1
      ;;
  esac
done

[[ -d "$nixos_root/secrets" && -f "$nixos_root/.sops.yaml" ]] || {
  echo "error: expected nixos secrets and .sops.yaml under $nixos_root" >&2
  exit 1
}

declare -a required_bins=(awk nsc sed tr)
if [[ "$dry_run" != true ]]; then
  required_bins+=(cp mkdir mktemp mv openssl rm sops)
fi

for bin in "${required_bins[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: '$bin' not on PATH" >&2
    exit 1
  }
done

cd "$nixos_root"

indent_block() {
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done <<<"$1"
}

random_alnum() {
  local length=$1
  local out=""

  while ((${#out} < length)); do
    out+="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  done

  printf '%s' "${out:0:length}"
}

random_base64() {
  openssl rand -base64 32 | tr -d '\n'
}

random_hex64() {
  openssl rand -hex 32 | tr -d '\n'
}

log_action() {
  local message=$1

  if [[ "$dry_run" == true ]]; then
    printf '[dry-run] %s\n' "$message"
    return 0
  fi

  printf '%s\n' "$message"
}

load_operator_context() {
  local env_output

  env_output="$(nsc env --operator "$operator_name" 2>/dev/null)"
  eval "$env_output"
  operator_context_ready=true
}

ensure_operator_context() {
  if nsc describe operator -n "$operator_name" >/dev/null 2>&1; then
    log_action "reuse nsc operator: $operator_name"
  else
    log_action "create nsc operator: $operator_name"
    if [[ "$dry_run" == true ]]; then
      log_action "set nsc operator service URL: $service_url"
      return 0
    fi

    nsc add operator -n "$operator_name" --generate-signing-key --sys >/dev/null
  fi

  if [[ "$dry_run" == true ]]; then
    if nsc describe operator -n "$operator_name" >/dev/null 2>&1; then
      load_operator_context
    fi

    log_action "set nsc operator service URL: $service_url"
    return 0
  fi

  load_operator_context
  nsc edit operator --service-url "$service_url" >/dev/null
}

ensure_account() {
  if [[ "$operator_context_ready" != true ]]; then
    log_action "create nsc account: $audit_account_name"
    return 0
  fi

  if nsc describe account -n "$audit_account_name" >/dev/null 2>&1; then
    log_action "reuse nsc account: $audit_account_name"
    return 0
  fi

  log_action "create nsc account: $audit_account_name"
  [[ "$dry_run" == true ]] && return 0

  nsc add account -n "$audit_account_name" >/dev/null
}

ensure_user() {
  local name=$1
  shift

  if [[ "$operator_context_ready" != true ]]; then
    log_action "create nsc user: $name"
    return 0
  fi

  if nsc describe user -a "$audit_account_name" -n "$name" >/dev/null 2>&1; then
    log_action "reuse nsc user: $name"
    return 0
  fi

  log_action "create nsc user: $name"
  [[ "$dry_run" == true ]] && return 0

  nsc add user -a "$audit_account_name" -n "$name" "$@" >/dev/null
}

write_encrypted_target() {
  local name=$1
  local generator=$2
  local rel_path="secrets/$name.yaml"
  local tmp_path
  local tmp_root
  local backup_path=""

  if [[ -e "$rel_path" && "$force" != true ]]; then
    log_action "skip: $rel_path already exists (use --force to replace)"
    return 0
  fi

  if [[ "$dry_run" == true ]]; then
    if [[ -e "$rel_path" ]]; then
      log_action "replace encrypted target: $rel_path"
    else
      log_action "create encrypted target: $rel_path"
    fi

    return 0
  fi

  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/secrets"
  tmp_path="$tmp_root/$rel_path"
  "$generator" > "$tmp_path"

  if ! sops --encrypt --in-place "$tmp_path"; then
    echo "error: failed to encrypt temp file for $rel_path" >&2
    rm -r "$tmp_root"
    return 1
  fi

  if [[ -e "$rel_path" ]]; then
    backup_path="$(mktemp "secrets/.${name}.yaml.bak.XXXXXX")"
    cp "$rel_path" "$backup_path"
  fi

  mv "$tmp_path" "$rel_path"
  rm -r "$tmp_root"

  [[ -n "$backup_path" ]] && rm -f "$backup_path"
  log_action "generated: $rel_path"
}

generate_nats_operator() {
  local operator_jwt
  local system_account_public_key
  local audit_account_jwt
  local admin_creds

  operator_jwt="$(nsc describe operator -n "$operator_name" --raw)"
  system_account_public_key="$(nsc describe account -n SYS --field sub | tr -d '\n')"
  audit_account_jwt="$(nsc describe account -n "$audit_account_name" --raw)"
  admin_creds="$(nsc generate creds -a "$audit_account_name" -n admin)"

  cat <<EOF
nats_operator_jwt: $operator_jwt
nats_system_account_public_key: $system_account_public_key
nats_account_audit_jwt: $audit_account_jwt
nats_admin_creds: |
$(indent_block "$admin_creds")
EOF
}

generate_mcp_nats() {
  local host=$1
  local vector_creds

  vector_creds="$(nsc generate creds -a "$audit_account_name" -n "vector-$host")"

  cat <<EOF
# Populate with the real step-ca root PEM after the first mcp-audit bootstrap.
step_ca_root_cert: |
    -----BEGIN CERTIFICATE-----
    REPLACE_ME_STEP_CA_ROOT_PEM
    -----END CERTIFICATE-----

nats_server_cert: REPLACE_ME_POPULATED_AT_BOOTSTRAP
nats_server_key: REPLACE_ME_POPULATED_AT_BOOTSTRAP
vector_client_cert: REPLACE_ME_POPULATED_AT_BOOTSTRAP
vector_client_key: REPLACE_ME_POPULATED_AT_BOOTSTRAP

nats_client_creds: |
$(indent_block "$vector_creds")
EOF
}

generate_mcp_nats01() {
  generate_mcp_nats "mcp-nats01"
}

generate_mcp_nats02() {
  generate_mcp_nats "mcp-nats02"
}

generate_mcp_nats03() {
  generate_mcp_nats "mcp-nats03"
}

generate_mcp_audit() {
  local postgres_password
  local clickhouse_password
  local redis_password
  local nextauth_secret
  local salt
  local encryption_key
  local step_ca_intermediate_pw
  local nats_ingest_creds
  local langfuse_web_env
  local langfuse_worker_env
  local langfuse_ingest_env

  postgres_password="$(random_alnum 32)"
  clickhouse_password="$(random_alnum 32)"
  redis_password="$(random_alnum 32)"
  nextauth_secret="$(random_base64)"
  salt="$(random_base64)"
  encryption_key="$(random_hex64)"
  step_ca_intermediate_pw="$(random_base64)"
  nats_ingest_creds="$(nsc generate creds -a "$audit_account_name" -n langfuse-ingest)"

  read -r -d '' langfuse_web_env <<EOF || true
DATABASE_URL=postgresql://langfuse:$postgres_password@127.0.0.1:5432/langfuse
NEXTAUTH_URL=http://localhost:3000
NEXTAUTH_SECRET=$nextauth_secret
SALT=$salt
ENCRYPTION_KEY=$encryption_key
CLICKHOUSE_URL=http://127.0.0.1:8123
CLICKHOUSE_MIGRATION_URL=clickhouse://127.0.0.1:9000
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=$clickhouse_password
REDIS_CONNECTION_STRING=redis://:$redis_password@127.0.0.1:6379/0
LANGFUSE_S3_EVENT_UPLOAD_BUCKET=langfuse
LANGFUSE_S3_EVENT_UPLOAD_REGION=us-east-1
LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID=REPLACE_ME_MINIO_ACCESS_KEY
LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=REPLACE_ME_MINIO_SECRET_KEY
LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT=https://minio.samesies.gay
LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE=true
LANGFUSE_S3_EVENT_UPLOAD_PREFIX=events/
EOF

  read -r -d '' langfuse_worker_env <<EOF || true
DATABASE_URL=postgresql://langfuse:$postgres_password@127.0.0.1:5432/langfuse
SALT=$salt
ENCRYPTION_KEY=$encryption_key
CLICKHOUSE_URL=http://127.0.0.1:8123
CLICKHOUSE_MIGRATION_URL=clickhouse://127.0.0.1:9000
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=$clickhouse_password
REDIS_CONNECTION_STRING=redis://:$redis_password@127.0.0.1:6379/0
LANGFUSE_S3_EVENT_UPLOAD_BUCKET=langfuse
LANGFUSE_S3_EVENT_UPLOAD_REGION=us-east-1
LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID=REPLACE_ME_MINIO_ACCESS_KEY
LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=REPLACE_ME_MINIO_SECRET_KEY
LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT=https://minio.samesies.gay
LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE=true
LANGFUSE_S3_EVENT_UPLOAD_PREFIX=events/
EOF

  read -r -d '' langfuse_ingest_env <<'EOF' || true
LANGFUSE_PUBLIC_KEY=REPLACE_ME_LANGFUSE_PUBLIC_KEY
LANGFUSE_SECRET_KEY=REPLACE_ME_LANGFUSE_SECRET_KEY
EOF

  cat <<EOF
langfuse_web_env: |
$(indent_block "$langfuse_web_env")

langfuse_worker_env: |
$(indent_block "$langfuse_worker_env")

langfuse_ingest_env: |
$(indent_block "$langfuse_ingest_env")

postgres_password: $postgres_password
clickhouse_password: $clickhouse_password
redis_password: $redis_password
step_ca_intermediate_pw: $step_ca_intermediate_pw

# Populate with the real step-ca root PEM after the first mcp-audit bootstrap.
step_ca_root_cert: |
    -----BEGIN CERTIFICATE-----
    REPLACE_ME_STEP_CA_ROOT_PEM
    -----END CERTIFICATE-----

nats_ingest_creds: |
$(indent_block "$nats_ingest_creds")
EOF
}

ensure_operator_context
ensure_account
ensure_user "admin"
ensure_user "langfuse-ingest" --allow-sub 'audit.otlp.>'
ensure_user "vector-mcp-nats01" --allow-pub 'audit.otlp.traces.mcp-nats01,audit.journal.mcp-nats01'
ensure_user "vector-mcp-nats02" --allow-pub 'audit.otlp.traces.mcp-nats02,audit.journal.mcp-nats02'
ensure_user "vector-mcp-nats03" --allow-pub 'audit.otlp.traces.mcp-nats03,audit.journal.mcp-nats03'

for target in "${targets[@]}"; do
  case "$target" in
    nats-operator)
      write_encrypted_target "$target" generate_nats_operator
      ;;
    mcp-audit)
      write_encrypted_target "$target" generate_mcp_audit
      ;;
    mcp-nats01)
      write_encrypted_target "$target" generate_mcp_nats01
      ;;
    mcp-nats02)
      write_encrypted_target "$target" generate_mcp_nats02
      ;;
    mcp-nats03)
      write_encrypted_target "$target" generate_mcp_nats03
      ;;
  esac
done

if [[ "$dry_run" == true ]]; then
  cat <<'EOF'

Dry run only: no NSC operator/account/user changes were made and no secret files
were written or encrypted.
EOF
  exit 0
fi

cat <<'EOF'

Next manual/deferred values:
- Fill MinIO access/secret keys in `nixos/secrets/mcp-audit.yaml`.
- After first mcp-audit bootstrap, replace `step_ca_root_cert` in:
  - `nixos/secrets/mcp-audit.yaml`
  - `nixos/secrets/mcp-nats01.yaml`
  - `nixos/secrets/mcp-nats02.yaml`
  - `nixos/secrets/mcp-nats03.yaml`
- After Langfuse is up, replace `LANGFUSE_PUBLIC_KEY` and
  `LANGFUSE_SECRET_KEY` in `nixos/secrets/mcp-audit.yaml`.
EOF
