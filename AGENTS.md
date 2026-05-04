<!-- GSD:project-start source:PROJECT.md -->
## Project

**Homelab Deploy**

Homelab Deploy is the declarative control repo for maintaining the whole homelab,
not just the Hermes host. It expands the existing `homelab` Proxmox LXC and
NixOS deployment system to cover workstation Home Manager configuration and the
existing Talos/Flux Kubernetes environment, with a practical path for moving low-
utilization services out of Kubernetes and into LXC containers.

**Core Value:** The homelab can be understood, changed, and recovered from one coherent source of
truth while keeping each platform's responsibilities clear.

### Constraints

- **Repo safety**: `.planning/` remains local-only for this initialization — the
  user selected not to commit planning docs.
- **Secrets**: SOPS-encrypted files, age keys, Flux deploy keys, Talos secrets,
  Terraform variables, and private credentials must not be decrypted into tracked
  files or committed.
- **Platform boundaries**: Terraform should continue to own Proxmox envelopes;
  NixOS should own guest convergence; Flux should own Kubernetes changes that
  remain in Kubernetes; Home Manager should own user-level workstation state.
- **Continuity**: Existing Hermes and MCP audit-plane deploy workflows must keep
  working while the repo is renamed and expanded.
- **Resource pressure**: Migration decisions should prioritize reducing reserved
  memory waste on Proxmox, especially for low-duty-cycle services.
- **Incrementality**: Kubernetes-to-LXC moves need per-service cutover and
  rollback, not a big-bang migration.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Nix (flakes, NixOS modules) — system configuration across `nixos/flake.nix`,
