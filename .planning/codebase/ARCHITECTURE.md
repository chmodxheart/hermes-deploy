# Architecture

**Analysis Date:** 2026-04-22

## Pattern Overview

**Overall:** Two-tier IaC monorepo — Terraform owns the Proxmox container envelope, NixOS flake owns all guest state. A thin shell-script seam between them turns `terraform apply` into a one-command end-to-end bring-up.

**Key Characteristics:**
- Strict ownership boundary between provisioning (Terraform) and convergence (NixOS), codified in `docs/ownership-boundary.md` and enforced by the `lxc-container` module refusing to accept guest bootstrap inputs (`remote-exec`, `file`).
- Versioned handoff contract (`terraform/contracts/nixos-hosts.schema.json`, `schema_version = 1.0.0`) decouples the two trees — the NixOS side consumes the normalized contract, not provider-internal resource shapes.
- Flake-level eval-time invariants (`nixos/flake.nix` `checks.*`) enforce security/audit posture across every `mcp-*` host before anything builds: no-hermes-reach nftables, digest-pinned Langfuse images, NATS no-anonymous + JWT resolver, 24h step-ca certs, OTEL env-var consistency, PBS exclude baselines.
- Target workload is a planned audit plane — Hermes agent host + 3-node NATS/JetStream cluster + Langfuse sink (`mcp-audit`) — with a one-way security posture: Hermes publishes in, the audit plane never accepts traffic from Hermes.

## Layers

**Terraform root (`terraform/`):**
- Purpose: Define the Proxmox-side container envelope (placement, sizing, networking, template, root SSH key) for every host.
- Location: `terraform/main.tf`, `terraform/locals.tf`, `terraform/providers.tf`, `terraform/versions.tf`
- Contains: Container inventory (`local.containers`), `bpg/proxmox ~> 0.102.0` provider config, root composition via `for_each` over the `lxc-container` module, and a `null_resource.nixos_deploy` that shells out to `scripts/bootstrap-host.sh` per host.
- Depends on: `terraform/modules/lxc-container/` (envelope), `terraform/contracts/nixos-hosts.schema.json` (output contract), `scripts/bootstrap-host.sh` (deploy hop).
- Used by: Operator (`terraform apply` from `terraform/`).

**Terraform module (`terraform/modules/lxc-container/`):**
- Purpose: Single source of truth for one unprivileged NixOS LXC's Proxmox resource shape. Hardcodes the SAFE-01 posture.
- Location: `terraform/modules/lxc-container/main.tf`, `variables.tf`, `outputs.tf`
- Contains: Exactly one `proxmox_virtual_environment_container.this` with `unprivileged = true`, `features { nesting = true }`, `operating_system.type = "nixos"`, static IPv4 only, at-least-one SSH key precondition.
- Depends on: `bpg/proxmox` provider, `template_file_id` input (the NixOS Proxmox LXC template).
- Used by: `terraform/main.tf` root module only.

**NixOS flake (`nixos/flake.nix`):**
- Purpose: Define `nixosConfigurations.<host>` for every guest, build two custom packages (`langfuse-nats-ingest`, `otlp-nats-publisher`), and run eval-time invariant checks.
- Location: `nixos/flake.nix`
- Contains: 5 host configs (`hermes`, `mcp-nats01/02/03`, `mcp-audit`) built via a shared `mkHost` helper; `packages.x86_64-linux`; `devShells.default`; `checks.x86_64-linux` (7 named invariant derivations).
- Depends on: `nixpkgs` (nixos-25.11), `sops-nix`, `disko`, `hermes-agent` (external flake input from `github:NousResearch/hermes-agent`), `rust-overlay`.
- Used by: `nixos-rebuild switch --flake .#<host>`, `nix flake check`, `just check/build/switch/deploy`.

