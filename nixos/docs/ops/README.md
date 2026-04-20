# Ops Docs

Runbooks for the `nixos/` subtree live here.

Use this directory for guest-side operator procedures. For Proxmox container
provisioning and the Terraform-to-NixOS contract, start from the shared docs in
`../../../docs/` and the Terraform root in `../../../terraform/`.

## Monorepo Map

- Shared contract and ownership docs: [`../../../docs/README.md`](../../../docs/README.md)
- Shared runtime architecture diagram: [`../../../docs/end-state-data-flow.md`](../../../docs/end-state-data-flow.md)
- Terraform infrastructure entrypoint: [`../../../terraform/README.md`](../../../terraform/README.md)
- NixOS subtree entrypoint: [`../../README.md`](../../README.md)

## Runbooks

- [`deploy-pipeline.md`](deploy-pipeline.md): end-to-end deploy flow when
  `terraform apply` drives both provisioning and NixOS convergence.
- [`new-lxc-checklist.md`](new-lxc-checklist.md): checklist for adding another
  NixOS LXC host to the monorepo.
- [`nats-bring-up.md`](nats-bring-up.md): one-time NATS cluster bootstrap.
- [`langfuse-minio-bucket.md`](langfuse-minio-bucket.md): one-time MinIO bucket
  and IAM setup for Langfuse object storage.
- [`phase-01-verification.md`](phase-01-verification.md): audit-plane live-host
  verification manual.

## Suggested Order

1. Read [`../../../docs/ownership-boundary.md`](../../../docs/ownership-boundary.md).
2. Build or refresh the template via
   [`../../../docs/template-workflow.md`](../../../docs/template-workflow.md).
3. Add or update hosts with [`new-lxc-checklist.md`](new-lxc-checklist.md).
4. Use [`deploy-pipeline.md`](deploy-pipeline.md) for routine deploys.
5. Use [`phase-01-verification.md`](phase-01-verification.md) when validating
   the audit-plane stack.
