# NixOS handoff contract

This monorepo's Terraform stack is the upstream producer of container facts for `nixos/`. The
NixOS flake is the downstream consumer. The only supported interface between the two areas is the
`nixos_hosts` contract defined in `terraform/contracts/nixos-hosts.schema.json`.

## Contract location

- Schema: `terraform/contracts/nixos-hosts.schema.json` (authoritative, versioned via `schema_version`).
- Example payload: `terraform/examples/nixos-hosts.example.json`.
- Terraform surface: `terraform/outputs.tf` exposes `nixos_hosts_contract_schema`,
  `nixos_hosts_contract_example`, and `nixos_hosts_contract_version`.

## Rules for future Terraform phases

1. Future Terraform outputs producing real host facts **must match this schema exactly**. Field
   names, field types, and the object keyed by Terraform container name are locked by
   `schema_version` `1.0.0`. Adding a new field is a minor bump; renaming or removing a field is a
   major bump.
2. Do not introduce provider-internal resource attributes into the downstream interface. The NixOS
   repo consumes the normalized contract, not `proxmox_virtual_environment_container.*` attribute
   shapes.
3. Do not leak secrets through these outputs. `api_token`, passwords, and SSH private key material
   must never appear in the rendered contract.

## Rules for `nixos/`

1. `nixos/` should read the normalized contract (schema + example, or real output once
   produced) and derive flake inputs from it. It must not reach into Proxmox provider internals.
2. `nixos/` should pin on `schema_version` so a breaking change here fails loudly there.
3. `nixos/` owns everything the ownership boundary doc assigns to it (users, packages,
   services, secrets, filesystem policy). Terraform only guarantees the host facts described in
   this contract.

## Why this exists

Locking the downstream interface in Phase 1 prevents later provisioning phases from inventing ad
hoc host shapes. Provider releases, module refactors, and VMID reshuffles are all allowed as long
as the rendered contract still validates against `nixos-hosts.schema.json`.