- HCL (Terraform) — infrastructure-as-code across `terraform/*.tf` and
- Bash — operator workflows in `scripts/*.sh` and `nixos/tests/*.sh`; all
- Python 3.11+ — two small services in `nixos/pkgs/langfuse-nats-ingest/`
- SQL — `nixos/hosts/mcp-audit/clickhouse-schema.sql` (Langfuse ClickHouse
- YAML — sops-encrypted secrets (`nixos/secrets/*.yaml`) and unencrypted
- JSON Schema — `terraform/contracts/nixos-hosts.schema.json`
- Fish shell — used as the default login shell; also the shell used by
## Runtime
- Nixpkgs channel: `github:NixOS/nixpkgs/nixos-25.11` (`nixos/flake.nix:5`)
- NixOS `system.stateVersion = "25.11"` on every host
- Experimental features enabled in `nixos/modules/common.nix:13-17`:
- Automatic garbage collection: weekly, `--delete-older-than 14d`
- `auto-optimise-store = true`; `nix.settings.sandbox = false` in the LXC
- `required_version = "~> 1.14.0"` (`terraform/versions.tf:2` and
- `requires-python = ">=3.11"` in both
- Built through `nixpkgs` `python3Packages.buildPythonApplication`; no
## Frameworks
- `nixpkgs` — `github:NixOS/nixpkgs/nixos-25.11`
- `sops-nix` — `github:Mic92/sops-nix`; primary secrets-management framework,
- `disko` — `github:nix-community/disko`; declarative disk/partition
- `hermes-agent` — `github:NousResearch/hermes-agent`; third-party NixOS
- `rust-overlay` — `github:oxalica/rust-overlay`; applied as a nixpkgs
- `bpg/proxmox` `~> 0.102.0` — primary Proxmox VE provider (LXC
- `hashicorp/null` `~> 3.2.4` — used for `null_resource.nixos_deploy` in
- `services.openssh` — hardened defaults in `nixos/modules/common.nix:58-90`
- `services.fail2ban` — exponential-backoff bantime on top of sshd
- `networking.nftables` — exclusive firewall backend; the legacy
- `systemd` — heavy use of oneshots, timers, and hardening directives
- `virtualisation.oci-containers` + Podman — Langfuse web/worker digest-
- `nixos/pkgs/langfuse-nats-ingest/pyproject.toml:11-13` — `nats-py>=2.7`,
- `nixos/pkgs/otlp-nats-publisher/pyproject.toml:11-13` — `aiohttp>=3.10`,
- Build backend: `setuptools>=68`
## Build & Developer Tooling
- Terraform: run from `terraform/`; `terraform apply` performs end-to-end
- NixOS per-host build: `nix build
- NixOS flake evaluation / checks: `nix flake check --no-build`
- `age` — symmetric age-format key handling
- `nil` — Nix language server
- `nixos-rebuild` — system activation CLI
- `nixfmt-rfc-style` — canonical Nix formatter (also set as
- `sops` — secrets en/decryption CLI
- `ssh-to-age` — converts ed25519 host keys to age recipients
- `just` — command runner (driver for `nixos/justfile`)
- `check` — `nix flake check --no-build`
- `build HOST` — build toplevel without activating
- `switch HOST` — `nixos-rebuild switch` locally
- `dry-run HOST` — `nixos-rebuild dry-activate`
- `deploy HOST TARGET` — wraps `scripts/bootstrap-host.sh` or runs
- `fmt` — `nix fmt`
- `update` — `nix flake update`
- `edit-secrets` — `sops secrets/hermes.yaml`
- `show-recipient` — derives age recipient via `age-keygen -y`
- Shell/editor: `vim`, `helix`, `neovim` (set as `defaultEditor`)
- Search/navigation: `ripgrep`, `fd`, `fzf`, `eza`, `zoxide`
- File processing: `bat`, `jq`, `yq`
- Monitoring: `htop`, `btop`, `ncdu`, `duf`
- Git stack: `git`, `git-lfs`, `gh`, `delta`
- Network: `curl`, `wget`, `httpie`, `dnsutils`
- Ops/secrets: `age`, `sops`, `ssh-to-age`
- Archive: `unzip`, `p7zip`
- Misc: `tree`, `tldr`, `watchexec`, `tmux`, `git.config.init.defaultBranch = "main"`,
## Configuration
- `terraform/provider-variables.tf:1-21` — `virtual_environment_endpoint`,
- `terraform/template-variables.tf` — template image identifier for the LXC
- `terraform/terraform.tfvars` (gitignored) / `terraform/terraform.tfvars.example`
- Host inventory in `terraform/locals.tf:5-70` — per-container map keyed by
- Flake outputs: `nixosConfigurations.{hermes, mcp-nats01..03, mcp-audit}`
- Shared system layer: `nixos/modules/common.nix` (imported by every host
- Per-class profile: `nixos/profiles/lxc.nix` (imports
- `system.autoUpgrade` — enabled in `common.nix:32-43` pointing at
- `time.timeZone = "America/Los_Angeles"` (`common.nix:45`)
- `i18n.defaultLocale = "en_US.UTF-8"` (`common.nix:46`)
- `.planning/`, `.git-backups/`, editor state
- Terraform local artifacts: `.terraform/`, state files, `*.tfvars`
- NixOS local artifacts: `nixos/result`, `nixos/result-*`,
## Platform Requirements
- Tools on PATH: `sops`, `python3`, `ssh`, `nix` (hard-checked in
- `nixos-rebuild` on PATH preferred; otherwise the script falls back to
- Env var: `SOPS_AGE_KEY_FILE` (defaults to `~/.config/sops/age/keys.txt`,
- SSH agent configured — the Proxmox provider uses `ssh.agent = true`
- Proxmox VE cluster with at least three nodes: `pm01`, `pm02`, `pm03`
- `ceph-rbd` datastore available on every node (`terraform/locals.tf:15,31,47,63`)
- `vmbr1` bridge + VLAN 1200 (`terraform/locals.tf:12-13`)
- Proxmox API endpoint reachable with a token; PAM SSH user for the
- NixOS 25.11 LXC image (template file id supplied via
- `operating_system { type = "nixos" }` (`lxc-container/main.tf:60-63`)
## Version Summary
| Component | Version / Pin | Source |
|---|---|---|
| Terraform | `~> 1.14.0` | `terraform/versions.tf:2` |
| `bpg/proxmox` provider | `~> 0.102.0` | `terraform/versions.tf:10-13` |
| `hashicorp/null` provider | `~> 3.2.4` | `terraform/versions.tf:5-8` |
| Nixpkgs | `nixos-25.11` branch | `nixos/flake.nix:5` |
| NixOS `stateVersion` | `25.11` | `nixos/hosts/*/default.nix` |
| Python | `>=3.11` | both `pkgs/*/pyproject.toml` |
| setuptools (build) | `>=68` | both `pkgs/*/pyproject.toml` |
| `nats-py` | `>=2.7` | both `pkgs/*/pyproject.toml` |
| `httpx` | `>=0.27` | `langfuse-nats-ingest/pyproject.toml` |
| `aiohttp` | `>=3.10` | `otlp-nats-publisher/pyproject.toml` |
| Langfuse (web + worker) | tag 3.169.0, pinned by `@sha256:` digest | `nixos/modules/mcp-audit.nix:33-39` |
| PostgreSQL | 17 (`pkgs.postgresql_17`) | `mcp-audit.nix:121` |
| ClickHouse | default nixpkgs (25.x) | `mcp-audit.nix:160` |
| Redis | default nixpkgs (named server `langfuse`) | `mcp-audit.nix:204-210` |
| NATS server | nixpkgs default, JetStream on, JWT "full" resolver | `nixos/modules/nats-cluster.nix:158-219` |
| step-ca | nixpkgs default; 24h cert TTL | `nixos/modules/step-ca.nix:24-64` |
| Vector | nixpkgs default | `nixos/modules/vector-audit-client.nix:139-204` |
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Repository Layout
- `terraform/` — Proxmox LXC provisioning (run `terraform` from here).
- `nixos/` — NixOS guest configuration as a flake (run `nix`/`just` from here).
- `scripts/` — operator scripts that cross the Terraform↔NixOS boundary
- `docs/` — cross-cutting contracts (ownership boundary, handoff, template workflow).
- `.planning/` — untracked GSD planning artifacts (excluded via global
## Nix Style
- **Attribute-set module signature** — every module file starts with a
- **Leading comment block** — non-trivial modules open with a
- **Options first, config second.** Reusable modules expose a typed
- **Enforce invariants at eval time.** Use `assertions = [ { assertion = …;
- **Nullable options for staged rollouts.** When a value isn't available
- **Inline shell via `pkgs.writeShellScript`.** Wrapper scripts called
- **`lib.mkDefault` / `lib.mkForce` are deliberate.** Use `mkDefault` for
- Files are `kebab-case.nix` (`mcp-otel.nix`, `nats-cluster.nix`, `pbs-excludes.nix`).
- Option namespaces use `services.mcp<ProperCase>` (camelCase after the
- Hosts live at `nixos/hosts/<hostname>/default.nix`.
- Profiles live at `nixos/profiles/<role>.nix` (`lxc.nix`, `cloud-vm.nix`).
- Every input uses `inputs.<name>.inputs.nixpkgs.follows = "nixpkgs"` to
- Hosts are assembled through an `mkHost { hostName, modules }` helper
- `specialArgs = { inherit inputs hostName; }` — never `inherit pkgs`;
- `system = "x86_64-linux"`; multi-system support is not in scope.
## Terraform / HCL Style
- `required_version = "~> 1.14.0"` — pessimistic pin to the current
- Providers pinned with `~>` in both root and every module
- `main.tf` — resources and composition only.
- `locals.tf` — data-only local values (e.g. the `containers` inventory
- `providers.tf` — `provider "…" {}` blocks; no resources.
- `versions.tf` — `terraform { required_version; required_providers }`.
- `outputs.tf` — module outputs.
- `variables.tf` / `provider-variables.tf` / `template-variables.tf` —
- `terraform.tfvars.example` committed; actual `*.tfvars` gitignored
- `contracts/*.schema.json` and `examples/*.example.json` hold JSON
- **`for_each` over static resources.** The root module drives every
- **`try(each.value.<key>, <default>)` for optional attrs.** Keeps the
- **`locals` for derivations inside modules.** See
- **`lifecycle.precondition` for invariants.** The LXC module refuses to
- **Security posture hardcoded, not configurable.** The LXC module pins
- **`null_resource` + `local-exec` bridges to NixOS.** `main.tf`'s
- Resources: snake_case (`proxmox_virtual_environment_container.this`).
- Variables: snake_case with descriptive prefixes
- Inventory keys: kebab-case hostnames (`"mcp-nats01"`, `"mcp-audit"`).
## Shell Script Standards
#!/usr/bin/env bash
#
#
- **Positional args with defaulted error:** `hostname="${1:?Usage: $0 <hostname>}"`.
- **Env-var defaults with `:=`:**
- **Absolute repo root resolution** from `$BASH_SOURCE`:
- **Prereq loop** over binaries, failing with a remediation hint:
- **Tmpfs + trap for secrets:** secret-touching scripts create `mktemp -d`,
- **`local` for function-scoped variables.** Functions in
- **shellcheck-clean.** `# shellcheck disable=SC<n>` must be accompanied
- **Idempotent by design.** Every operator script is safe to re-run
- **Skip vs fail.** Integration tests in `nixos/tests/` exit `0` with a
## Secrets Handling
- **Workstation key** lives at `~/.config/sops/age/keys.txt` and is
- **Per-host age keys** are generated by `scripts/add-host.sh <host>`,
- **First-boot delivery** is `scripts/bootstrap-host.sh`: it extracts
- **Every host module** imports `sops-nix.nixosModules.sops` via the
- One YAML anchor per human/host recipient under `keys:`.
- One `creation_rule` per encrypted file, with a `path_regex` pinned to
- Every rule grants `*evelyn` **plus** exactly the hosts that need to
- `nixos/secrets/*.yaml` unless sops-encrypted (check for a `sops:` key
- `nixos/keys.txt`, `nixos/*.age`, `terraform/*.tfvars` — all gitignored
- `nixos/secrets/host-sops-keys.yaml` is committed **only** sops-encrypted
- Commit the `.example` versions (e.g. `terraform/terraform.tfvars.example`,
- Terraform variables or state — `.tfstate` files are gitignored, but
- Nix `configuration.nix` — secrets are always read from
- LLM / agent context — the project's security architecture (see root
## Error Handling
- **Nix:** prefer build-time failure. Use `throw` inside `let` blocks
- **Terraform:** use `lifecycle.precondition` / `postcondition` for
- **Shell:** rely on `set -euo pipefail`. Write explicit `exit 1` with
## Comments
- Cite the decision record (`D-03`, `AUDIT-05`, `Pitfall P9`) that
- Explain **why** something is forbidden or deliberately absent
- `FIXME(Plan NN-NN)` tags reference an open planning task
## Git / Commit Conventions
- Feature branches + PRs; never push directly to `main`.
- Conventional-commit-adjacent subjects seen in `scripts/add-host.sh`
- `.planning/` is **never** committed — it's listed in the root
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- Strict ownership boundary between provisioning (Terraform) and convergence (NixOS), codified in `docs/ownership-boundary.md` and enforced by the `lxc-container` module refusing to accept guest bootstrap inputs (`remote-exec`, `file`).
- Versioned handoff contract (`terraform/contracts/nixos-hosts.schema.json`, `schema_version = 1.0.0`) decouples the two trees — the NixOS side consumes the normalized contract, not provider-internal resource shapes.
- Flake-level eval-time invariants (`nixos/flake.nix` `checks.*`) enforce security/audit posture across every `mcp-*` host before anything builds: no-hermes-reach nftables, digest-pinned Langfuse images, NATS no-anonymous + JWT resolver, 24h step-ca certs, OTEL env-var consistency, PBS exclude baselines.
- Target workload is a planned audit plane — Hermes agent host + 3-node NATS/JetStream cluster + Langfuse sink (`mcp-audit`) — with a one-way security posture: Hermes publishes in, the audit plane never accepts traffic from Hermes.
## Layers
- Purpose: Define the Proxmox-side container envelope (placement, sizing, networking, template, root SSH key) for every host.
- Location: `terraform/main.tf`, `terraform/locals.tf`, `terraform/providers.tf`, `terraform/versions.tf`
- Contains: Container inventory (`local.containers`), `bpg/proxmox ~> 0.102.0` provider config, root composition via `for_each` over the `lxc-container` module, and a `null_resource.nixos_deploy` that shells out to `scripts/bootstrap-host.sh` per host.
- Depends on: `terraform/modules/lxc-container/` (envelope), `terraform/contracts/nixos-hosts.schema.json` (output contract), `scripts/bootstrap-host.sh` (deploy hop).
- Used by: Operator (`terraform apply` from `terraform/`).
- Purpose: Single source of truth for one unprivileged NixOS LXC's Proxmox resource shape. Hardcodes the SAFE-01 posture.
- Location: `terraform/modules/lxc-container/main.tf`, `variables.tf`, `outputs.tf`
- Contains: Exactly one `proxmox_virtual_environment_container.this` with `unprivileged = true`, `features { nesting = true }`, `operating_system.type = "nixos"`, static IPv4 only, at-least-one SSH key precondition.
- Depends on: `bpg/proxmox` provider, `template_file_id` input (the NixOS Proxmox LXC template).
- Used by: `terraform/main.tf` root module only.
- Purpose: Define `nixosConfigurations.<host>` for every guest, build two custom packages (`langfuse-nats-ingest`, `otlp-nats-publisher`), and run eval-time invariant checks.
- Location: `nixos/flake.nix`
- Contains: 5 host configs (`hermes`, `mcp-nats01/02/03`, `mcp-audit`) built via a shared `mkHost` helper; `packages.x86_64-linux`; `devShells.default`; `checks.x86_64-linux` (7 named invariant derivations).
- Depends on: `nixpkgs` (nixos-25.11), `sops-nix`, `disko`, `hermes-agent` (external flake input from `github:NousResearch/hermes-agent`), `rust-overlay`.
- Used by: `nixos-rebuild switch --flake .#<host>`, `nix flake check`, `just check/build/switch/deploy`.
- Purpose: Deployment-target-shaped base modules. One per runtime environment.
- Location: `nixos/profiles/lxc.nix`, `nixos/profiles/cloud-vm.nix`
- Contains: `lxc.nix` imports `<nixpkgs>/modules/virtualisation/proxmox-lxc.nix`, disables `systemd-networkd-wait-online` (LXC hang), turns off `nix.settings.sandbox` (no mount namespace), enables rootful Podman, sets `boot.isContainer = true`. `cloud-vm.nix` is a disko/qemu-guest scaffold for future cloud hosts.
- Depends on: `nixpkgs` virtualisation modules.
- Used by: Every host in `flake.nix` imports exactly one profile.
- Purpose: Compose role modules, declare host-identity values, bind sops secrets, own host-specific nftables tables.
- Location: `nixos/hosts/hermes/default.nix` (hermes-agent + supermemory plugin plumbing, 562 lines), `nixos/hosts/mcp-audit/default.nix` (151 lines), `nixos/hosts/mcp-nats01/02/03/default.nix` (207 lines each, near-identical — deliberately "copy+rename; do not over-DRY").
- Contains: `let` block with host-identity bindings (`lxcIp`, `hermesIp`, `promSourceIp`, `auditPlaneAllowlist`, `sshAllowlist`), `imports` of the relevant `modules/*.nix`, `services.mcp*.enable`/option wiring, per-host `sops.secrets.*` bindings, `networking.nftables.tables.<name>`, `networking.extraHosts`.
- Depends on: `nixos/modules/*.nix`, `nixos/secrets/<host>.yaml`, `../../../docs/ownership-boundary.md` (prose contract).
- Used by: `mkHost` in `nixos/flake.nix`.
- Purpose: Reusable role modules — each module declares a `services.mcp<Role>` option namespace and implements it.
- Location: `nixos/modules/common.nix` (baseline: sshd hardening, fail2ban, sops defaults, auto-upgrade, packages), `nixos/modules/nats-cluster.nix` (JetStream R3 + mTLS + JWT resolver + cert-bootstrap), `nixos/modules/nats-accounts.nix` (operator JWT + credentials materialization), `nixos/modules/mcp-audit.nix` (Langfuse v3 stack: native Postgres/ClickHouse/Redis + digest-pinned oci-containers), `nixos/modules/step-ca.nix` (24h-cert issuer on `mcp-audit`), `nixos/modules/otlp-nats-publisher.nix` (local `127.0.0.1:4318` receiver → `audit.otlp.traces.<host>`), `nixos/modules/vector-audit-client.nix` (journald → `audit.journal.<host>`), `nixos/modules/mcp-otel.nix` (shared OTEL env), `nixos/modules/mcp-prom-exporters.nix` (narrow Prom carve-out), `nixos/modules/pbs-excludes.nix` (backup exclude baseline).
- Contains: NixOS `options.services.mcp<X>` + `config` implementations, systemd units, tmpfiles rules, sops bindings, embedded shell scripts (`pkgs.writeShellScript`) for cert renewal / health probes.
- Depends on: `common.nix` (sops, sshd), upstream `services.nats`, `services.step-ca`, `services.vector`, `services.clickhouse`, `services.postgresql`, `virtualisation.oci-containers`.
- Used by: `hosts/<host>/default.nix` imports.
- Purpose: Project-local Python packages referenced by modules.
- Location: `nixos/pkgs/otlp-nats-publisher/` (`pkgs.callPackage`'d; OTLP HTTP → NATS publish bridge), `nixos/pkgs/langfuse-nats-ingest/` (NATS subscribe → Langfuse OTLP POST bridge)
- Contains: `default.nix` + `pyproject.toml` + `src/` per package.
- Depends on: `nixpkgs` Python builders, `rust-overlay` (via flake).
- Used by: `modules/otlp-nats-publisher.nix`, `modules/mcp-audit.nix`.
- Purpose: Operator workflows that span both trees.
- Location: `scripts/add-host.sh` (per-host age identity bootstrap), `scripts/bootstrap-host.sh` (push age key + `nixos-rebuild switch --target-host`), `scripts/init-secrets.sh` (NATS NSC operator/account/user + bootstrap secrets generator).
- Contains: Bash scripts, `set -euo pipefail`, invoked from repo root.
- Depends on: `age`, `sops`, `nsc`, `python3`, `jq`, `nixos-rebuild` (or `nix run nixpkgs#nixos-rebuild --`).
- Used by: Operator directly (`./scripts/add-host.sh`, `./scripts/init-secrets.sh`) and by `terraform/main.tf` `null_resource.nixos_deploy` (invokes `bootstrap-host.sh`).
## Data Flow
- `terraform/outputs.tf` emits `nixos_hosts` = `{ schema_version = "1.0.0", hosts = { for k, m in module.lxc_container : k => m.host } }`, plus the schema itself (`nixos_hosts_contract_schema`) and a pinned version (`nixos_hosts_contract_version`).
- Current state: NixOS hosts hard-code their own identity (IPs, VMIDs appear in `hosts/<host>/default.nix` `let` blocks and in `nixos/secrets/*`). The contract is defined and exported but not yet consumed by the flake — future work.
- Terraform state: local `terraform/terraform.tfstate` (+ backup). Remote backend not yet configured.
- NixOS state: declarative, reproduced from flake + sops secrets each rebuild. Host age keys persist at `/var/lib/sops-nix/key.txt`.
- sops/age: workstation key at `~/.config/sops/age/keys.txt`, per-host keys stored encrypted in `nixos/secrets/host-sops-keys.yaml` (sops-encrypted under the workstation recipient).
## Key Abstractions
- Purpose: Every `mcp-*` host starts with a `let` block of identity constants (`lxcIp`, `hermesIp`, `promSourceIp`, `auditPlaneAllowlist`, `sshAllowlist`).
- Examples: `nixos/hosts/mcp-nats01/default.nix` lines 18–48, `nixos/hosts/mcp-audit/default.nix` lines 19–49.
- Pattern: `hermesIp` is bound but deliberately **not referenced in any accept rule** — that absence is the AUDIT-03/D-11 invariant; `flake.nix` `checks.assert-no-hermes-reach` enforces it.
- Purpose: Project-local NixOS modules expose their config under `services.mcp<Role>`.
- Examples: `services.mcpNatsCluster`, `services.mcpNatsAccounts`, `services.mcpVectorAuditClient`, `services.mcpOtlpNatsPublisher`, `services.mcpPromExporters`, `services.mcpAuditPbs`.
- Pattern: Each module declares `options.services.mcp<Role> = { enable = mkEnableOption; ... }` and conditional `config = mkIf cfg.enable { ... }`.
- Purpose: Cross-host security/audit posture enforcement before any host builds.
- Examples: `assert-no-hermes-reach`, `assert-prom-carveout-narrow`, `nats-no-anonymous`, `mcp-audit-pbs-excludes`, `step-ca-cert-duration-24h`, `langfuse-image-pinned-by-digest`, `otel-module-consistent`.
- Pattern: Each check filters `nixosConfigurations` by hostname prefix (`mcp-`, `mcp-nats-`) or by option value (`services.step-ca.enable`), then either evaluates a `pkgs.runCommand` that greps rendered config strings or `throw`s directly in Nix. Vacuous pass when the filter yields `[]`.
- Purpose: New host has no age key yet, so `nix flake check` on a clean clone would fail evaluating encrypted `secrets/<host>.yaml`.
- Examples: `hosts/mcp-nats01/default.nix` lines 77–105 set `sops.validateSopsFiles = false` until the real encrypted file lands.
- Pattern: `.yaml.example` template committed plaintext; `scripts/add-host.sh` generates per-host age key, inserts into `.sops.yaml` + stashes in `secrets/host-sops-keys.yaml`; operator populates `.yaml`, runs `sops -e -i`, flips `validateSopsFiles` back.
- Purpose: NATS operator/account/user JWTs, credentials, and publish ACLs materialized from `nsc` CLI into sops-encrypted yaml.
- Examples: `scripts/init-secrets.sh` creates the `mcp-audit-cluster` operator, `AUDIT` account, per-host `vector-mcp-nats01/02/03` users with per-host `audit.otlp.traces.<host>`/`audit.journal.<host>` publish ACLs.
## Entry Points
- Location: `terraform/main.tf`
- Triggers: Operator.
- Responsibilities: Provision/update every container in `local.containers`, then invoke `scripts/bootstrap-host.sh` per host for NixOS convergence.
- Location: `nixos/flake.nix` `nixosConfigurations.<host>`
- Triggers: Operator directly, `scripts/bootstrap-host.sh` via `--target-host`, or the daily auto-upgrade timer (`system.autoUpgrade` in `nixos/modules/common.nix` at 04:00 from `github:chmodxheart/hermes-deploy?dir=nixos`). Audit-plane hosts override auto-upgrade with `mkForce false`.
- Responsibilities: Evaluate the flake for `<host>`, build the toplevel derivation, activate on target.
- Location: `nixos/flake.nix` `checks.x86_64-linux`
- Triggers: Operator, `just check`, CI.
- Responsibilities: Run all eval-time invariant derivations across every `nixosConfiguration`.
- Location: `scripts/add-host.sh`
- Triggers: Operator before adding a new NixOS host.
- Responsibilities: Generate per-host age keypair (in tmpfs, shredded on exit), insert public recipient into `nixos/.sops.yaml`, stash private key in `nixos/secrets/host-sops-keys.yaml` via `sops set`, re-encrypt `secrets/<host>.yaml` for the new recipient.
- Location: `scripts/init-secrets.sh`
- Triggers: Operator for one-time NATS bring-up.
- Responsibilities: Create NSC operator/account/users, generate `nats_operator_jwt` / per-host creds / Langfuse env / Postgres/ClickHouse/Redis passwords, write sops-encrypted `secrets/{nats-operator,mcp-audit,mcp-nats01/02/03}.yaml`.
## Error Handling
- Flake checks `throw` synchronously during Nix evaluation for policy violations (`nats-no-anonymous`, `step-ca-cert-duration-24h`, `mcp-audit-pbs-excludes`).
- Shell scripts use `set -euo pipefail`, check prerequisites (`command -v`) up front, and refuse to clobber (`add-host.sh` won't overwrite a real age key).
- Systemd units in `modules/nats-cluster.nix` and `modules/mcp-audit.nix` gate with `ExecStartPre` health loops (`waitForStepCa`, `waitForLangfuseWeb`) to handle cert-bootstrap ordering (Pitfall P9) and migration ordering.
- Terraform `lifecycle.precondition` in `modules/lxc-container/main.tf` asserts at least one SSH key is provided before the resource plans.
## Cross-Cutting Concerns
- Terraform: `versions.tf` pins `terraform ~> 1.14.0`, `bpg/proxmox ~> 0.102.0`, `hashicorp/null ~> 3.2.4`; JSON schema at `terraform/contracts/nixos-hosts.schema.json` with `schema_version` pinning.
- NixOS: `nix flake check` runs every `checks.*` invariant; assertions + absence-of-option inside modules (e.g. `nats-cluster.nix` forbids `allow_anonymous`).
- Proxmox: API token (`var.virtual_environment_api_token`) + SSH agent passthrough (`var.virtual_environment_ssh_username`). Both are input variables, not committed.
- SSH to guests: ed25519 only, no passwords, no root login (enforced in `common.nix`).
- NATS: mTLS (24h step-ca certs) + JWT resolver (operator/account/user via NSC); no anonymous publishers.
- Secrets: sops + age, per-host recipients in `.sops.yaml`, decryption happens on-host via `/var/lib/sops-nix/key.txt` delivered by `scripts/bootstrap-host.sh`.
- Every host enables `networking.nftables.enable = true` + `firewall.enable = true` via `common.nix`.
- Audit-plane hosts add per-host `networking.nftables.tables.*` with explicit allowlists; `hermesIp` is bound in `let` but never referenced in accept rules (AUDIT-03).
- Prometheus scrape ports (9100/9598/7777) are opened only via `modules/mcp-prom-exporters.nix` scoped to `promSourceIp` (narrow carve-out; wildcards rejected by `assert-prom-carveout-narrow`).
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
