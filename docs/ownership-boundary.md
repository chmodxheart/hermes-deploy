# Ownership Boundary

This repo is the operator source of truth for the homelab, but each platform
still owns a distinct layer. The table separates current ownership from planned
integration direction so future intent is not mistaken for completed control.

| Domain | Current owner | Current source | Planned direction | External owner | Hard guardrail |
| --- | --- | --- | --- | --- | --- |
| Proxmox envelopes | Terraform | `terraform/` | Stays Terraform-owned. | Proxmox VE cluster | Terraform owns node placement, VMID, CPU, memory, disk, MAC/IP envelope, template selection, and root SSH key injection only. |
| NixOS guest convergence | NixOS flake | `nixos/` | Stays NixOS-owned. | NixOS/nixpkgs inputs | NixOS owns users, packages, services, secrets, firewall policy, filesystem policy, and ongoing guest configuration. |
| Home Manager user state | Home Manager | `~/repo/home-manager` | Referenced from homelab through docs/home-manager.md and scripts/home-manager.sh. | Home Manager repo/workflow | Home Manager owns user-level workstation state; do not commit decrypted user secrets into this repo. |
| Kubernetes resources | Flux/Talos | `external/clustertool` | Referenced from homelab; Flux/Talos remains authoritative. | Talos cluster and Flux GitOps source | Homelab may verify and inventory cluster state, but durable Kubernetes resource changes must land in clustertool and reconcile through Flux. |
| SOPS/age and platform secrets | Platform-specific secret owners | `nixos/secrets/*.yaml`, `.sops.yaml`, ignored local stores, `external/clustertool` encrypted metadata, and external secret sources | Imported Home Manager and Kubernetes/Talos material must preserve encrypted boundaries; homelab defaults inspect Kubernetes SOPS files only for encrypted metadata. | SOPS/age, Flux deploy keys, Talos secrets, Terraform variable stores | Decrypted SOPS/age material, Flux deploy keys, Talos secrets, Terraform variables, private credentials, and generated credential material must not be committed as tracked plaintext. |
| DNS/ingress | External DNS/ingress operators | Current external DNS/ingress systems and platform runbooks | Future phases may document references, not silently move ownership. | Samba AD DNS, router, ingress/GitOps systems | This repo may document records and dependencies, but the owning DNS/ingress system remains authoritative. |
| storage | Platform storage owners | Proxmox/Ceph, MinIO, Kubernetes PVs, and host filesystems as applicable | Document boundaries per service as migrations happen. | Proxmox/Ceph, MinIO, Kubernetes storage controllers | Do not move storage ownership across platforms without an explicit per-service cutover and rollback plan. |
| backups | Backup platform owners | PBS/vzdump policy, NixOS PBS excludes, and platform backup jobs | Keep backup responsibility explicit for every moved service. | Proxmox Backup Server and platform-native backup systems | Backup docs must not include decrypted runtime secrets or restored `/run/secrets` material in tracked files. |
| monitoring | Platform monitoring owners | NixOS exporters, Vector, NATS/Langfuse audit plane, and external scrape systems | Keep scrape and audit ownership explicit as services move. | Prometheus/scrape systems, NATS, Langfuse | Monitoring carve-outs must stay narrow; telemetry sinks must not become control paths back into producers. |
| external systems | The external system itself | Current external repos/services | This repo documents touchpoints and planned integration only. | Home Manager, Talos, Flux, DNS, storage, backup, and monitoring systems | Documentation must not imply the homelab repo owns systems it only coordinates with. |

## Terraform to NixOS Contract

| Area | Terraform owns | `nixos/` owns |
| --- | --- | --- |
| Placement and identity | Proxmox node placement, VMID | In-guest hostname use and system identity policy |
| Resource sizing | CPU, memory, disk | Package footprint and service-level resource use |
| Networking envelope | Bridge/network attachment | In-guest network behavior and service binding |
| Metadata | Tags/comments, template selection, exported host facts | Role-specific guest meaning of that metadata |
| Guest state | None | Users, packages, services, secrets, filesystem policy, and ongoing guest configuration |

## Hard guardrails

- Terraform owns Proxmox envelopes only; NixOS owns guest convergence.
- Do not use `remote-exec` or `file` provisioners to push guest state from
  Terraform.
- The existing `null_resource.nixos_deploy`/`local-exec` bridge is allowed only
  because it invokes the NixOS-owned `scripts/bootstrap-host.sh` workflow. It is
  not Terraform-owned guest configuration.
- Home Manager owns user-level workstation state.
- Flux owns Kubernetes workloads that remain in-cluster.
- Decrypted SOPS/age material, Flux deploy keys, Talos secrets, Terraform
  variables, private credentials, and generated credential material must not be
  committed as tracked plaintext.

See `nixos-handoff.md` for the normalized Terraform-to-NixOS contract and
`../nixos/docs/ops/deploy-pipeline.md` for the accepted deploy bridge details.
