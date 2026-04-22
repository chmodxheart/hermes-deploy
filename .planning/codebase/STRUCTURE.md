# Codebase Structure

**Analysis Date:** 2026-04-22

## Directory Layout

```
hermes-deploy/
├── README.md                       # Monorepo entrypoint + security/audit rationale
├── docs/                           # Cross-tree contracts and runtime data-flow
├── nixos/                          # NixOS flake — guest configuration subtree
│   ├── flake.nix                   # Inputs, nixosConfigurations, packages, checks
│   ├── flake.lock
│   ├── justfile                    # fish-only recipes: check/build/switch/deploy/fmt
│   ├── README.md                   # NixOS subtree entrypoint + bring-up runbook
│   ├── docs/ops/                   # NixOS operator runbooks (guest-side only)
│   ├── hosts/                      # Per-host compositions (one subdir per host)
│   │   ├── hermes/default.nix      # Hermes agent LXC (562 lines)
│   │   ├── mcp-audit/              # Audit sink LXC (Langfuse + step-ca + journal archive)
│   │   ├── mcp-nats01/default.nix  # NATS/JetStream member 1 (207 lines)
│   │   ├── mcp-nats02/default.nix  # NATS/JetStream member 2 (near-identical to 01)
│   │   └── mcp-nats03/default.nix  # NATS/JetStream member 3 (near-identical to 01)
│   ├── modules/                    # Reusable role modules (services.mcp* namespace)
│   ├── pkgs/                       # Project-local Python packages (pkgs.callPackage)
│   │   ├── langfuse-nats-ingest/
│   │   └── otlp-nats-publisher/
│   ├── profiles/                   # Deployment-target base modules
│   │   ├── lxc.nix                 # Proxmox LXC tweaks + podman
│   │   └── cloud-vm.nix            # disko + qemu-guest scaffold (future)
│   ├── secrets/                    # sops-encrypted YAML + *.example templates
│   ├── tests/                      # Per-host assertion scripts + flake-check helpers
│   ├── users/eve.nix               # Login user + SSH key
│   └── scripts/                    # (empty — placeholder)
├── scripts/                        # Operator workflows spanning both trees
│   ├── add-host.sh                 # Per-host age identity bootstrap
│   ├── bootstrap-host.sh           # Age-key push + nixos-rebuild switch (called by terraform)
│   └── init-secrets.sh             # NSC operator/account/user + bootstrap secrets generator
└── terraform/                      # Terraform subtree — Proxmox container envelope
    ├── AGENTS.md                   # Subtree agent context (GSD project block)
    ├── README.md
    ├── main.tf                     # Root composition: for_each over local.containers + nixos_deploy
    ├── locals.tf                   # Container inventory (vmid, ipv4, sizing, tags)
    ├── providers.tf                # bpg/proxmox provider block
    ├── provider-variables.tf       # Proxmox endpoint / token / SSH user / insecure
    ├── template-variables.tf       # template_file_id variable
    ├── versions.tf                 # Terraform + provider version pins
    ├── outputs.tf                  # nixos_hosts contract rendering
    ├── terraform.tfvars            # Real values (local, gitignored-ish)
    ├── terraform.tfvars.example    # Template
    ├── terraform.tfstate{,.backup} # Local state (no remote backend yet)
    ├── contracts/                  # JSON Schema (versioned handoff contract)
    │   └── nixos-hosts.schema.json # schema_version 1.0.0, locked
    ├── examples/                   # Example payloads matching the schema
    │   └── nixos-hosts.example.json
    ├── modules/
    │   └── lxc-container/          # One Proxmox container resource (SAFE-01 hardcoded)
    │       ├── main.tf
    │       ├── variables.tf
    │       ├── outputs.tf
    │       └── README.md
    └── docs/                       # (empty — placeholder)
```

## Directory Purposes

