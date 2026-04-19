# hermes-deploy

Top-level monorepo for the Proxmox LXC lab.

This repo is the deployment system as a whole: Terraform provisions the
Proxmox-side container envelope, NixOS converges the guest systems, and shared
scripts/docs define the operator workflow across both.

## Layout

- `terraform/` provisions Proxmox containers.
- `nixos/` defines guest operating system configuration.
- `scripts/` holds shared operator workflows used across both areas.
- `docs/` holds cross-cutting contract and workflow docs.

## Canonical Paths

- Run Terraform from `terraform/`.
- Run NixOS flake commands from `nixos/`.
- Run shared scripts from the repo root as `./scripts/<name>.sh`.

## Common Workflow

1. Build or refresh the NixOS Proxmox LXC template as documented in `docs/template-workflow.md`.
2. Model or update host inventory in `terraform/locals.tf`.
3. Add or update host definitions and secrets in `nixos/`.
4. Bootstrap per-host age identities from the repo root with `./scripts/add-host.sh <hostname>`.
5. Run `terraform apply` from `terraform/` for end-to-end bring-up.

## Docs

- `docs/README.md`: shared docs index.
- `docs/ownership-boundary.md`: Terraform vs NixOS responsibilities.
- `docs/template-workflow.md`: supported template artifact flow.
- `docs/nixos-handoff.md`: Terraform-to-NixOS host contract.
- `nixos/docs/ops/README.md`: NixOS operator runbook index.
- `nixos/docs/ops/deploy-pipeline.md`: operator runbook for one-command deploys.
