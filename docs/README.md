# Docs

Shared documents for the `hermes-deploy` monorepo live here.

Use this directory for cross-cutting contracts between `terraform/` and
`nixos/`. Subtree-specific runbooks live under `../nixos/docs/ops/`.

## Core Docs

- `ownership-boundary.md`: what Terraform owns, what NixOS owns, and where the crossover stops.
- `template-workflow.md`: the supported way to build and register the NixOS Proxmox LXC template.
- `nixos-handoff.md`: the stable contract exported by Terraform and consumed by the NixOS side.

## Subtree Docs

- `../terraform/README.md`: Terraform-side entrypoint for Proxmox container provisioning.
- `../nixos/README.md`: NixOS subtree entrypoint for guest configuration and secrets flow.
- `../nixos/docs/ops/README.md`: NixOS operator runbook index.

## Operator Flow

1. Read `ownership-boundary.md` for the mental model.
2. Follow `template-workflow.md` when you need a new template artifact.
3. Use `../nixos/docs/ops/README.md` to pick the right NixOS runbook.
4. Use `../nixos/docs/ops/deploy-pipeline.md` for end-to-end host bring-up.
5. Use `../nixos/docs/ops/phase-01-verification.md` for live verification of the current audit-plane stack.
