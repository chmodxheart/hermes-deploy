---
phase: 05-target-confirmation-source-baseline
plan: 05
subsystem: docs
tags: [allocation-policy, uptime-kuma, kubernetes, flux, proxmox, migration]

requires: []
provides:
  - Canonical allocation policy for new Proxmox LXC migrations
  - Confirmed Uptime Kuma VMID, IPv4, MAC, VLAN, sizing, and SSH key baseline
  - Uptime Kuma Kubernetes source, restore-source, and DNS/cutover gates
affects: [phase-06-terraform-lxc-envelope, phase-07-nixos-service, phase-08-cutover]

tech-stack:
  added: []
  patterns:
    - Markdown allocation policy with owner and conflict-gate tables
    - Checklist-style Kubernetes source baseline without decrypted secrets

key-files:
  created:
    - docs/allocation-policy.md
  modified:
    - docs/migration-pattern.md

key-decisions:
  - "Use VLAN 2100 / 10.2.100.0/24 and VMID 2130 for Uptime Kuma while grandfathering existing VLAN 1200 audit-plane LXCs."
  - "Treat missing restore dry-run proof as a Phase 8 cutover blocker, not a Phase 6 or Phase 7 implementation blocker."

patterns-established:
  - "Allocation docs cite platform owners and use names-only secret references."
  - "Source baselines record paths, commands, and readiness facts rather than full command output logs."

requirements-completed: [ALLOC-01, ALLOC-02]

duration: 1m45s
completed: 2026-05-04
---

# Phase 5 Plan 05: Target Confirmation And Source Baseline Summary

**Uptime Kuma allocation policy with VLAN 2100 target values, Flux source evidence, and Phase 8 DNS/restore cutover gates**

## Performance

- **Duration:** 1m45s
- **Started:** 2026-05-04T10:55:25Z
- **Completed:** 2026-05-04T10:57:10Z
- **Tasks:** 3/3
- **Files modified:** 2

## Accomplishments

- Created `docs/allocation-policy.md` as the canonical VMID, VLAN, IPv4, MAC, owner, and conflict-gate policy for new LXC migrations.
- Updated the Uptime Kuma migration pattern from the older VLAN 1200 proposal to VLAN 2100, VMID 2130, `10.2.100.30/24`, and `BC:24:11:AD:21:30`.
- Recorded the Flux-owned Uptime Kuma source baseline, VolSync/restic snapshot name, names-only secret references, and Phase 8 DNS/restore blockers.

## Task Commits

Each task was committed atomically:

1. **Task 05-01: Create the allocation policy and Uptime Kuma reservation baseline** - `0cd173a` (docs)
2. **Task 05-02: Update the Uptime Kuma migration pattern target proposal** - `a7ecc22` (docs)
3. **Task 05-03: Record source recoverability, restore source, and DNS/ingress gate** - `5758a26` (docs)

**Plan metadata:** pending final commit

## Files Created/Modified

- `docs/allocation-policy.md` - Canonical allocation policy, Uptime Kuma target baseline, conflict gates, source baseline, and DNS/cutover ownership.
- `docs/migration-pattern.md` - Uptime Kuma first migration target proposal updated to the Phase 5 VLAN 2100 baseline.

## Decisions Made

- Followed Phase 5 decisions D-01 through D-21 as written.
- Kept live Proxmox uniqueness as a Phase 6 pre-apply gate because the plan did not require mutating or credentialed Proxmox checks.
- Kept restore dry-run proof as a Phase 8 cutover blocker rather than blocking Phase 6 or Phase 7 implementation planning.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- `./scripts/kubernetes-talos.sh verify` completed read-only verification and showed Uptime Kuma ready, but also reported unrelated live cluster issues for other releases (`recyclarr`, `metallb-config`, `minio`, `vikunja`, `webnut`) and a skipped Talos health check due to context selection. These were documented as unrelated to the Uptime Kuma source baseline.

## User Setup Required

None - no external service configuration required.

## Known Stubs

None.

## Next Phase Readiness

- Phase 6 can add the Terraform LXC envelope using VMID `2130`, IPv4 `10.2.100.30/24`, gateway `10.2.100.1`, MAC `BC:24:11:AD:21:30`, VLAN `2100`, node `pm01`, datastore `ceph-rbd`, rootfs `20GiB`, CPU `1`, memory `1024MiB`, tags `["migration", "uptime-kuma"]`, and SSH key source `pathexpand("~/.ssh/id_ed25519.pub")`.
- Phase 7 can consume the same hostname, service port, and local app data assumptions without re-asking for target values.
- Phase 8 must still prove restore dry-run evidence, set an explicit rollback window, verify target health/logs/UI/monitor list, and coordinate DNS/ingress ownership before cutover.

## Verification

- `test -f docs/allocation-policy.md` — passed.
- `grep -F "10.2.100.30/24" docs/allocation-policy.md` — passed.
- `grep -F "BC:24:11:AD:21:30" docs/allocation-policy.md` — passed.
- `grep -F "uptime-kuma-config" docs/allocation-policy.md` — passed.
- `grep -F "Phase 8 cutover blocker" docs/allocation-policy.md` — passed.
- `grep -F "http://10.2.100.30:3001/" docs/migration-pattern.md` — passed.
- `./scripts/kubernetes-talos.sh verify` — passed for static checks and Uptime Kuma readiness; unrelated live release failures were present outside Uptime Kuma.

## Self-Check: PASSED

- Found created file: `docs/allocation-policy.md`.
- Found task commits: `0cd173a`, `a7ecc22`, `5758a26`.
- No STATE.md or ROADMAP.md changes were made by this executor.

---
*Phase: 05-target-confirmation-source-baseline*
*Completed: 2026-05-04*
