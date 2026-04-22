# External Integrations

**Analysis Date:** 2026-04-22

Hermes-deploy is a personal-infrastructure deploy that wires one Proxmox
cluster to a NixOS-based audit plane plus an LLM agent host. External
dependencies are few and named: Proxmox VE, a self-hosted MinIO, a
self-hosted AD domain (`samesies.gay`), NATS/Langfuse/ClickHouse running on
the audit plane itself, and a handful of third-party LLM / messaging
providers surfaced by the `hermes-agent` module.

## APIs & External Services

**Hypervisor control plane:**
- Proxmox VE — provisioned via `bpg/proxmox` `~> 0.102.0`
  (`terraform/versions.tf:10-13`)
  - Endpoint: `var.virtual_environment_endpoint`
    (`terraform/providers.tf:2`, `provider-variables.tf:1-4`)
  - Auth: API token (`var.virtual_environment_api_token`, sensitive,
    `provider-variables.tf:6-10`) plus PAM-backed SSH user
    (`var.virtual_environment_ssh_username`, `provider-variables.tf:12-15`);
    provider uses `ssh.agent = true` (`providers.tf:7`) for file uploads

**Public-key infrastructure (self-hosted on the audit plane):**
- `step-ca` (Smallstep) — ACME provisioner issuing 24-hour TLS certs
  (`nixos/modules/step-ca.nix:24-64`)
  - Listens on `ca.samesies.gay:8443`, forced CN match
  - Consumers: `nats-server-cert.service`
    (`nixos/modules/nats-cluster.nix:244-272`) and
    `vector-client-cert.service`
    (`nixos/modules/vector-audit-client.nix:219-242`) — both use
    `step ca certificate --provisioner acme`; renew every 12h via a
    systemd timer
  - Flake-check `step-ca-cert-duration-24h` (`nixos/flake.nix:275-300`)
    asserts both `defaultTLSCertDuration` and `maxTLSCertDuration` equal
    `"24h"`

**Messaging / audit transport (self-hosted, three-node cluster):**
- NATS JetStream — `mcp-nats01..03`, cluster name `mcp-audit-cluster`
  (`nixos/modules/nats-cluster.nix:86-99`)
  - mTLS on 4222 (client), 6222 (cluster), monitor HTTP on 8222
  - JWT "full" resolver; operator + account JWTs come from
    `nixos/secrets/nats-operator.yaml` via
    `nixos/modules/nats-accounts.nix`
  - Subjects: `audit.otlp.traces.<host>` (OTLP traces, publisher in
    `nixos/modules/otlp-nats-publisher.nix:63`) and
    `audit.journal.<host>` (journald, Vector sink in
    `vector-audit-client.nix:174`); consumers on `mcp-audit`
    (`modules/mcp-audit.nix:412-434`)
  - Flake-checks: `nats-no-anonymous` (`nixos/flake.nix:185-231`) blocks
    any `allow_anonymous = true` and requires the `resolver.type = full`
    block

**Observability / audit sink (self-hosted on `mcp-audit`):**
- Langfuse v3 — `langfuse/langfuse` + `langfuse/langfuse-worker`
  OCI containers pinned to sha256 digests (tag 3.169.0 as of 2026-04-17,
  `nixos/modules/mcp-audit.nix:33-39`)
  - Bound on `127.0.0.1:3000` only; LAN access via SSH tunnel
    (`mcp-audit.nix:227-231`)
  - Health probe at `http://127.0.0.1:3000/api/public/health`
    (`mcp-audit.nix:45-55`)
  - Flake-check `langfuse-image-pinned-by-digest`
    (`nixos/flake.nix:307-346`) asserts every `langfuse-*` container
    image carries `@sha256:<64-hex>`
- PostgreSQL 17 — native, database `langfuse`, user `langfuse`, bound on
  `127.0.0.1:5432` (`mcp-audit.nix:119-147`)
- ClickHouse — native, Langfuse user created from sops, built-in Prom
  endpoint on port 9363 (`mcp-audit.nix:160-199`)
- Redis 8 (named server `langfuse`) — bound on `127.0.0.1:6379`,
  `maxmemory-policy = noeviction` (`mcp-audit.nix:204-218`)
