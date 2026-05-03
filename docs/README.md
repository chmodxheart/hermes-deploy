# Docs

Shared documents for the `homelab` monorepo live here.

Use this directory for cross-cutting contracts between homelab platform areas.
Subtree-specific runbooks live under `../nixos/docs/ops/`.

## Core Docs

- `ownership-boundary.md`: whole-homelab ownership matrix, hard guardrails, and the Terraform/NixOS crossover limit.
- `home-manager.md`: referenced Home Manager source, wrapper commands, machine onboarding, and SOPS/age boundary.
- `kubernetes-talos.md`: referenced clustertool source, safe wrapper commands, Flux/Talos ownership, and Kubernetes SOPS boundary.
- `service-inventory.md`: whole-homelab service catalog, inventory source-of-truth, and migration triage evidence.
- `migration-pattern.md`: Kubernetes-to-LXC migration rubric/template and
  implementation-ready `uptime-kuma` plan; clustertool/Flux still owns durable
  Kubernetes cleanup.
- `template-workflow.md`: the supported way to build and register the NixOS Proxmox LXC template.
- `nixos-handoff.md`: the stable contract exported by Terraform and consumed by the NixOS side.
- `end-state-data-flow.md`: planned runtime architecture and data-flow diagram for Hermes + audit-plane hosts.

## Whole-Homelab Platform Map

| Platform area | Current active source | Planned direction | Start here |
| --- | --- | --- | --- |
| Proxmox envelopes | `../terraform/` | Stays Terraform-owned. | `../terraform/README.md` |
| NixOS guest state | `../nixos/` | Stays NixOS-owned. | `../nixos/README.md` |
| Home Manager | `~/repo/home-manager` | Referenced from homelab through scripts/home-manager.sh and docs/home-manager.md. | `home-manager.md` |
| Kubernetes/Talos | `../external/clustertool` | Referenced from homelab through docs/kubernetes-talos.md, scripts/kubernetes-talos.sh, inventory/services.json, and migration-pattern.md for target planning; durable Kubernetes cleanup remains clustertool/Flux-owned. | `kubernetes-talos.md`, `migration-pattern.md` |
| Cross-cutting contracts | `../docs/` | Stays the repo-level contract layer. | `ownership-boundary.md` |

## Hard Guardrails

- Do not commit decrypted secrets, Flux deploy keys, Talos secrets, Terraform
  variables, private credentials, or generated credential material as tracked
  plaintext.
- Do not add Terraform guest-state provisioners. Terraform may invoke the
  existing deploy bridge, but NixOS owns guest convergence.
- Do not bypass Flux for Kubernetes workloads that remain cluster-owned.

## Subtree Docs

- `../terraform/README.md`: Terraform-side entrypoint for Proxmox container provisioning.
- `../nixos/README.md`: NixOS subtree entrypoint for guest configuration and secrets flow.
- `../nixos/docs/ops/README.md`: NixOS operator runbook index.

## Operator Flow

1. Read `ownership-boundary.md` for the mental model.
2. Use `home-manager.md` when operating `wsl-desktop` or onboarding another non-NixOS Home Manager target.
3. Follow `template-workflow.md` when you need a new template artifact.
4. Use `../nixos/docs/ops/README.md` to pick the right NixOS runbook.
5. Use `../nixos/docs/ops/deploy-pipeline.md` for end-to-end host bring-up.
6. Run `../scripts/kubernetes-talos.sh verify` and inspect `service-inventory.md` before Phase 4 migration planning.
7. Use `migration-pattern.md` for the migration rubric/template and the `uptime-kuma` implementation plan.
8. Use `../nixos/docs/ops/phase-01-verification.md` for live verification of the current audit-plane stack.