**NixOS profiles (`nixos/profiles/`):**
- Purpose: Deployment-target-shaped base modules. One per runtime environment.
- Location: `nixos/profiles/lxc.nix`, `nixos/profiles/cloud-vm.nix`
- Contains: `lxc.nix` imports `<nixpkgs>/modules/virtualisation/proxmox-lxc.nix`, disables `systemd-networkd-wait-online` (LXC hang), turns off `nix.settings.sandbox` (no mount namespace), enables rootful Podman, sets `boot.isContainer = true`. `cloud-vm.nix` is a disko/qemu-guest scaffold for future cloud hosts.
- Depends on: `nixpkgs` virtualisation modules.
- Used by: Every host in `flake.nix` imports exactly one profile.

**NixOS hosts (`nixos/hosts/<host>/default.nix`):**
- Purpose: Compose role modules, declare host-identity values, bind sops secrets, own host-specific nftables tables.
- Location: `nixos/hosts/hermes/default.nix` (hermes-agent + supermemory plugin plumbing, 562 lines), `nixos/hosts/mcp-audit/default.nix` (151 lines), `nixos/hosts/mcp-nats01/02/03/default.nix` (207 lines each, near-identical — deliberately "copy+rename; do not over-DRY").
- Contains: `let` block with host-identity bindings (`lxcIp`, `hermesIp`, `promSourceIp`, `auditPlaneAllowlist`, `sshAllowlist`), `imports` of the relevant `modules/*.nix`, `services.mcp*.enable`/option wiring, per-host `sops.secrets.*` bindings, `networking.nftables.tables.<name>`, `networking.extraHosts`.
- Depends on: `nixos/modules/*.nix`, `nixos/secrets/<host>.yaml`, `../../../docs/ownership-boundary.md` (prose contract).
- Used by: `mkHost` in `nixos/flake.nix`.

**NixOS modules (`nixos/modules/`):**
- Purpose: Reusable role modules — each module declares a `services.mcp<Role>` option namespace and implements it.
- Location: `nixos/modules/common.nix` (baseline: sshd hardening, fail2ban, sops defaults, auto-upgrade, packages), `nixos/modules/nats-cluster.nix` (JetStream R3 + mTLS + JWT resolver + cert-bootstrap), `nixos/modules/nats-accounts.nix` (operator JWT + credentials materialization), `nixos/modules/mcp-audit.nix` (Langfuse v3 stack: native Postgres/ClickHouse/Redis + digest-pinned oci-containers), `nixos/modules/step-ca.nix` (24h-cert issuer on `mcp-audit`), `nixos/modules/otlp-nats-publisher.nix` (local `127.0.0.1:4318` receiver → `audit.otlp.traces.<host>`), `nixos/modules/vector-audit-client.nix` (journald → `audit.journal.<host>`), `nixos/modules/mcp-otel.nix` (shared OTEL env), `nixos/modules/mcp-prom-exporters.nix` (narrow Prom carve-out), `nixos/modules/pbs-excludes.nix` (backup exclude baseline).
- Contains: NixOS `options.services.mcp<X>` + `config` implementations, systemd units, tmpfiles rules, sops bindings, embedded shell scripts (`pkgs.writeShellScript`) for cert renewal / health probes.
- Depends on: `common.nix` (sops, sshd), upstream `services.nats`, `services.step-ca`, `services.vector`, `services.clickhouse`, `services.postgresql`, `virtualisation.oci-containers`.
- Used by: `hosts/<host>/default.nix` imports.

