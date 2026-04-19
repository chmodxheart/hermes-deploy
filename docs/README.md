# Docs

Shared documents for the `hermes-deploy` monorepo live here.

## Core Docs

- `ownership-boundary.md`: what Terraform owns, what NixOS owns, and where the crossover stops.
- `template-workflow.md`: the supported way to build and register the NixOS Proxmox LXC template.
- `nixos-handoff.md`: the stable contract exported by Terraform and consumed by the NixOS side.

## Operator Flow

1. Read `ownership-boundary.md` for the mental model.
2. Follow `template-workflow.md` when you need a new template artifact.
3. Use `nixos/docs/ops/deploy-pipeline.md` for end-to-end host bring-up.
4. Use `nixos/docs/ops/phase-01-verification.md` for live verification of the current audit-plane stack.
