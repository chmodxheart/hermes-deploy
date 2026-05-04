# Allocation Policy

This document is the canonical human-readable allocation policy for new homelab
Proxmox LXC migrations. It records VMID, IPv4, VLAN, MAC, and service-class
conventions alongside the confirmed Uptime Kuma target baseline.

## Scope And Owners

| Domain | Owner | Policy |
|---|---|---|
| Proxmox envelopes | Terraform | Terraform owns VMID, node placement, CPU, memory, rootfs, bridge, VLAN, IPv4, MAC, tags, and root SSH key references. |
| Guest convergence | NixOS | NixOS owns packages, services, filesystems, firewall policy, users, and guest secrets. |
| Kubernetes source resources | Flux / clustertool | Flux and clustertool remain authoritative for durable Kubernetes resources. Homelab records source evidence only. |
| DNS and ingress | External DNS/ingress owners | External DNS/ingress owners remain authoritative for `uptime.${DOMAIN_0}` and any route changes. |
| Secrets | Platform secret owners | Decrypted secrets must not be recorded. Use encrypted paths and variable names only. |

This scope establishes the canonical allocation policy (D-01, D-02, D-19),
grandfathers existing Terraform-managed audit-plane LXCs on VLAN 1200 (D-10),
keeps external DNS/ingress ownership explicit (D-15), and gives downstream Phase
6, Phase 7, and Phase 8 planners durable baseline values (D-21).

## VLAN Tiers

| Tier | Role | VLANs |
|---|---|---|
| Tier 0 | Primary access and client device VLANs | `10`, `20`, `30`, `40`, `50`, `60`, `70`, `80`, `90`, `100` |
| Tier 1 | Infrastructure VLANs | `1010`, `1020`, `1030`, `1040`, `1050`, `1060`, `1070`, `1080`, `1090`, `1100`, `1200` |
| Tier 2 | Application VLANs | `2010`, `2020`, `2030`, `2040`, `2050`, `2060`, `2100` |
| Tier 3 | Access and endpoint VLANs | `255`, `2255` |

This table seeds the allocation policy from the existing VLAN taxonomy (D-03).

## VMID And Slot Rules

New Proxmox container ID ranges should mirror VLAN IDs where practical so service
class and network placement stay semantically aligned (D-04). Existing
Terraform-managed audit-plane LXCs on VLAN 1200 are grandfathered and do not need
to be renumbered (D-10).

Monitoring UI migrations default to VLAN 2100 and subnet `10.2.100.0/24`
(D-05). Uptime Kuma reserves Monitoring UI slot `30`, IPv4 `10.2.100.30/24`,
MAC suffix `30`, and mirrored VMID `2130` in the VLAN 2100 policy range (D-06).

## Current Reservations

| Host | VMID | IPv4 | MAC | VLAN | Status |
|---|---:|---|---|---:|---|
| `mcp-audit` | `705` | `10.0.120.20/24` | `BC:24:11:AD:00:10` | `1200` | Existing Terraform-managed audit-plane LXC; grandfathered. |
| `mcp-nats01` | `711` | `10.0.120.21/24` | `BC:24:11:AD:00:11` | `1200` | Existing Terraform-managed audit-plane LXC; grandfathered. |
| `mcp-nats02` | `712` | `10.0.120.22/24` | `BC:24:11:AD:00:12` | `1200` | Existing Terraform-managed audit-plane LXC; grandfathered. |
| `mcp-nats03` | `713` | `10.0.120.23/24` | `BC:24:11:AD:00:13` | `1200` | Existing Terraform-managed audit-plane LXC; grandfathered. |

## Uptime Kuma Target Baseline

| Field | Confirmed baseline |
|---|---|
| Hostname | `uptime-kuma` |
| Terraform key | `"uptime-kuma"` |
| VMID | `2130` |
| Node | `pm01` |
| Datastore | `ceph-rbd` |
| Rootfs | `20GiB` |
| CPU | `1` |
| Memory | `1024MiB` |
| VLAN | `2100` |
| IPv4 | `10.2.100.30/24` |
| Gateway | `10.2.100.1` |
| Bridge | `vmbr1` |
| Slot | `30` |
| MAC | `BC:24:11:AD:21:30` |
| Tags | `["migration", "uptime-kuma"]` |
| SSH key source | `pathexpand("~/.ssh/id_ed25519.pub")` |