- Vector — publish side (journald → `audit.journal.<host>` via NATS) on
  every LXC via `modules/vector-audit-client.nix`; consumer side
  (`audit.journal.>` → `/var/log/journal/remote/`) on `mcp-audit`
  (`modules/mcp-audit.nix:412-439`)

**Object storage (external to this repo):**
- MinIO at `https://minio.samesies.gay`
  (`nixos/secrets/mcp-audit.yaml.example:47,70`)
  - Bucket: `langfuse` (event uploads)
  - Consumed only by the Langfuse web + worker containers via
    `LANGFUSE_S3_EVENT_UPLOAD_*` env vars; no MinIO runs inside the
    hermes-deploy tree (`modules/mcp-audit.nix:9-11,41` notes "external
    MinIO backing store … no in-LXC S3 container")
  - Path-style addressing: `LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE=true`

**Telemetry ingestion on every host:**
- OTLP HTTP receiver — `otlp-nats-publisher` listens on
  `127.0.0.1:4318` (`nixos/modules/otlp-nats-publisher.nix:29-37`)
  - Receives OTLP traces, forwards raw protobuf to NATS JetStream
  - SDK env vars set in `modules/mcp-otel.nix:14-20`:
    `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318`,
    `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`,
    `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental`,
    `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true`,
    `OTEL_RESOURCE_ATTRIBUTES` with `service.namespace=mcp`
  - Flake-check `otel-module-consistent` (`nixos/flake.nix:359-383`)
    asserts these values across every `mcp-*` host

**LLM / agent integrations on the `hermes` host (via `hermes-agent`
NixOS module — input `github:NousResearch/hermes-agent`,
`nixos/flake.nix:13-14`):**
- Primary chat model: `claude-sonnet-4-6` via a "custom" provider pointing
  at `${CUSTOM_API_URL}` with `${CUSTOM_API_KEY}` (secrets injected from
  sops, `nixos/hosts/hermes/default.nix:154-172`)
- Smart-model-routing cheap path: `openai/gpt-5.4-mini`
  (`hosts/hermes/default.nix:270-278`)
- Web-search backend: Exa (`settings.web.backend = "exa"`,
  `hosts/hermes/default.nix:491-493`)
- Supermemory — memory provider (`settings.memory.provider = "supermemory"`,
  `hermes/default.nix:394-402`); configured by a declarative symlink to
  `/var/lib/hermes/.hermes/supermemory.json`
  (`hosts/hermes/default.nix:537-554`)
- NodeSource apt repo — `https://deb.nodesource.com/setup_22.x`, pulled
  into the hermes-agent container to install Node 22 LTS
  (`hosts/hermes/default.nix:62-63`)
- NPM registry (implicit) — `@openai/codex` and `agent-browser` installed
  via `npm install -g` inside the container
  (`hosts/hermes/default.nix:37-38,79-83`)
- PyPI (implicit) — `supermemory` installed into a uv-managed venv
  (`hosts/hermes/default.nix:39,119-123`)
- Docker Hub (implicit) — `ubuntu:24.04` image for the hermes-agent
  container (`hosts/hermes/default.nix:138`), plus
  `nikolaik/python-nodejs:python3.11-nodejs20` for terminal/modal/daytona
  sandbox images (`hosts/hermes/default.nix:229-233`)
- Platform toolsets declared (not all enabled, but present in config
  surface, `hosts/hermes/default.nix:176-201`): Telegram, Discord,
  WhatsApp, Slack, Signal, Home Assistant, QQBot
- Discord — `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_USERS`,
  `DISCORD_HOME_CHANNEL` injected from sops via `hermes-env`
  (`hosts/hermes/default.nix:519-522`); `libopus0` installed for voice
  playback (`hosts/hermes/default.nix:36,51`)
- TTS providers surfaced in settings: Edge, ElevenLabs, OpenAI, Mistral,
  Neuphonic NeuTTS (`hosts/hermes/default.nix:336-359`)
- STT providers surfaced: local Whisper (`base` model), OpenAI `whisper-1`,
  Mistral `voxtral-mini-latest` (`hosts/hermes/default.nix:361-374`)
- Tirith policy gate — `security.tirith_enabled = true`, resolved on PATH
  (`hosts/hermes/default.nix:448-453`)

## Data Storage

**State / databases:**
- PostgreSQL 17 (local to `mcp-audit`) — Langfuse metadata
- ClickHouse (local to `mcp-audit`) — Langfuse event store; TTL DDL in
  `nixos/hosts/mcp-audit/clickhouse-schema.sql` re-applied weekly via
  `systemd.timers.clickhouse-ttl-reapply`
  (`modules/mcp-audit.nix:366-382`)
- Redis 8 (local to `mcp-audit`) — Langfuse BullMQ queues
- NATS JetStream (on `mcp-nats01..03`) — `AUDIT_JOURNAL` stream
  (`modules/mcp-audit.nix:418`); OTLP stream implicit via
  `audit.otlp.traces.<host>` subjects
- MinIO (`https://minio.samesies.gay`, external) — Langfuse event blobs,
  bucket `langfuse`

**Filesystem:**
- Ceph RBD — every LXC's rootfs via `rootfs_datastore = "ceph-rbd"`
  (`terraform/locals.tf:15,31,47,63`)
- Local journald — source of truth on every host; mirrored into
  `/var/log/journal/remote/` on `mcp-audit`
  (`modules/mcp-audit.nix:428-439`)
- Proxmox Backup Server (PBS) — integration via
  `nixos/modules/pbs-excludes.nix` + flake-check
  `mcp-audit-pbs-excludes` (`nixos/flake.nix:237-267`); required excludes:
  `/run`, `/var/run`, `/proc`, `/sys`, `/dev`, `/tmp`, `/var/cache`,
  `/run/secrets` (subset invariant)

**State file storage (Terraform):**
- Local backend — `terraform/terraform.tfstate` exists on disk;
  `.gitignore` ignores `terraform/*.tfstate*` (no remote backend
  configured in `terraform/versions.tf`)

## Authentication & Identity

**Operator SSH (into every managed LXC):**
- Public keys read from `~/.ssh/id_ed25519.pub` and passed through the LXC
  module (`terraform/locals.tf:20,36,52,68` →
  `terraform/modules/lxc-container/main.tf:19-22,67-71`)
- OpenSSH hardened in `nixos/modules/common.nix:58-90`:
  `PasswordAuthentication = false`, `PermitRootLogin = "no"`,
  `MaxAuthTries = 3`, ed25519 host key only

**DNS / name resolution:**
- Samba AD domain `samesies.gay`, domain controllers
  `10.0.1.30/31/32` (`nixos/hosts/mcp-audit/default.nix:138-150`)
- `services.resolved` fronts AD; `networking.extraHosts` hard-codes
  audit-plane peers as `/etc/hosts` fallback (`mcp-audit/default.nix:145-150`)
- Terraform injects `MCP_DOMAIN = "samesies.gay"` into
  `scripts/bootstrap-host.sh` (`terraform/main.tf:73-75`)

**Service-to-service:**
- NATS: JWT-in-creds identities per user, mTLS via step-ca certs; operator
  JWT at `/run/secrets/nats-operator-jwt`, per-account JWTs at
  `/var/lib/nats/jwt/<account>.jwt` (synced by
  `nats-jwt-sync.service`, `modules/nats-accounts.nix:155-180`)
- Vector: mTLS client cert from step-ca, credentials file
  `/run/secrets/nats-client.creds`
  (`modules/vector-audit-client.nix:178-188`)
- `langfuse-nats-ingest`: `/run/secrets/nats-ingest.creds`
  subscribe-only on `audit.otlp.>` (`modules/mcp-audit.nix:295-301`)
- Langfuse inter-component auth: env-file secrets
  (`DATABASE_URL`, `NEXTAUTH_SECRET`, `SALT`, `ENCRYPTION_KEY`,
  `CLICKHOUSE_*`, `REDIS_CONNECTION_STRING`) — see
  `nixos/secrets/mcp-audit.yaml.example:32-72`

**Hermes agent:**
- `API_SERVER_KEY` — bundled inside `hermes-env` sops secret; firewall
  restricts port 8642 to `10.0.1.0/24` as defense-in-depth
  (`hosts/hermes/default.nix:556-561`)
- `hermes-auth.json` — auth bundle owned by
  `config.services.hermes-agent.{user,group}` at
  `/run/secrets/hermes-auth.json` (`hosts/hermes/default.nix:20-27`)

## Secrets Management

**Framework:** `sops-nix` (input `github:Mic92/sops-nix`,
`nixos/flake.nix:7-8`), activated as `sops-nix.nixosModules.sops` in
`mkHost` (`nixos/flake.nix:52`).

**Key material:**
- Per-host age identity at `/var/lib/sops-nix/key.txt` — pushed on first
  boot by `scripts/bootstrap-host.sh:68-86`, which decrypts
  `nixos/secrets/host-sops-keys.yaml` and installs the private key over
  SSH with `sudo install -m 600 -o root`
- Fallback identity: the host's `/etc/ssh/ssh_host_ed25519_key` via
  `ssh-to-age` (`modules/common.nix:175-184`)
- Workstation key: `SOPS_AGE_KEY_FILE`, default
  `~/.config/sops/age/keys.txt` (`bootstrap-host.sh:49-50`)

**Encrypted files (`nixos/secrets/`, committed encrypted; plaintext
`.yaml.example` templates are committed):**
- `hermes.yaml` — `hermes_env` (env file with LLM API keys, Discord
  tokens, `SUPERMEMORY_API_KEY`, `API_SERVER_KEY`) and
  `hermes_auth_json` (`nixos/hosts/hermes/default.nix:10-28`)
- `mcp-audit.yaml` — Langfuse web/worker env files, `langfuse_ingest_env`
  (`LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`), `postgres_password`,
  `clickhouse_password`, `redis_password`, `step_ca_intermediate_pw`,
  `step_ca_root_cert`, `nats_ingest_creds` — see
  `secrets/mcp-audit.yaml.example`
- `mcp-nats01.yaml`, `mcp-nats02.yaml`, `mcp-nats03.yaml` — per-node
  Vector client `.creds` and TLS material
- `nats-operator.yaml` — shared operator bundle (`nats_operator_jwt`,
  `nats_system_account_public_key`, `nats_admin_creds`, per-account
  `nats_account_<name>_jwt` — see `modules/nats-accounts.nix:48-58,105-144`)
- `host-sops-keys.yaml` — per-host age private keys, consumed by
  `scripts/bootstrap-host.sh` and `scripts/add-host.sh`

**Helpers:**
- `scripts/init-secrets.sh` (475 lines) — first-time bootstrap of the
  secrets tree
- `scripts/add-host.sh` (160 lines) — generates an age identity for a new
  host and updates `host-sops-keys.yaml`
- `nixos/justfile` target `edit-secrets` — `sops secrets/hermes.yaml`
- `nixos/justfile` target `show-recipient` — `age-keygen -y ~/.config/sops/age/keys.txt`

**Decrypted paths at runtime:** exclusively under `/run/secrets/`
(tmpfs). Explicit mode `0400` / `0444`, owner-scoped to the consuming
service user (`postgres`, `clickhouse`, `redis-langfuse`, `nats`,
`vector`, `langfuse-ingest`, `step-ca`, `root` for container envfiles).

## Monitoring & Observability

**Error tracking / tracing:**
- Langfuse (self-hosted) — receives OTLP traces via the
  NATS → `langfuse-nats-ingest` pipeline
  (`modules/mcp-audit.nix:281-338`)

**Metrics:**
- Prometheus scraping — assumed external to this repo; every `mcp-*` host
  exposes a narrow nftables carve-out to one configured source IP
  (`modules/mcp-prom-exporters.nix:72-111`)
- `services.prometheus.exporters.node` enabled on every `mcp-*` host
  (`mcp-prom-exporters.nix:90-95`, port 9100)
- Vector self-metrics via `prometheus_exporter` sink bound on the LXC IP
  at 9598 (`vector-audit-client.nix:197-201`)
- ClickHouse built-in `/metrics` on port 9363
  (`modules/mcp-audit.nix:165-177`)
- Service-specific exporter ports documented in
  `mcp-prom-exporters.nix:43-58`: `7777` nats-exporter, `9187`
  postgres_exporter, `9121` redis_exporter

**Logs:**
- journald on every host; republished as `audit.journal.<host>` to NATS
  by Vector; archived to `/var/log/journal/remote/` on `mcp-audit`
- D-10 disk-utilization check — 15-minute timer warning to journald at
  ≥70% (`modules/mcp-audit.nix:387-403`)

## CI/CD & Deployment

**Hosting:** Self-hosted — Proxmox LXC containers on nodes `pm01..03`.

**CI pipeline:** None committed to this tree (no `.github/workflows/`,
no `.gitlab-ci.yml`). Flake-check assertions in `nixos/flake.nix:116-384`
are the gate; expected to be run manually or via `just check`.

**Deploy pipeline:**
1. `terraform apply` in `terraform/` — provisions LXCs and then invokes
   `scripts/bootstrap-host.sh <hostname>` per container via
   `null_resource.nixos_deploy` (`terraform/main.tf:55-77`)
2. `bootstrap-host.sh` — pushes age key (first run only), then runs
   `nixos-rebuild switch --flake nixos#<host> --target-host
   eve@<host>.samesies.gay --use-remote-sudo --fast`
3. `system.autoUpgrade` — pulls `github:escidmore/hermes-deploy?dir=nixos`
   nightly at 04:00 with 45-minute jitter, `allowReboot = false`
   (`modules/common.nix:32-43`); disabled on `mcp-audit`
4. Cert renewal — systemd timers fire every 12h to re-mint 24h step-ca
   certs for NATS servers and Vector clients

**Template pipeline:**
- Documented in `docs/template-workflow.md`; NixOS LXC template built
  via `nixos-rebuild build-image --image-variant proxmox-lxc` (implied;
  template file id passed to Terraform as `var.template_file_id`,
  `terraform/main.tf:17`)

## Environment Configuration

**Required env vars (operator workstation):**
- `SOPS_AGE_KEY_FILE` — path to age private key
  (`scripts/bootstrap-host.sh:49-50`)
- `MCP_DOMAIN` — defaults to `samesies.gay`, overridable
  (`bootstrap-host.sh:18`, injected by Terraform in `main.tf:73-75`)
- `DEPLOY_USER` — defaults to `eve` (`bootstrap-host.sh:19`)

**Required Terraform inputs (from `terraform.tfvars`, gitignored):**
- `virtual_environment_endpoint`, `virtual_environment_api_token`,
  `virtual_environment_ssh_username`, `virtual_environment_insecure`
- `template_file_id`
- Optional overrides: `hermes_repo_path` (default
  `/home/eve/repo/hermes-deploy`), `nixos_deploy_enabled` (default
  `true`)

**Secrets location on disk:**
- Workstation: `~/.config/sops/age/keys.txt` + sops-encrypted files under
  `nixos/secrets/`
- Target LXCs: `/var/lib/sops-nix/key.txt` (600 root:root) for the age
  identity; plaintext decrypted at activation into `/run/secrets/<name>`
  by sops-nix

## Webhooks & Callbacks

**Incoming:**
- Hermes agent API server — `0.0.0.0:8642` LAN-scoped to `10.0.1.0/24`
  via `networking.firewall.extraInputRules`
  (`hosts/hermes/default.nix:525-526,559-561`)
- OTLP HTTP receivers — `127.0.0.1:4318` on every host
  (`modules/otlp-nats-publisher.nix:29-37`)
- Langfuse web — `127.0.0.1:3000` on `mcp-audit`
  (`modules/mcp-audit.nix:227-231`), SSH-tunnel reach only
- step-ca ACME — `0.0.0.0:8443` on `mcp-audit`, nftables-scoped to
  the audit-plane allowlist (`hosts/mcp-audit/default.nix:123-132`)
- NATS — 4222/6222/8222 on `mcp-nats01..03`, nftables-scoped per host

**Outgoing:**
- Proxmox API (Terraform provider)
- step-ca (clients — NATS, Vector — call `/health` and ACME endpoints)
- `https://minio.samesies.gay` (Langfuse web + worker S3 clients)
- `github.com/escidmore/hermes-deploy` (`system.autoUpgrade` nightly pull)
- `github.com/NousResearch/hermes-agent` (flake input, at evaluation time)
- `github.com/NixOS/nixpkgs`, `github.com/Mic92/sops-nix`,
  `github.com/nix-community/disko`, `github.com/oxalica/rust-overlay`
  (flake inputs)
- `deb.nodesource.com` (one-time Node 22 install inside the hermes-agent
  container, `hosts/hermes/default.nix:62-63`)
- Third-party LLM / messaging APIs listed under the hermes-agent section
  above

---

*Integration audit: 2026-04-22*
