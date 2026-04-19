<!-- GSD:project-start source:PROJECT.md -->
## Project

**Terraform Proxmox NixOS LXC Lab**

This project uses Terraform and the Proxmox provider to provision the LXC containers that will run
NixOS systems. It is the infrastructure subtree inside the hermes-deploy monorepo and stands up the
Proxmox-side container resources consumed by the sibling `nixos/` tree.

**Core Value:** Provision repeatable Proxmox LXC infrastructure that gives the `nixos/` tree stable, predictable
container targets to configure.

### Constraints

- **Platform**: Proxmox LXC containers — the infrastructure target is specifically Proxmox LXCs.
- **Repo Boundary**: Separate `terraform/` and `nixos/` subtrees — this directory stays focused on
  provisioning, not OS configuration.
- **Git Tracking**: `.planning/` remains untracked — the user already ignores planning docs via a
  global gitignore.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Core Technologies
| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Proxmox VE | 9.1 | Hypervisor and LXC platform | Use current Proxmox for greenfield. The bpg provider explicitly targets Proxmox VE 9.x first; 8.x is only secondary support. That matters because this repo exists to manage Proxmox resources, so provider/host alignment is more important than squeezing life out of an older cluster. | HIGH |
| Terraform CLI | 1.14.8 | IaC engine and plan/apply workflow | If you want “Terraform-based” in the literal sense, pin current Terraform and keep the workflow boring. 1.14.x is current stable in HashiCorp docs, and the Proxmox provider supports Terraform 1.5+. | HIGH |
| `bpg/proxmox` provider | 0.102.0 | Proxmox API provider for LXC, storage, networking, and files | This is the standard modern choice now. It is actively released, documents Proxmox 9.x compatibility, supports Terraform/OpenTofu, and has first-class LXC resources. For a new repo, there is no good reason to start on the older Telmate provider. | HIGH |
| NixOS | 25.11 | Guest OS running inside the LXCs | Use current stable NixOS for the guest systems so the sibling `nixos/` tree can target a stable channel instead of chasing old module behavior. | HIGH |
| Nix | 2.34.5 | Build toolchain for generating NixOS artifacts | Current Nix matters because image-building is now upstream NixOS functionality; you do not need legacy image tooling anymore. | HIGH |
### Supporting Libraries / Built-ins
| Library / Feature | Version | Purpose | When to Use | Confidence |
|-------------------|---------|---------|-------------|------------|
| `nixos-rebuild build-image` + `proxmox-lxc` image module | NixOS 25.11 built-in | Build a native NixOS LXC template for Proxmox | Use this for every NixOS LXC base image. It replaces the old `nixos-generators` path and matches the current upstream NixOS image workflow. | HIGH |
| Terraform `s3` backend with `use_lockfile = true` | Built into Terraform 1.14.x | Remote state and state locking | Use once this repo is used from CI or more than one machine. It is the standard remote-state baseline; DynamoDB locking is now deprecated in the official docs. | HIGH |
| Proxmox API token auth + PAM SSH user/`ssh-agent` | Provider-supported | API auth plus file/snippet/template upload path | Use API tokens for Terraform auth, but keep a PAM-backed SSH user available because some provider operations still require SSH/SFTP-style access. | HIGH |
| TFLint | 0.61.0 | Terraform linting | Use from day one. It catches provider/schema mistakes before apply, which is especially valuable against fast-moving provider releases. | HIGH |
| Terraform Language Server (`terraform-ls`) | 0.38.6 | Editor completions, validation, and schema awareness | Use in the editor for better HCL authoring; worth standardizing even in a solo repo. | HIGH |
| Terragrunt | 1.0.1 | Optional wrapper for multi-stack orchestration | Do **not** start with this. Add it only if the repo later grows into many environments/nodes/modules and plain Terraform stops being manageable. | MEDIUM |
### Development Tools
| Tool | Version | Purpose | Notes |
|------|---------|---------|-------|
| `terraform fmt` / `terraform validate` | 1.14.8 | Formatting and static validation | Mandatory baseline checks before every plan/apply. |
| TFLint | 0.61.0 | HCL/provider linting | Add the Terraform ruleset and run it in CI. |
| `terraform-ls` | 0.38.6 | IDE support | Keep dev experience aligned with current Terraform syntax/schema. |
## Installation
# Core CLI
# Terraform 1.14.8: https://developer.hashicorp.com/terraform/install
# Linting / editor support
# TFLint 0.61.0: https://github.com/terraform-linters/tflint/releases/tag/v0.61.0
# terraform-ls 0.38.6: https://github.com/hashicorp/terraform-ls/releases/tag/v0.38.6
# Nix / NixOS image tooling
# Nix 2.34.5 and NixOS 25.11: https://nixos.org/download/
# Build the NixOS LXC template artifact
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Terraform 1.14.8 | OpenTofu 1.11.0 | Use OpenTofu only if you want the same HCL workflow but prefer an MPL-licensed fork. The bpg provider supports both. |
| `bpg/proxmox` 0.102.0 | `Telmate/proxmox` v3.0.2-rc07 | Only use Telmate if you are inheriting an existing Telmate codebase and migration cost is higher than the benefits of switching. Do not choose it for greenfield. |
| Plain Terraform modules | Terragrunt 1.0.1 | Use Terragrunt later if this repo expands into many repeated stacks/environments and backend/provider DRY pressure becomes real. |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `Telmate/terraform-provider-proxmox` for a new repo | Its latest release is still an RC, and its own README lists LXC crash/failed-task limitations. That is the wrong place to start for a clean greenfield stack. | `bpg/proxmox` 0.102.0 |
| `nix-community/nixos-generators` as the primary image path | The repository is archived and explicitly says most functionality was upstreamed into nixpkgs starting with NixOS 25.05. | `nixos-rebuild build-image --image-variant proxmox-lxc` |
| Proxmox VE 8.x for greenfield | The provider explicitly says 9.x is the compatibility target and 8.x is not where testing priority goes. Starting old just buys you version friction. | Proxmox VE 9.1 |
| OCI-image-based Proxmox containers for NixOS hosts | Proxmox 9.1’s OCI support is still technology preview and is aimed at OCI/application-container workflows. This project needs durable NixOS system containers. | Native NixOS `proxmox-lxc` image/module |
| Privileged LXCs by default | Proxmox documents unprivileged containers as the safer default; privileged containers should be restricted to trusted edge cases. | Unprivileged LXCs |
| Hardcoded credentials in backend/provider config | Terraform docs warn that backend-config secrets can leak into `.terraform` and plan files. | Environment variables / external secret store injection |
## Stack Patterns by Variant
- Start with plain Terraform modules and the `bpg/proxmox` provider.
- Keep state remote if possible, but do not add Terragrunt yet.
- Build NixOS LXC templates from the NixOS repo and feed the artifact into Proxmox.
- Move to an S3-compatible remote backend with `use_lockfile = true`.
- Standardize TFLint and `terraform validate` in CI.
- Consider Terragrunt only after module/environment sprawl is obvious.
## Version Compatibility
| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| Proxmox VE 9.1 | `bpg/proxmox` 0.102.0 | Provider README says 9.x is the primary compatibility target. |
| Terraform 1.14.8 | `bpg/proxmox` 0.102.0 | Provider requires Terraform 1.5+; 1.14.8 is current stable. |
| OpenTofu 1.11.0 | `bpg/proxmox` 0.102.0 | Supported if you later choose the OpenTofu fork. |
| NixOS 25.11 | Nix 2.34.5 | Current stable pairing from nixos.org download/manual docs. |
| NixOS 25.11 image tooling | `proxmox-lxc` image variant | Current upstream path for building Proxmox LXC images. |
## Recommendation Summary
## Sources
- https://developer.hashicorp.com/terraform/install — verified current Terraform release (1.14.8) and install guidance
- https://developer.hashicorp.com/terraform/language/backend/s3 — verified `s3` backend, `use_lockfile`, and DynamoDB locking deprecation
- https://github.com/bpg/terraform-provider-proxmox/blob/main/README.md — verified provider requirements, Proxmox 9.x compatibility, SSH/API token behavior, and known issues
- https://github.com/bpg/terraform-provider-proxmox/releases/tag/v0.102.0 — verified current provider version
- https://pve.proxmox.com/wiki/Roadmap — verified current Proxmox VE stable line includes 9.1
- https://pve.proxmox.com/wiki/Linux_Container — verified LXC defaults, unprivileged-container recommendation, and current container behavior
- https://nixos.org/download/ — verified current Nix (2.34.5) and NixOS (25.11) versions
- https://nixos.org/manual/nixos/stable/#sec-image-nixos-rebuild-build-image — verified upstream `nixos-rebuild build-image` workflow and `proxmox-lxc.nix` module availability
- https://github.com/nix-community/nixos-generators — verified archive/deprecation status and upstreaming note
- https://github.com/Telmate/terraform-provider-proxmox — verified latest release remains `v3.0.2-rc07` and README-known limitations
- https://github.com/terraform-linters/tflint/releases/tag/v0.61.0 — verified current TFLint version
- https://github.com/hashicorp/terraform-ls/releases/tag/v0.38.6 — verified current terraform-ls version
- https://github.com/gruntwork-io/terragrunt/releases/tag/v1.0.1 — verified current Terragrunt version
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.OpenCode/skills/`, `.agents/skills/`, `.cursor/skills/`, or `.github/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using edit, write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-OpenCode-profile` -- do not edit manually.
<!-- GSD:profile-end -->