**`docs/`:**
- Purpose: Cross-cutting contract and architecture docs shared by both trees.
- Contains: The ownership boundary, template workflow, NixOS handoff contract, and end-state runtime data-flow diagram.
- Key files: `docs/ownership-boundary.md` (Terraform vs NixOS responsibilities), `docs/nixos-handoff.md` (schema versioning rules), `docs/template-workflow.md` (only supported template path: `nixos-rebuild build-image --image-variant proxmox-lxc`), `docs/end-state-data-flow.md` (Mermaid diagram of hermes + audit-plane runtime), `docs/README.md` (docs index + suggested operator flow).

**`nixos/`:**
- Purpose: NixOS flake tree. Owns everything inside the guest: users, packages, services, secrets, firewall, filesystem policy.
- Contains: Flake entrypoint, per-host compositions, reusable modules, project-local packages, deployment profiles, sops-encrypted secrets, per-host nftables assertion scripts.
- Key files: `nixos/flake.nix` (the authoritative definition of every `nixosConfiguration` + `checks.*` invariants), `nixos/README.md` (bringing up the hermes LXC end-to-end), `nixos/justfile` (day-to-day recipes).

**`nixos/hosts/`:**
- Purpose: One subdirectory per host — thin composition layer that wires `modules/*.nix` together, binds sops secrets, and owns host-identity constants.
- Contains: `<host>/default.nix` per host. `mcp-audit/` also holds `clickhouse-schema.sql` (TTL DDL applied by a boot-oneshot in `modules/mcp-audit.nix`) and `disk-check.sh` (D-10 timer script).
- Key files: `nixos/hosts/hermes/default.nix` is the largest (562 lines — includes `hermes-agent-container-extras` bootstrap that apt/npm/pip-installs Node 22, libopus0, `@openai/codex`, `agent-browser`, `supermemory` into the ubuntu:24.04 container's writable layer).
- Convention: The three `mcp-nats0{1,2,3}/default.nix` are **deliberately near-identical** (copy+rename, don't over-DRY). They differ only in `serverName`, `lxcIp`, and `sops.defaultSopsFile`.

**`nixos/modules/`:**
- Purpose: Reusable role modules. Each declares `options.services.mcp<Role>` and implements it.
- Contains:
  - `common.nix` (189 lines) — baseline every host inherits via `mkHost` (sshd with ed25519-only + restricted ciphers/kex/macs, fail2ban, nftables, auto-upgrade from `github:escidmore/hermes-deploy?dir=nixos` at 04:00, Nix GC 14d, sops defaults, base package set).
  - `nats-cluster.nix` (288 lines) — `services.mcpNatsCluster`: JetStream R3 + mTLS + JWT full resolver + cluster routes + cert-bootstrap oneshot with 12h renewal timer against step-ca.
  - `nats-accounts.nix` (191 lines) — operator JWT + creds materialization.
  - `mcp-audit.nix` (459 lines) — full Langfuse v3 stack (native Postgres 17 / ClickHouse 25.10 / Redis 8 + digest-pinned oci-containers langfuse-web/worker), langfuse-nats-ingest bridge, ClickHouse TTL boot-oneshot + weekly timer, disk-check timer, Vector journal consumer.
  - `step-ca.nix` (76 lines) — 24h-cert issuer, enforced by `flake.nix` `checks.step-ca-cert-duration-24h`.
  - `otlp-nats-publisher.nix` (87 lines) — local `127.0.0.1:4318` OTLP HTTP receiver → `audit.otlp.traces.<host>` NATS publisher.
  - `vector-audit-client.nix` (272 lines) — journald → `audit.journal.<host>`.
  - `mcp-otel.nix` (21 lines) — shared OTEL env vars, consistency enforced by `otel-module-consistent` flake check.
  - `mcp-prom-exporters.nix` (113 lines) — narrow Prom carve-out (no wildcard saddr, concrete IP required at eval time).
  - `pbs-excludes.nix` (64 lines) — PBS backup exclude baseline (8 required paths, subset-enforced by `mcp-audit-pbs-excludes` check).

**`nixos/pkgs/`:**
- Purpose: Project-local packages built by the flake's `packages.x86_64-linux`.
- Contains: `langfuse-nats-ingest/` (NATS → Langfuse OTLP bridge, consumed by `modules/mcp-audit.nix`) and `otlp-nats-publisher/` (OTLP HTTP → NATS publisher, consumed by `modules/otlp-nats-publisher.nix`). Each has `default.nix`, `pyproject.toml`, `src/`.
- Generated: No. Committed: Yes.

**`nixos/profiles/`:**
- Purpose: Deployment-target shape. Imported by exactly one host via `mkHost`'s `modules` list.
- Contains: `lxc.nix` (Proxmox LXC — imports `<nixpkgs>/modules/virtualisation/proxmox-lxc.nix`, disables `systemd-networkd-wait-online`, turns off `nix.settings.sandbox`, enables rootful Podman with `dockerCompat`), `cloud-vm.nix` (disko + qemu-guest for future cloud VMs).

**`nixos/secrets/`:**
- Purpose: sops-encrypted YAML per host + plaintext `.example` templates.
- Contains: `hermes.yaml[.example]`, `mcp-audit.yaml[.example]`, `mcp-nats01/02/03.yaml[.example]`, `nats-operator.yaml[.example]`, `host-sops-keys.yaml[.example]` (per-host age private keys, decryptable only by the workstation recipient).
- Key convention: `.sops.yaml` (not visible in `ls` — hidden) holds age recipient anchors per host and `creation_rules` path_regex per file.

**`nixos/tests/`:**
- Purpose: Post-deploy verification scripts + one flake-check helper.
- Contains: `audit0{1,2,3,4,5}-*.sh` per-phase verification scripts (datastores up, disk alerts, hermes probe, NATS anon check, OTLP end-to-end), `nats-node-loss.sh`, `nats-restart-zero-drop.sh`, `restore-check.sh`, `nft-no-hermes.nix` (imported per-host by `flake.nix` `checks.assert-no-hermes-reach`), and a `fixtures/` directory.

**`nixos/users/`:**
- Purpose: User definitions. Currently just one.
- Contains: `eve.nix` (login user, SSH key, fish shell, wheel group).

**`nixos/docs/ops/`:**
- Purpose: NixOS operator runbooks (guest-side only). Cross-tree docs live in `../../../docs/`.
- Contains: `README.md` (index + suggested order), `deploy-pipeline.md` (end-to-end `terraform apply` flow), `new-lxc-checklist.md` (add another host), `nats-bring-up.md` (one-time NATS cluster bootstrap), `langfuse-minio-bucket.md` (MinIO bucket + IAM setup for Langfuse object storage), `phase-01-verification.md` (audit-plane verification manual), `phase-close-diffs/` (closing-diff artefacts).

**`terraform/`:**
- Purpose: Proxmox-side container envelope. Owns placement/identity, resource sizing, networking envelope, metadata, template selection — and a single `null_resource.nixos_deploy` hop into NixOS.
- Contains: Root Terraform config, one submodule (`modules/lxc-container/`), the handoff contract (`contracts/`), examples, versioned provider pins.
- Key files: `terraform/main.tf` (root composition + `null_resource.nixos_deploy` that shells out to `../scripts/bootstrap-host.sh`), `terraform/locals.tf` (container inventory — currently `mcp-audit` + `mcp-nats01/02/03`, each with node/vmid/ipv4/mac/vlan/bridge/nixos_role/rootfs_datastore/cpu/memory/tags), `terraform/contracts/nixos-hosts.schema.json` (the locked `schema_version = 1.0.0` downstream contract).

**`terraform/modules/lxc-container/`:**
- Purpose: Single source of truth for one unprivileged NixOS LXC container.
- Contains: `main.tf` (hardcodes `unprivileged = true`, `features { nesting = true }`, `operating_system.type = "nixos"`; lifecycle precondition on SSH keys), `variables.tf`, `outputs.tf` (`host` object matching the schema), `README.md`.
- Key posture: No guest bootstrap inputs (`remote-exec`, `file`) — that's `nixos/`'s job. DHCP unsupported — static IPv4 only.

**`scripts/`:**
- Purpose: Operator workflows that span both trees. Always invoked from repo root as `./scripts/<name>.sh`.
- Contains: `add-host.sh` (one-shot per-host setup: age keypair in tmpfs, `.sops.yaml` anchor insert, `secrets/host-sops-keys.yaml` stash, re-key host secrets), `bootstrap-host.sh` (SSH wait + age-key push + `nixos-rebuild switch --target-host`; called by `terraform/main.tf` `null_resource.nixos_deploy`), `init-secrets.sh` (NSC operator/account/user creation for `mcp-audit-cluster` + `AUDIT` account + per-host `vector-mcp-nats*` users + sops-encrypted generation of `nats-operator.yaml`, `mcp-audit.yaml`, `mcp-nats01/02/03.yaml`).

## Key File Locations

**Entry Points:**
- `terraform/main.tf`: Root Terraform composition.
- `nixos/flake.nix`: Every `nixosConfiguration` and `checks.*` invariant.
- `scripts/add-host.sh`, `scripts/bootstrap-host.sh`, `scripts/init-secrets.sh`: Operator scripts.
- `nixos/justfile`: Day-to-day recipes (fish shell required).

**Configuration:**
- `terraform/locals.tf`: Container inventory (one `locals.containers.<name> = { node, vmid, ipv4, gateway, mac_address, vlan_id, bridge, nixos_role, rootfs_datastore, rootfs_size_gib, cpu_cores, memory_mib, tags, ssh_authorized_key_files }` entry per host).
- `terraform/versions.tf`: `terraform ~> 1.14.0`, `bpg/proxmox ~> 0.102.0`, `hashicorp/null ~> 3.2.4`.
- `terraform/providers.tf`: `proxmox` provider block (API token + SSH agent).
- `terraform/terraform.tfvars{,.example}`: Secret-bearing values (endpoint, API token, SSH username, template file ID, repo path).
- `nixos/flake.lock`: Pinned flake inputs.
- `nixos/.sops.yaml` (hidden): Age recipient anchors + creation_rules per path.

**Core Logic:**
- `terraform/modules/lxc-container/main.tf`: The one Proxmox container resource.
- `terraform/contracts/nixos-hosts.schema.json`: The locked Terraform→NixOS contract.
- `terraform/outputs.tf`: Renders `nixos_hosts` payload per schema.
- `nixos/modules/common.nix`: Baseline inherited by every host.
- `nixos/modules/nats-cluster.nix`, `nixos/modules/mcp-audit.nix`, `nixos/modules/step-ca.nix`: Core audit-plane role modules.
- `nixos/hosts/hermes/default.nix`: Hermes agent LXC + supermemory plugin plumbing.

**Secrets (encrypted at rest):**
- `nixos/secrets/hermes.yaml`: hermes-agent env + auth JSON.
- `nixos/secrets/nats-operator.yaml`: operator JWT + admin creds + AUDIT account JWT.
- `nixos/secrets/mcp-audit.yaml`: Langfuse web/worker/ingest env, Postgres/ClickHouse/Redis passwords, step-ca intermediate password, step-ca root PEM, NATS ingest creds.
- `nixos/secrets/mcp-nats0{1,2,3}.yaml`: step-ca root, NATS server cert/key, Vector client cert/key, NATS client creds.
- `nixos/secrets/host-sops-keys.yaml`: per-host age private keys (workstation-decryptable only).

**Testing / Verification:**
- `nixos/flake.nix` `checks.x86_64-linux`: eval-time invariants (run via `just check` / `nix flake check`).
- `nixos/tests/audit0*-*.sh`: post-deploy verification scripts.
- `nixos/tests/nft-no-hermes.nix`: per-host nftables ruleset greps consumed by `assert-no-hermes-reach`.

## Naming Conventions

**Files:**
- NixOS modules: `nixos/modules/<role>.nix` — kebab-case. Module declares `options.services.mcp<RoleCamel>`.
- NixOS hosts: `nixos/hosts/<hostname>/default.nix` — hostname matches `nixosConfigurations.<name>` and the Terraform `local.containers` key.
- Terraform modules: one subdirectory under `terraform/modules/` per module, with `main.tf`/`variables.tf`/`outputs.tf`/`README.md`.
- Scripts: lowercase hyphenated `.sh` in `scripts/` (repo root) or `nixos/tests/` (per-test).

**Directories:**
- Host dirs under `nixos/hosts/` use the exact hostname (no prefix/suffix). `mcp-*` prefix denotes audit-plane hosts and is what the flake checks filter on.

**Secrets YAML:**
- `<host>.yaml` = encrypted. `<host>.yaml.example` = plaintext template, committed alongside.

## Where to Add New Code

**New NixOS host:**
- Create `nixos/hosts/<name>/default.nix` (copy `nixos/hosts/mcp-nats01/default.nix` as the audit-plane template, or `nixos/hosts/hermes/default.nix` for privileged workload).
- Add a `nixosConfigurations.<name>` entry in `nixos/flake.nix` that imports the right profile (`./profiles/lxc.nix` or `./profiles/cloud-vm.nix`) and the host module.
- Add a `locals.containers.<name> = { ... }` entry in `terraform/locals.tf` (node, vmid, ipv4, gateway, mac_address, vlan_id, bridge, nixos_role, rootfs_datastore, rootfs_size_gib, cpu_cores, memory_mib, tags).
- Run `./scripts/add-host.sh <name>` from the repo root to generate the age identity.
- Copy `nixos/secrets/<name>.yaml.example` → `.yaml`, populate, `sops -e -i`.
- See `nixos/docs/ops/new-lxc-checklist.md`.

**New reusable NixOS role module:**
- Create `nixos/modules/<role>.nix` with `options.services.mcp<RoleCamel>` + conditional `config`.
- Import it from each host that wants the role in `nixos/hosts/<host>/default.nix`.
- If the module must hold a cross-host security invariant, add a `checks.<name>` derivation in `nixos/flake.nix` that filters hosts by prefix or option and validates the rendered config.

**New project-local package:**
- Create `nixos/pkgs/<pkgname>/` with `default.nix` + `pyproject.toml` + `src/`.
- Add `packages.${system}.<pkgname> = pkgs.callPackage ./pkgs/<pkgname> { };` to `nixos/flake.nix`.
- Reference from the consuming module via `self.packages.${system}.<pkgname>` or a `pkgs.callPackage` in the module.

**New cross-tree operator script:**
- Add `scripts/<name>.sh` (bash, `set -euo pipefail`), invoked from repo root.
- If Terraform needs to call it, add a `null_resource` in `terraform/main.tf` with `local-exec` + `working_dir = var.hermes_repo_path`.

**New Terraform resource shape:**
- Extend `terraform/modules/lxc-container/` **only** for Proxmox-envelope concerns. Guest concerns stay in `nixos/`.
- For a new shape entirely, add `terraform/modules/<name>/` with its own `main.tf`/`variables.tf`/`outputs.tf`/`README.md`.
- If it produces facts consumed by NixOS, update `terraform/contracts/nixos-hosts.schema.json` (bump `schema_version`: minor for new field, major for rename/remove).

**New cross-tree doc:**
- Contract docs → `docs/`.
- NixOS guest-side runbooks → `nixos/docs/ops/`.
- Terraform module docs → colocated `README.md` in `terraform/modules/<name>/`.

## Special Directories

**`nixos/result/` (if present):**
- Purpose: `nix build` output symlink.
- Generated: Yes. Committed: No (gitignored).

**`nixos/.serena/`, `.git-backups/`:**
- Purpose: Serena MCP / git backup metadata.
- Generated: Yes. Committed: No.

**`.planning/`:**
- Purpose: GSD planning artefacts (phases, codebase maps, todos).
- Generated: Yes (by GSD workflow). Committed: No (globally gitignored per project convention in `terraform/AGENTS.md`).

**`terraform/terraform.tfstate{,.backup}`:**
- Purpose: Local Terraform state. No remote backend configured yet.
- Generated: Yes. Committed: Yes in this repo (local single-operator setup).

---

*Structure analysis: 2026-04-22*
