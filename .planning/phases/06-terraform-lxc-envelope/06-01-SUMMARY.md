---
phase: 06-terraform-lxc-envelope
plan: 01
subsystem: terraform
tags: [terraform, proxmox, lxc, uptime-kuma, migration]

requires:
  - Phase 5 allocation baseline
  - Existing lxc-container Terraform module
provides:
  - Static uptime-kuma Proxmox LXC envelope in Terraform inventory
  - Terraform fmt and validation evidence for the updated inventory
affects:
  - phase-07-nixos-service
  - phase-08-cutover

tech-stack:
  added: []
  patterns:
    - Existing local.containers inventory entry consumed by root module for_each
    - Existing unprivileged NixOS LXC module posture

key-files:
  created:
    - .planning/phases/06-terraform-lxc-envelope/06-01-SUMMARY.md
  modified:
    - terraform/locals.tf

key-decisions:
  - "Use the Phase 5 VLAN 2100 Uptime Kuma baseline and leave existing VLAN 1200 audit-plane entries unchanged."
  - "Treat live Proxmox VMID/IP/MAC uniqueness and pm01 capacity as pre-apply gates because no live read-only Proxmox check was run."

requirements-completed: [PROX-01, PROX-02]

duration: under 5m
completed: 2026-05-04T11:19:35Z
---

# Phase 06 Plan 01: Terraform LXC Envelope Summary

**Uptime Kuma Proxmox envelope added to Terraform inventory with VLAN 2100 target values and static validation evidence.**

## Performance

- **Duration:** under 5m
- **Completed:** 2026-05-04T11:19:35Z
- **Tasks:** 2/2
- **Files modified:** 2 (`terraform/locals.tf` and this summary)

## Accomplishments

- Added exactly one `"uptime-kuma"` entry to `terraform/locals.tf` using the locked Phase 5 baseline: VMID `2130`, node `pm01`, IPv4 `10.2.100.30/24`, gateway `10.2.100.1`, MAC `BC:24:11:AD:21:30`, VLAN `2100`, bridge `vmbr1`, `ceph-rbd`, `20GiB`, `1` CPU, `1024MiB`, tags `migration`/`uptime-kuma`, and the existing SSH key file source.
- Reused the existing `local.containers` -> root `module "lxc_container"` `for_each` path; no new Terraform resource, provider, backend, provisioner, NixOS, DNS, Kubernetes, or secret files were added.
- Ran static fixed-string conflict gates against `terraform/locals.tf` and `docs/allocation-policy.md`, then ran Terraform formatting and validation.

## Task Commits

1. **Task 1: Add the locked uptime-kuma Terraform inventory entry** - `7e1fa67` (feat)
2. **Task 2: Run static conflict gates and Terraform validation** - verification-only; no implementation files changed after Task 1. Evidence is recorded in this summary commit.

## Files Created/Modified

- `terraform/locals.tf` - Added the `uptime-kuma` container inventory entry.
- `.planning/phases/06-terraform-lxc-envelope/06-01-SUMMARY.md` - Execution evidence and pre-apply gates.

## Decisions Made

- Followed the Phase 5/Phase 6 VLAN `2100` baseline for Uptime Kuma instead of stale VLAN 1200 requirement wording.
- Left existing MCP audit-plane VLAN 1200 entries unchanged.
- Did not claim live Proxmox uniqueness or capacity; those checks remain pre-apply gates.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- The worktree contained unrelated pre-existing modifications and untracked files outside this plan. They were not staged or committed.

## User Setup Required

- Before Terraform apply, the operator must run safe live checks for VMID `2130`, IPv4 `10.2.100.30/24`, MAC `BC:24:11:AD:21:30`, and `pm01` capacity.
- If a fresh workspace lacks provider initialization, run `terraform -chdir=terraform init -backend=false` before validation.

## Known Stubs

None.

## Threat Flags

None. The plan touched only the existing Terraform inventory surface described by the plan threat model.

## Verification

- Static conflict gate comparing `terraform/locals.tf` and `docs/allocation-policy.md` for key, VMID, IPv4, gateway, MAC, VLAN, node, datastore, sizing, tags, and SSH key source — passed.
- `terraform -chdir=terraform fmt -check` — passed.
- `terraform -chdir=terraform validate` — passed.
- Live Proxmox uniqueness/capacity — not run; recorded as a pre-apply gate.

## Self-Check: PASSED

- Found modified file: `terraform/locals.tf`.
- Found summary file: `.planning/phases/06-terraform-lxc-envelope/06-01-SUMMARY.md`.
- Found task commit: `7e1fa67`.
- No STATE.md or ROADMAP.md changes were made by this executor.

---
*Phase: 06-terraform-lxc-envelope*
*Completed: 2026-05-04T11:19:35Z*