**NixOS packages (`nixos/pkgs/`):**
- Purpose: Project-local Python packages referenced by modules.
- Location: `nixos/pkgs/otlp-nats-publisher/` (`pkgs.callPackage`'d; OTLP HTTP → NATS publish bridge), `nixos/pkgs/langfuse-nats-ingest/` (NATS subscribe → Langfuse OTLP POST bridge)
- Contains: `default.nix` + `pyproject.toml` + `src/` per package.
- Depends on: `nixpkgs` Python builders, `rust-overlay` (via flake).
- Used by: `modules/otlp-nats-publisher.nix`, `modules/mcp-audit.nix`.

**Scripts (`scripts/`):**
- Purpose: Operator workflows that span both trees.
- Location: `scripts/add-host.sh` (per-host age identity bootstrap), `scripts/bootstrap-host.sh` (push age key + `nixos-rebuild switch --target-host`), `scripts/init-secrets.sh` (NATS NSC operator/account/user + bootstrap secrets generator).
- Contains: Bash scripts, `set -euo pipefail`, invoked from repo root.
- Depends on: `age`, `sops`, `nsc`, `python3`, `jq`, `nixos-rebuild` (or `nix run nixpkgs#nixos-rebuild --`).
- Used by: Operator directly (`./scripts/add-host.sh`, `./scripts/init-secrets.sh`) and by `terraform/main.tf` `null_resource.nixos_deploy` (invokes `bootstrap-host.sh`).

## Data Flow

**End-to-end host bring-up (`terraform apply`):**

1. Operator runs `terraform apply` in `terraform/`.
2. Root module iterates `local.containers` with `for_each` and calls `module.lxc_container` per entry. Each call creates one `proxmox_virtual_environment_container` via `bpg/proxmox` against Proxmox (`var.virtual_environment_endpoint`, API token + SSH agent auth).
3. Container boots from `var.template_file_id` (Proxmox file ID of a prebuilt NixOS LXC template produced by `nixos-rebuild build-image --image-variant proxmox-lxc`).
4. `depends_on = [module.lxc_container]` gates the `null_resource.nixos_deploy` per host.
5. `null_resource.nixos_deploy` runs `scripts/bootstrap-host.sh <hostname>` as a `local-exec` with `MCP_DOMAIN = "samesies.gay"`.
6. `bootstrap-host.sh` SSH-polls `eve@<host>.<domain>` for 60s, decrypts `nixos/secrets/host-sops-keys.yaml` with the workstation age key, extracts that host's age private key, and installs it at `/var/lib/sops-nix/key.txt` (0600, root:root) via `sudo` — unless the file is already present (idempotent).
7. `bootstrap-host.sh` runs `nixos-rebuild switch --flake "$nixos_root#<host>" --target-host "$target" --use-remote-sudo --fast`.
8. On-host: `sops-nix` decrypts `nixos/secrets/<host>.yaml` using `/var/lib/sops-nix/key.txt`, materializes `/run/secrets/*`, activates the new generation.
9. `triggers.rebuild_at = timestamp()` forces re-execution on every apply — NixOS flake changes converge without a Terraform-side diff.

**Contract handoff (Terraform → NixOS):**

- `terraform/outputs.tf` emits `nixos_hosts` = `{ schema_version = "1.0.0", hosts = { for k, m in module.lxc_container : k => m.host } }`, plus the schema itself (`nixos_hosts_contract_schema`) and a pinned version (`nixos_hosts_contract_version`).
- Current state: NixOS hosts hard-code their own identity (IPs, VMIDs appear in `hosts/<host>/default.nix` `let` blocks and in `nixos/secrets/*`). The contract is defined and exported but not yet consumed by the flake — future work.

**Audit-plane runtime data flow:**

1. Any audit-plane host publishes its own OTLP traces to `127.0.0.1:4318` (local `otlp-nats-publisher`, `modules/otlp-nats-publisher.nix`), which forwards to subject `audit.otlp.traces.<host>` on the NATS cluster.
2. Journald events flow through a local Vector client (`modules/vector-audit-client.nix`) to subject `audit.journal.<host>`.
3. `mcp-nats01/02/03` form a 3-node JetStream cluster (`modules/nats-cluster.nix`). mTLS with 24h step-ca-issued certs; publish ACLs scoped per-user via NSC (`scripts/init-secrets.sh`).
4. On `mcp-audit` (`modules/mcp-audit.nix`): `langfuse-nats-ingest` subscribes `audit.otlp.>` and POSTs to local Langfuse; the Vector consumer subscribes `audit.journal.>` and writes to `/var/log/journal/remote/`. Langfuse web+worker (digest-pinned oci-containers) persist to native Postgres/ClickHouse/Redis on the same host; object storage is external MinIO (`https://minio.samesies.gay`).
5. `step-ca` is co-located on `mcp-audit` (`modules/step-ca.nix`) and issues short-lived TLS for NATS servers and every audit-plane client.

**State Management:**
- Terraform state: local `terraform/terraform.tfstate` (+ backup). Remote backend not yet configured.
- NixOS state: declarative, reproduced from flake + sops secrets each rebuild. Host age keys persist at `/var/lib/sops-nix/key.txt`.
- sops/age: workstation key at `~/.config/sops/age/keys.txt`, per-host keys stored encrypted in `nixos/secrets/host-sops-keys.yaml` (sops-encrypted under the workstation recipient).

## Key Abstractions

**Host identity binding (`let` block pattern):**
- Purpose: Every `mcp-*` host starts with a `let` block of identity constants (`lxcIp`, `hermesIp`, `promSourceIp`, `auditPlaneAllowlist`, `sshAllowlist`).
- Examples: `nixos/hosts/mcp-nats01/default.nix` lines 18–48, `nixos/hosts/mcp-audit/default.nix` lines 19–49.
- Pattern: `hermesIp` is bound but deliberately **not referenced in any accept rule** — that absence is the AUDIT-03/D-11 invariant; `flake.nix` `checks.assert-no-hermes-reach` enforces it.

**`services.mcp*` option namespace:**
- Purpose: Project-local NixOS modules expose their config under `services.mcp<Role>`.
- Examples: `services.mcpNatsCluster`, `services.mcpNatsAccounts`, `services.mcpVectorAuditClient`, `services.mcpOtlpNatsPublisher`, `services.mcpPromExporters`, `services.mcpAuditPbs`.
- Pattern: Each module declares `options.services.mcp<Role> = { enable = mkEnableOption; ... }` and conditional `config = mkIf cfg.enable { ... }`.

**Eval-time invariant checks (`flake.nix` `checks.*`):**
- Purpose: Cross-host security/audit posture enforcement before any host builds.
- Examples: `assert-no-hermes-reach`, `assert-prom-carveout-narrow`, `nats-no-anonymous`, `mcp-audit-pbs-excludes`, `step-ca-cert-duration-24h`, `langfuse-image-pinned-by-digest`, `otel-module-consistent`.
- Pattern: Each check filters `nixosConfigurations` by hostname prefix (`mcp-`, `mcp-nats-`) or by option value (`services.step-ca.enable`), then either evaluates a `pkgs.runCommand` that greps rendered config strings or `throw`s directly in Nix. Vacuous pass when the filter yields `[]`.

**Two-stage sops bootstrap:**
- Purpose: New host has no age key yet, so `nix flake check` on a clean clone would fail evaluating encrypted `secrets/<host>.yaml`.
- Examples: `hosts/mcp-nats01/default.nix` lines 77–105 set `sops.validateSopsFiles = false` until the real encrypted file lands.
- Pattern: `.yaml.example` template committed plaintext; `scripts/add-host.sh` generates per-host age key, inserts into `.sops.yaml` + stashes in `secrets/host-sops-keys.yaml`; operator populates `.yaml`, runs `sops -e -i`, flips `validateSopsFiles` back.

**NSC-driven NATS identity:**
- Purpose: NATS operator/account/user JWTs, credentials, and publish ACLs materialized from `nsc` CLI into sops-encrypted yaml.
- Examples: `scripts/init-secrets.sh` creates the `mcp-audit-cluster` operator, `AUDIT` account, per-host `vector-mcp-nats01/02/03` users with per-host `audit.otlp.traces.<host>`/`audit.journal.<host>` publish ACLs.

## Entry Points

**`terraform apply` (from `terraform/`):**
- Location: `terraform/main.tf`
- Triggers: Operator.
- Responsibilities: Provision/update every container in `local.containers`, then invoke `scripts/bootstrap-host.sh` per host for NixOS convergence.

**`nixos-rebuild switch --flake .#<host>` (from `nixos/` or on-host):**
- Location: `nixos/flake.nix` `nixosConfigurations.<host>`
- Triggers: Operator directly, `scripts/bootstrap-host.sh` via `--target-host`, or the daily auto-upgrade timer (`system.autoUpgrade` in `nixos/modules/common.nix` at 04:00 from `github:escidmore/hermes-deploy?dir=nixos`). Audit-plane hosts override auto-upgrade with `mkForce false`.
- Responsibilities: Evaluate the flake for `<host>`, build the toplevel derivation, activate on target.

**`nix flake check` (from `nixos/`):**
- Location: `nixos/flake.nix` `checks.x86_64-linux`
- Triggers: Operator, `just check`, CI.
- Responsibilities: Run all eval-time invariant derivations across every `nixosConfiguration`.

**`./scripts/add-host.sh <hostname>` (from repo root):**
- Location: `scripts/add-host.sh`
- Triggers: Operator before adding a new NixOS host.
- Responsibilities: Generate per-host age keypair (in tmpfs, shredded on exit), insert public recipient into `nixos/.sops.yaml`, stash private key in `nixos/secrets/host-sops-keys.yaml` via `sops set`, re-encrypt `secrets/<host>.yaml` for the new recipient.

**`./scripts/init-secrets.sh` (from repo root):**
- Location: `scripts/init-secrets.sh`
- Triggers: Operator for one-time NATS bring-up.
- Responsibilities: Create NSC operator/account/users, generate `nats_operator_jwt` / per-host creds / Langfuse env / Postgres/ClickHouse/Redis passwords, write sops-encrypted `secrets/{nats-operator,mcp-audit,mcp-nats01/02/03}.yaml`.

## Error Handling

**Strategy:** Fail fast at eval time wherever possible; idempotent scripts with SSH reachability polling at run time.

**Patterns:**
- Flake checks `throw` synchronously during Nix evaluation for policy violations (`nats-no-anonymous`, `step-ca-cert-duration-24h`, `mcp-audit-pbs-excludes`).
- Shell scripts use `set -euo pipefail`, check prerequisites (`command -v`) up front, and refuse to clobber (`add-host.sh` won't overwrite a real age key).
- Systemd units in `modules/nats-cluster.nix` and `modules/mcp-audit.nix` gate with `ExecStartPre` health loops (`waitForStepCa`, `waitForLangfuseWeb`) to handle cert-bootstrap ordering (Pitfall P9) and migration ordering.
- Terraform `lifecycle.precondition` in `modules/lxc-container/main.tf` asserts at least one SSH key is provided before the resource plans.

## Cross-Cutting Concerns

**Logging:** Systemd journald per host. Audit-plane hosts publish their own journald to `audit.journal.<host>` via the local Vector client, which `mcp-audit` consumes into `/var/log/journal/remote/`.

**Validation:**
- Terraform: `versions.tf` pins `terraform ~> 1.14.0`, `bpg/proxmox ~> 0.102.0`, `hashicorp/null ~> 3.2.4`; JSON schema at `terraform/contracts/nixos-hosts.schema.json` with `schema_version` pinning.
- NixOS: `nix flake check` runs every `checks.*` invariant; assertions + absence-of-option inside modules (e.g. `nats-cluster.nix` forbids `allow_anonymous`).

**Authentication:**
- Proxmox: API token (`var.virtual_environment_api_token`) + SSH agent passthrough (`var.virtual_environment_ssh_username`). Both are input variables, not committed.
- SSH to guests: ed25519 only, no passwords, no root login (enforced in `common.nix`).
- NATS: mTLS (24h step-ca certs) + JWT resolver (operator/account/user via NSC); no anonymous publishers.
- Secrets: sops + age, per-host recipients in `.sops.yaml`, decryption happens on-host via `/var/lib/sops-nix/key.txt` delivered by `scripts/bootstrap-host.sh`.

**Network Posture:**
- Every host enables `networking.nftables.enable = true` + `firewall.enable = true` via `common.nix`.
- Audit-plane hosts add per-host `networking.nftables.tables.*` with explicit allowlists; `hermesIp` is bound in `let` but never referenced in accept rules (AUDIT-03).
- Prometheus scrape ports (9100/9598/7777) are opened only via `modules/mcp-prom-exporters.nix` scoped to `promSourceIp` (narrow carve-out; wildcards rejected by `assert-prom-carveout-narrow`).

---

*Architecture analysis: 2026-04-22*
