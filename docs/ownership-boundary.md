 # Ownership Boundary

 This repo defines the Terraform ↔ NixOS contract for Proxmox LXC provisioning.

 | Area | Terraform owns | `nixos/` owns |
 | --- | --- | --- |
 | Placement and identity | Proxmox node placement, VMID | In-guest hostname use and system identity policy |
 | Resource sizing | CPU, memory, disk | Package footprint and service-level resource use |
 | Networking envelope | Bridge/network attachment | In-guest network behavior and service binding |
 | Metadata | Tags/comments, template selection, exported host facts | Role-specific guest meaning of that metadata |
 | Guest state | None | Users, packages, services, secrets, filesystem policy, and ongoing guest configuration |

 ## Guardrails

 - Terraform owns Proxmox-side container provisioning only.
 - `nixos/` owns guest configuration and ongoing system convergence.
 - Do not use guest bootstrap provisioners such as `remote-exec` or `file` to push guest state from Terraform.
 - Do not normalize privileged bootstrap flows in this repo.
