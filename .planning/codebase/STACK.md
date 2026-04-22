# Technology Stack

**Analysis Date:** 2026-04-22

Hermes-deploy is a two-tree monorepo: `terraform/` provisions Proxmox LXC
containers and `nixos/` configures the NixOS guests that run inside them.
Shared operator scripts in `scripts/` glue the two together. The stack is
pinned-version-first — every major tool has an explicit version floor in code.

## Languages

**Primary:**
- Nix (flakes, NixOS modules) — system configuration across `nixos/flake.nix`,
  `nixos/modules/*.nix`, `nixos/hosts/*/default.nix`, `nixos/profiles/*.nix`
- HCL (Terraform) — infrastructure-as-code across `terraform/*.tf` and
  `terraform/modules/lxc-container/*.tf`
- Bash — operator workflows in `scripts/*.sh` and `nixos/tests/*.sh`; all
  scripts use `set -euo pipefail`
- Python 3.11+ — two small services in `nixos/pkgs/langfuse-nats-ingest/`
  and `nixos/pkgs/otlp-nats-publisher/`, both packaged via
  `buildPythonApplication`

**Secondary:**
- SQL — `nixos/hosts/mcp-audit/clickhouse-schema.sql` (Langfuse ClickHouse
  TTL DDL)
- YAML — sops-encrypted secrets (`nixos/secrets/*.yaml`) and unencrypted
  `*.yaml.example` templates
- JSON Schema — `terraform/contracts/nixos-hosts.schema.json`
- Fish shell — used as the default login shell; also the shell used by
  `nixos/justfile` (`set shell := ["fish", "-c"]`)

## Runtime

**Nix / NixOS:**
- Nixpkgs channel: `github:NixOS/nixpkgs/nixos-25.11` (`nixos/flake.nix:5`)
- NixOS `system.stateVersion = "25.11"` on every host
  (`nixos/hosts/*/default.nix`)
- Experimental features enabled in `nixos/modules/common.nix:13-17`:
  `nix-command`, `flakes`
- Automatic garbage collection: weekly, `--delete-older-than 14d`
  (`common.nix:25-29`)
- `auto-optimise-store = true`; `nix.settings.sandbox = false` in the LXC
  profile (`profiles/lxc.nix:21`) because Proxmox LXC does not expose the
  mount namespaces Nix's sandbox needs

**Terraform:**
- `required_version = "~> 1.14.0"` (`terraform/versions.tf:2` and
  `terraform/modules/lxc-container/main.tf:7`)

**Python:**
- `requires-python = ">=3.11"` in both
  `nixos/pkgs/langfuse-nats-ingest/pyproject.toml` and
  `nixos/pkgs/otlp-nats-publisher/pyproject.toml`
- Built through `nixpkgs` `python3Packages.buildPythonApplication`; no
  in-repo Python interpreter pin beyond that

## Frameworks

**NixOS modules (flake inputs, `nixos/flake.nix:4-18`):**
- `nixpkgs` — `github:NixOS/nixpkgs/nixos-25.11`
- `sops-nix` — `github:Mic92/sops-nix`; primary secrets-management framework,
  imported as `sops-nix.nixosModules.sops` in `nixos/flake.nix:52`
- `disko` — `github:nix-community/disko`; declarative disk/partition
  configuration (input declared; not yet consumed by any host file in the
  current tree)
- `hermes-agent` — `github:NousResearch/hermes-agent`; third-party NixOS
  module consumed by the `hermes` host via
  `hermes-agent.nixosModules.default`
- `rust-overlay` — `github:oxalica/rust-overlay`; applied as a nixpkgs
  overlay at the flake level

**Terraform providers (`terraform/versions.tf:4-14`):**
- `bpg/proxmox` `~> 0.102.0` — primary Proxmox VE provider (LXC
  containers, network interfaces, disk, initialization)
- `hashicorp/null` `~> 3.2.4` — used for `null_resource.nixos_deploy` in
  `terraform/main.tf:55-77` which shells out to
  `scripts/bootstrap-host.sh`

**Guest OS runtime frameworks:**
- `services.openssh` — hardened defaults in `nixos/modules/common.nix:58-90`
  (no password auth, ed25519 host key only, chacha20/aes-gcm ciphers,
  curve25519 KEX)
