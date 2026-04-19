# modules/lxc-container

One unprivileged, NixOS-targeted Proxmox LXC container.

## Contract

Owns exactly one `proxmox_virtual_environment_container` resource from the
`bpg/proxmox` provider. The root module composes many callers via `for_each`
and aggregates each caller's `host` output into the root `nixos_hosts` output.

## Inputs

| Name | Type | Default | Required | Purpose |
|------|------|---------|----------|---------|
| `name` | `string` | — | yes | Terraform identifier and default hostname source. |
| `hostname` | `string` | `null` | no | DNS hostname if different from `name`. |
| `node` | `string` | — | yes | Proxmox cluster node. |
| `vmid` | `number` | — | yes | Explicit VMID, integer `>= 100`. |
| `nixos_role` | `string` | — | yes | Handoff key for `nixos/`. |
| `template_file_id` | `string` | — | yes | `storage:vztmpl/<filename>`, re-validated in-module. |
| `bridge` | `string` | `"main"` | no | Proxmox bridge for `net0`. |
| `ipv4` | `string` | — | yes | Static IPv4 CIDR. |
| `gateway` | `string` | — | yes | IPv4 gateway. |
| `mac_address` | `string` | — | yes | Stable MAC for `net0`. |
| `ssh_authorized_keys` | `list(string)` | `[]` | conditional | Literal public keys. |
| `ssh_authorized_key_files` | `list(string)` | `[]` | conditional | Public-key file paths. |
| `rootfs_datastore` | `string` | — | yes | Proxmox storage id for the rootfs. |
| `rootfs_size_gib` | `number` | `8` | no | Rootfs size in GiB. |
| `cpu_cores` | `number` | `1` | no | CPU cores. |
| `memory_mib` | `number` | `1024` | no | Dedicated memory in MiB. |
| `memory_swap_mib` | `number` | `512` | no | Swap in MiB. |
| `start_on_boot` | `bool` | `true` | no | Autostart on node boot. |
| `tags` | `list(string)` | `[]` | no | Extra Proxmox tags; module prepends `nixos`. |

At least one entry across `ssh_authorized_keys` and `ssh_authorized_key_files`
is required. `ssh-agent` passthrough for guest keys is deliberately unsupported.

## Outputs

- `host`: object matching `contracts/nixos-hosts.schema.json` host record.

## Example Caller

```hcl
module "lxc_container" {
  for_each = local.containers
  source   = "./modules/lxc-container"

  name                     = each.key
  node                     = each.value.node
  vmid                     = each.value.vmid
  ipv4                     = each.value.ipv4
  gateway                  = each.value.gateway
  mac_address              = each.value.mac_address
  nixos_role               = each.value.nixos_role
  rootfs_datastore         = each.value.rootfs_datastore
  ssh_authorized_key_files = [pathexpand("~/.ssh/id_ed25519.pub")]
  template_file_id         = var.template_file_id
}
```

## Security Posture

This module keeps the SAFE-01 posture by leaving risky paths out of the
interface entirely.

- `unprivileged = true` is hardcoded.
- `features { nesting = true }` is the only enabled feature block.
- `ssh_user = "root"` is hardcoded for bootstrap; `nixos/` owns later
  user creation and SSH hardening.
- Static IPv4 only; DHCP is intentionally unsupported to preserve stable host
  identity.

Public keys provided through `file()` become part of Terraform state, so callers
should pass only public `*.pub` material here.

If a future workload needs privileged mode, extra feature flags, or guest-side
bootstrap beyond this envelope, add that in a later phase with an explicit
justification instead of widening this module ad hoc.

### Canonical references

- `../../../docs/ownership-boundary.md` for the Terraform vs `nixos/` split.
- `.planning/research/PITFALLS.md` §3 for NixOS LXC nesting requirements.
- `.planning/research/PITFALLS.md` §4 for privileged-container and mount safety.
- `contracts/nixos-hosts.schema.json` for the emitted `host` shape.