The sizing and placement retain node `pm01`, datastore `ceph-rbd`, rootfs
`20GiB`, CPU `1`, and memory `1024MiB` unless Phase 6 checks find a conflict
(D-07). Terraform should use the existing SSH key-file pattern
`pathexpand("~/.ssh/id_ed25519.pub")` (D-08).

## Conflict Gates

Before Terraform apply, the operator must confirm static plus safe live
uniqueness checks for VMID `2130`, IPv4 `10.2.100.30/24`, MAC
`BC:24:11:AD:21:30`, and Proxmox node capacity on `pm01` (D-09).

Static repo checks can compare against `terraform/locals.tf` and this document.
Live Proxmox and network checks should be performed where credentials and safe
read-only context are available. If live Proxmox checks are unavailable during
planning or implementation, the missing evidence is a Phase 6 pre-apply gate, not
permission to treat the allocation as live-confirmed.

## Uptime Kuma Source Baseline

| Source fact | Baseline evidence | Owner / guardrail |
|---|---|---|
| Source path | `external/clustertool/clusters/main/kubernetes/apps/uptime-kuma/app/helm-release.yaml` | `clustertool / Flux` owns the durable manifest. |
| Namespace / name | `uptime-kuma` / `uptime-kuma` | Source identity only; target host identity remains homelab-owned. |
| Chart / version | `uptime-kuma` / `14.1.1` | Source evidence for Phase 6 and Phase 7 implementation planning. |
| Ingress host | `uptime.${DOMAIN_0}` | DNS/ingress owner remains external and authoritative. |
| Ingress class | `internal` | Target planning assumes internal-only exposure. |
| Persistence | `config` | Maps to local LXC app data during later restore work. |
| Restore source | VolSync/restic snapshot `uptime-kuma-config` | Restore dry-run proof is required before cutover treats the source as proven. |
| Read-only verification command | `./scripts/kubernetes-talos.sh verify` | Static and live checks are read-only (D-11). |

Secret references are names-only and must never be decrypted or pasted into docs
(D-12). The Uptime Kuma source references `${VOLSYNC_WASABI_NAME}`,
`${VOLSYNC_WASABI_ACCESSKEY}`, `${VOLSYNC_WASABI_BUCKET}`,
`${VOLSYNC_WASABI_ENCRKEY}`, `${VOLSYNC_WASABI_PATH}`,
`${VOLSYNC_WASABI_SECRETKEY}`, `${VOLSYNC_WASABI_URL}`, `${TZ}`,
`${DOMAIN_0}`, and `${CERTIFICATE_ISSUER}`.

2026-05-04 baseline result: static clustertool checks passed,
`flux-system/uptime-kuma` was ready at `main@sha1:9fa8193d`,
`uptime-kuma/uptime-kuma` HelmRelease was ready with chart
`uptime-kuma@14.1.1`, and all Kubernetes nodes reported ready. Record source
baseline evidence as checklist-style paths, commands, and facts rather than full
command-output logs (D-20). Unrelated live cluster issues for other releases do
not block Uptime Kuma target planning.

Restore-source readiness requires a dry-run restore before cutover planning treats
the source as proven (D-13). Missing restore dry-run proof is a Phase 8 cutover
blocker, not a Phase 6 or Phase 7 implementation planning blocker (D-14). These
facts are recorded here so Phase 6, Phase 7, and Phase 8 planners can consume
durable baseline evidence without re-asking for the source path or secret names
(D-21).

## DNS And Cutover Ownership

External DNS/ingress owners remain authoritative for `uptime.${DOMAIN_0}`; this
repo records the target baseline and gate but does not own the external control
plane (D-15). Until later source verification proves another owner-specific path,
target planning assumes direct LXC DNS for the access path (D-16).

`uptime.${DOMAIN_0}` must not be repointed until Phase 8 confirms all cutover
evidence: HTTP health, service logs, UI login, monitor list, restore
evidence/dry-run, rollback path, and explicit rollback window (D-17, D-18).
The missing restore dry-run proof remains a Phase 8 cutover blocker, not a Phase
6 or Phase 7 planning blocker (D-14). This keeps downstream planning durable
without overstating source recoverability (D-21).