- `services.fail2ban` — exponential-backoff bantime on top of sshd
  (`common.nix:92-101`)
- `networking.nftables` — exclusive firewall backend; the legacy
  `networking.firewall` compat layer is explicitly avoided (see
  `nixos/modules/mcp-prom-exporters.nix:20-24`)
- `systemd` — heavy use of oneshots, timers, and hardening directives
  (`NoNewPrivileges`, `ProtectSystem=strict`, `MemoryDenyWriteExecute`,
  `SystemCallFilter = [ "@system-service" "~@privileged" ]`) on every
  custom service — see `nixos/modules/mcp-audit.nix:303-338`,
  `nixos/modules/otlp-nats-publisher.nix:54-84`,
  `nixos/modules/vector-audit-client.nix:248-270`
- `virtualisation.oci-containers` + Podman — Langfuse web/worker digest-
  pinned by `@sha256:` (`nixos/modules/mcp-audit.nix:223-261`); host-level
  Podman enabled in `nixos/profiles/lxc.nix:36-42` with
  `dockerCompat = true`, `autoPrune.enable = true`

**Python service dependencies:**
- `nixos/pkgs/langfuse-nats-ingest/pyproject.toml:11-13` — `nats-py>=2.7`,
  `httpx>=0.27`
- `nixos/pkgs/otlp-nats-publisher/pyproject.toml:11-13` — `aiohttp>=3.10`,
  `nats-py>=2.7`
- Build backend: `setuptools>=68`

## Build & Developer Tooling

**Build commands:**
- Terraform: run from `terraform/`; `terraform apply` performs end-to-end
  bring-up (including calling `scripts/bootstrap-host.sh`, see
  `terraform/main.tf:55-77`)
- NixOS per-host build: `nix build
  .#nixosConfigurations.<host>.config.system.build.toplevel`
  (`nixos/justfile:14-15`)
- NixOS flake evaluation / checks: `nix flake check --no-build`
  (`nixos/justfile:10-11`); six custom `checks.${system}` derivations in
  `nixos/flake.nix:116-384` assert invariants at eval time
  (`assert-no-hermes-reach`, `assert-prom-carveout-narrow`,
  `nats-no-anonymous`, `mcp-audit-pbs-excludes`,
  `step-ca-cert-duration-24h`, `langfuse-image-pinned-by-digest`,
  `otel-module-consistent`)

**`nixos/devShells.${system}.default` (`nixos/flake.nix:102-112`) ships:**
- `age` — symmetric age-format key handling
- `nil` — Nix language server
- `nixos-rebuild` — system activation CLI
- `nixfmt-rfc-style` — canonical Nix formatter (also set as
  `formatter.${system}` in `nixos/flake.nix:114`)
- `sops` — secrets en/decryption CLI
- `ssh-to-age` — converts ed25519 host keys to age recipients
- `just` — command runner (driver for `nixos/justfile`)

**Justfile targets (`nixos/justfile`):**
- `check` — `nix flake check --no-build`
- `build HOST` — build toplevel without activating
- `switch HOST` — `nixos-rebuild switch` locally
- `dry-run HOST` — `nixos-rebuild dry-activate`
- `deploy HOST TARGET` — wraps `scripts/bootstrap-host.sh` or runs
  `nixos-rebuild switch --target-host` directly
- `fmt` — `nix fmt`
- `update` — `nix flake update`
- `edit-secrets` — `sops secrets/hermes.yaml`
- `show-recipient` — derives age recipient via `age-keygen -y`

**Operator-system-package baseline (`nixos/modules/common.nix:105-154`):**
- Shell/editor: `vim`, `helix`, `neovim` (set as `defaultEditor`)
- Search/navigation: `ripgrep`, `fd`, `fzf`, `eza`, `zoxide`
- File processing: `bat`, `jq`, `yq`
- Monitoring: `htop`, `btop`, `ncdu`, `duf`
- Git stack: `git`, `git-lfs`, `gh`, `delta`
- Network: `curl`, `wget`, `httpie`, `dnsutils`
- Ops/secrets: `age`, `sops`, `ssh-to-age`
- Archive: `unzip`, `p7zip`
- Misc: `tree`, `tldr`, `watchexec`, `tmux`, `git.config.init.defaultBranch = "main"`,
  `programs.fish.enable = true`

## Configuration

**Terraform variables:**
- `terraform/provider-variables.tf:1-21` — `virtual_environment_endpoint`,
  `virtual_environment_api_token` (sensitive), `virtual_environment_ssh_username`,
  `virtual_environment_insecure`
- `terraform/template-variables.tf` — template image identifier for the LXC
  module (consumed as `var.template_file_id` in `terraform/main.tf:17`)
- `terraform/terraform.tfvars` (gitignored) / `terraform/terraform.tfvars.example`
  (committed) carry concrete values
- Host inventory in `terraform/locals.tf:5-70` — per-container map keyed by
  hostname with `node`, `vmid`, `ipv4`, `gateway`, `mac_address`, `vlan_id`,
  `bridge`, `rootfs_datastore`, `cpu_cores`, `memory_mib`, `tags`

**NixOS configuration shape:**
- Flake outputs: `nixosConfigurations.{hermes, mcp-nats01..03, mcp-audit}`
  (`nixos/flake.nix:58-95`)
- Shared system layer: `nixos/modules/common.nix` (imported by every host
  via `mkHost` in `nixos/flake.nix:50`)
- Per-class profile: `nixos/profiles/lxc.nix` (imports
  `<nixpkgs/nixos/modules/virtualisation/proxmox-lxc.nix>`, enables Podman,
  disables `networkd-wait-online` and TTY getty units for LXC)
- `system.autoUpgrade` — enabled in `common.nix:32-43` pointing at
  `github:escidmore/hermes-deploy?dir=nixos`; explicitly disabled with
  `lib.mkForce false` on `mcp-audit` to prevent unattended bumps of the
  Langfuse stack (`hosts/mcp-audit/default.nix:63-65`)

**Time / locale:**
- `time.timeZone = "America/Los_Angeles"` (`common.nix:45`)
- `i18n.defaultLocale = "en_US.UTF-8"` (`common.nix:46`)

**Gitignore (`.gitignore`):**
- `.planning/`, `.git-backups/`, editor state
  (`**/.claude/`, `**/.serena/`, `**/.vscode/`, `**/.direnv/`)
- Terraform local artifacts: `.terraform/`, state files, `*.tfvars`
  (except `*.tfvars.example`), `*.tfplan`, crash logs, local `.terraformrc`
- NixOS local artifacts: `nixos/result`, `nixos/result-*`,
  `nixos/*.qcow2`, `nixos/*.raw`, `nixos/keys.txt`, `nixos/*.age`

## Platform Requirements

**Provisioning host (runs `terraform apply`, `scripts/bootstrap-host.sh`):**
- Tools on PATH: `sops`, `python3`, `ssh`, `nix` (hard-checked in
  `scripts/bootstrap-host.sh:35-40`)
- `nixos-rebuild` on PATH preferred; otherwise the script falls back to
  `nix run nixpkgs#nixos-rebuild --` (`bootstrap-host.sh:42-47`)
- Env var: `SOPS_AGE_KEY_FILE` (defaults to `~/.config/sops/age/keys.txt`,
  `bootstrap-host.sh:49-50`)
- SSH agent configured — the Proxmox provider uses `ssh.agent = true`
  (`terraform/providers.tf:7`)

**Infrastructure target:**
- Proxmox VE cluster with at least three nodes: `pm01`, `pm02`, `pm03`
  (`terraform/locals.tf:7,23,39,55`)
- `ceph-rbd` datastore available on every node (`terraform/locals.tf:15,31,47,63`)
- `vmbr1` bridge + VLAN 1200 (`terraform/locals.tf:12-13`)
- Proxmox API endpoint reachable with a token; PAM SSH user for the
  provider's file-upload path

**Guest target (inside each LXC):**
- NixOS 25.11 LXC image (template file id supplied via
  `var.template_file_id`); unprivileged; `features.nesting = true` only
  (`terraform/modules/lxc-container/main.tf:26-44`)
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

---

*Stack analysis: 2026-04-22*
