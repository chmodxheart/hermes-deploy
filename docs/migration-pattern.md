# Kubernetes-to-LXC Migration Pattern

This runbook defines the repeatable pattern for moving one Kubernetes workload to
a Proxmox LXC converged by NixOS. It is operator-facing documentation: use it to
score candidates, copy a per-service template, and keep platform ownership
visible before any implementation plan changes Terraform, NixOS, DNS, backups,
or clustertool.

## Source Of Truth

`inventory/services.json` is the machine-readable service inventory and the
source of truth for automation. `docs/service-inventory.md` is the human-readable
catalog derived from that inventory. Kubernetes manifests remain owned by
`external/clustertool` and Flux/Talos; LXC envelopes remain owned by Terraform;
guest convergence remains owned by the `nixos/` flake.

Phase 3 migration triage is input evidence only. Phase 4 owns final candidate
selection, scoring rationale, target mapping, cutover sequencing, rollback, DNS,
backup, monitoring, and secret-handling requirements for each selected move.

## Weighted Evidence Rubric

Score each candidate from 0 to the listed weight. Higher scores mean a safer
first migration. Low-risk proof comes before maximum memory savings.

| Criterion | Weight | Evidence to record | Scoring direction |
|---|---:|---|---|
| low criticality / blast radius | 20 | Service role, users affected, platform dependency notes | Higher means failure is isolated and non-platform-critical. |
| backup/restore clarity | 15 | Backup owner, restore source, restore test or evidence path | Higher means the restore path is known before cutover. |
| low statefulness complexity | 15 | Database, PVC, NFS, object storage, and local-data notes | Higher means fewer coupled state systems. |
| rollback simplicity | 15 | Recoverable source manifests, DNS reversal, data rewind notes | Higher means traffic can return to Kubernetes safely. |
| ingress/DNS simplicity | 10 | Hostnames, ingress class, certificate owner, target route | Higher means one internal route with clear ownership. |
| Kubernetes-controller coupling | 10 | Whether the workload owns cluster control-plane behavior | Higher means the app is not a controller or cluster primitive. |
| monitoring impact | 5 | Existing checks, logs, exporters, or manual verification | Higher means no new monitoring platform is needed. |
| memory-pressure relief | 10 | Requested, limited, and observed resource usage evidence | Higher means clear Proxmox memory relief with real evidence. |

Observed resource usage must be recorded as real evidence when available and as
`unknown` when not available. Do not infer low utilization from Kubernetes
requests or limits alone; requests and limits can show reservation pressure, but
they are not observed use.

Phase 3 triage labels are evidence inputs only. They help shortlist candidates,
but Phase 4 owns the final candidate decision and must explain why the chosen
service is safer than other candidates.

## Scoring Rules

1. Record the service name, source path, Phase 3 triage label, requested
   resources, limits, observed resource usage, and evidence paths before scoring.
2. Assign each criterion a numeric value from 0 to the criterion weight. Do not
   award points for unknown evidence unless the unknown is itself low-risk.
3. Keep low-risk-first selection explicit. A service with lower memory relief can
   beat a larger memory target when it has clearer backups, simpler rollback,
   lower statefulness, or lower blast radius.
4. Treat observed resource usage as required evidence when available. If metrics
   are not collected, write `observed=unknown` and lower confidence in the
   memory-pressure relief score.
5. Include every score's source path or command output reference. A score without
   evidence is a draft, not a decision.
6. Re-score after source manifests, restore evidence, ingress ownership, or
   runtime metrics change.

## Candidate Decision Record

Copy this table for every service considered in a migration wave.

| Service | Score | Phase 3 triage | Observed usage | Evidence gaps | Decision |
|---|---:|---|---|---|---|
| `<service>` | `<0-100>` | `<candidate/maybe/stay/blocked/unknown>` | `<value or unknown>` | `<missing evidence>` | `<first / runner-up / deferred>` |

Required decision notes:

- Why this service is safer or more urgent than the alternatives.
- Which rubric criteria drove the selection.
- Which evidence paths support the score.
- Which unknowns remain and why they do not block planning.
- Which owner performs any Kubernetes, DNS/ingress, storage, backup, or monitoring
  change outside homelab.

## Ownership Guardrails

| Work | Owner | Homelab role | Guardrail |
|---|---|---|---|
| Source Kubernetes manifests | clustertool / Flux | Reference and verify only | Do not mutate durable cluster resources from homelab. |
| Proxmox LXC envelope | Terraform | Define node, VMID, CPU, memory, disk, MAC, IP | Do not push guest state through Terraform. |
| Guest convergence | NixOS flake | Define packages, services, users, filesystems, firewall, SOPS refs | Do not make NixOS state a Kubernetes concern. |
| Secrets | Platform secret owners | Reference encrypted paths and variable names | Never paste decrypted secret material into tracked files. |
| DNS/ingress | External DNS/ingress owner | Document cutover and rollback requirements | Do not imply homelab owns authoritative records. |
| Backups and storage | Backup/storage owners | Require restore evidence and target ownership | Do not move data without per-service rollback. |
| Monitoring | Existing monitoring owners | State logs/exporters/manual checks | Do not create a control path through telemetry. |

Do not decrypt or paste SOPS, age, Flux, Talos, Terraform, or NixOS secret material; reference encrypted paths, variable names, and owner systems only.

Durable Kubernetes disable, suspend, delete, or cleanup work belongs in clustertool and reconciles through Flux, not direct homelab kubectl mutations.

## Reusable Per-Service Migration Template

Copy this section into a service-specific plan or runbook and replace every
placeholder before implementation.

### Service Identity

- Service: `<service>`
- Current platform: Kubernetes / Flux / Talos
- Target platform: Proxmox LXC + NixOS
- Phase 3 triage label: `<candidate/maybe/stay/blocked/unknown>`
- Final Phase 4 decision: `<first candidate / runner-up / deferred>`
- Summary rationale: `<one paragraph>`

### Source Kubernetes Manifest Paths

| Source item | Path | Owner | Evidence needed |
|---|---|---|---|
| HelmRelease / Kustomization | `<external/clustertool/...>` | clustertool / Flux | Chart, values, namespace, health status |
| Namespace | `<external/clustertool/...>` | clustertool / Flux | Namespace and app identity |
| Secret metadata | `<encrypted path or variable name>` | clustertool / SOPS | Names only; no decrypted values |
| Persistence / backup manifests | `<external/clustertool/...>` | clustertool / backup owner | Restore source and backup owner |

### Target Terraform LXC Envelope

| Field | Planned value | Owner | Verification |
|---|---|---|---|
| Inventory key / hostname | `<target-host>` | homelab Terraform | Present in `terraform/locals.tf` |
| Proxmox node | `<pmXX>` | homelab Terraform | Operator confirms capacity |
| VMID / IP / MAC | `<vmid> / <cidr> / <mac>` | homelab Terraform | Operator confirms uniqueness |
| CPU / memory / disk | `<cores> / <MiB> / <GiB>` | homelab Terraform | Sized from evidence |
| Tags | `<tags>` | homelab Terraform | Identifies migration service |

### Target NixOS Host/Module Changes

| Target item | Planned path | Owner | Notes |
|---|---|---|---|
| Flake host entry | `nixos/flake.nix#nixosConfigurations.<target-host>` | homelab NixOS | Use existing `mkHost` pattern. |
| Host module | `nixos/hosts/<target-host>/default.nix` | homelab NixOS | Own firewall and host identity. |
| Service module | `nixos/modules/<service>.nix` or host-local config | homelab NixOS | Use systemd or digest-pinned OCI. |
| SOPS references | `nixos/secrets/<target-host>.yaml` keys | homelab SOPS/NixOS | Names and paths only. |

### Data Restore Path

| Data item | Source | Target | Evidence before cutover |
|---|---|---|---|
| App data | `<backup/PVC/export/source>` | `<local LXC path>` | Restore command, timestamp, and checksum or UI proof |
| Database | `<db owner or none>` | `<target db/path>` | Migration or restore proof |
| File permissions | `<source owner/mode>` | `<target owner/mode>` | NixOS activation or service startup evidence |

### Secret Mapping

| Secret purpose | Source reference | Target reference | Owner |
|---|---|---|---|
| `<purpose>` | `<encrypted path or variable name>` | `<SOPS key/path>` | `<owner>` |

Only reference encrypted paths, variable names, and owner systems. Do not copy,
decrypt, print, or commit secret values.

### Networking/Ingress/DNS Changes

| Route | Source behavior | Target behavior | Owner | Cutover check |
|---|---|---|---|---|
| `<hostname>` | `<Kubernetes ingress>` | `<LXC IP/reverse proxy>` | external DNS/ingress owner | `<HTTP/UI/TLS check>` |

### Backup Ownership

| Backup scope | Pre-migration owner | Post-migration owner | Required proof |
|---|---|---|---|
| App data | `<owner>` | `<owner>` | Restore evidence and next backup plan |
| Host/LXC | `<owner>` | `<owner>` | Excludes secrets and runtime paths |

### Monitoring Expectations

| Signal | Source check | Target check | Owner |
|---|---|---|---|
| Service health | Flux HelmRelease or app endpoint | systemd/OCI status and app endpoint | operator/NixOS |
| Logs | Kubernetes pod logs | journald or container logs | operator/NixOS |
| Metrics | cluster Prometheus if scraped | host exporter, scrape path, or manual check | monitoring owner |

The migration may reuse host logs/exporters, existing Prometheus scrape paths, or
documented manual checks. Do not create a new monitoring platform only to move a
low-risk service.

### Cutover Checks

| Check | Command or evidence | Required result |
|---|---|---|
| Source still recoverable | `./scripts/kubernetes-talos.sh verify` | Static checks pass; live skips are acceptable if context is unavailable. |
| Target builds | `nix build ./nixos#nixosConfigurations.&lt;target-host&gt;.config.system.build.toplevel` | Build succeeds. |
| Terraform validates | `terraform -chdir=terraform validate` | Validation succeeds. |
| Service health | `<curl/UI/systemctl/podman check>` | App responds and data is present. |
| Restore evidence | `<restore proof>` | Data, auth, and critical records are present. |
| DNS/ingress | `<HTTP/TLS check>` | External owner confirms route points to target. |

### Rollback Steps

1. Stop or isolate the LXC target service without deleting restored data.
2. Ask the DNS/ingress owner to point traffic back to the Kubernetes route.
3. Use clustertool/Flux-owned workflow to resume or reconcile the source service
   if it was suspended after cutover.
4. Verify Kubernetes service health and user-visible route.
5. Record what failed and keep LXC evidence for diagnosis.
6. Do not delete source manifests or backup paths until rollback is no longer
   required by the service-specific plan.

### Candidate Scoring Table

| Criterion | Weight | Score | Evidence path or command | Notes |
|---|---:|---:|---|---|
| low criticality / blast radius | 20 | `<score>` | `<path>` | `<notes>` |
| backup/restore clarity | 15 | `<score>` | `<path>` | `<notes>` |
| low statefulness complexity | 15 | `<score>` | `<path>` | `<notes>` |
| rollback simplicity | 15 | `<score>` | `<path>` | `<notes>` |
| ingress/DNS simplicity | 10 | `<score>` | `<path>` | `<notes>` |
| Kubernetes-controller coupling | 10 | `<score>` | `<path>` | `<notes>` |
| monitoring impact | 5 | `<score>` | `<path>` | `<notes>` |
| memory-pressure relief | 10 | `<score>` | `<path>` | `<notes>` |
| **Total** | **100** | `<score>` |  |  |

### Manifest-To-Target Mapping

| Source Kubernetes field | Evidence | Target homelab mapping | Owner |
|---|---|---|---|
| Namespace/name | `<namespace>/<name>` | `<target-host>` | homelab Terraform/NixOS |
| Helm chart/image | `<chart or image>` | `<NixOS package/systemd/OCI>` | homelab NixOS |
| Ingress host | `<hostname>` | `<target route>` | external DNS/ingress owner |
| Persistence | `<PVC/VolSync/restic>` | `<local LXC data path>` | backup/storage + NixOS |
| Secrets | `<encrypted refs>` | `<SOPS refs>` | source secret owner + homelab SOPS |
| Health | `<source status>` | `<target endpoint/status>` | operator/NixOS |
| Cleanup | `<Flux path>` | `<clustertool PR/task>` | clustertool/Flux |

## Uptime Kuma First Migration Plan

This plan maps the selected `uptime-kuma` Kubernetes source into a proposed
Terraform and NixOS target. It does not execute the migration. The target values
below are proposed operator-confirmation values because free VMID, IP, and MAC
inventory is not encoded in repo docs. Confirm those values before implementation
or Terraform apply.

The reusable checklist in this document remains generic. The authoritative
Phase 8 service-specific cutover runbook for Uptime Kuma is
`docs/uptime-kuma-cutover.md`; use it for restore evidence, target verification,
the DNS/ingress request, rollback window, and clustertool/Flux cleanup handoff.

The older VLAN 1200 proposal was superseded by Phase 5; existing audit-plane
VLAN 1200 allocations remain grandfathered.

Implementation must pin any OCI image by digest if OCI is used.

### Source Evidence

| Source field | Evidence value | Owner / note |
|---|---|---|
| HelmRelease path | `external/clustertool/clusters/main/kubernetes/apps/uptime-kuma/app/helm-release.yaml` | clustertool / Flux owns the durable source manifest. |
| Namespace / name | `uptime-kuma` / `uptime-kuma` | Source identity only; target hostname remains homelab-owned. |
| Chart | `uptime-kuma` | Do not copy Helm state into homelab. |
| Chart version | `14.1.1` | Source evidence for implementation planning. |
| Ingress | `uptime.${DOMAIN_0}` | DNS/ingress owner remains authoritative. |
| Ingress class | `internal` | Target must preserve internal-only exposure. |
| Persistence | `config` | Maps to local LXC data storage. |
| Backup | `VolSync/restic` | Restore evidence required before cutover. |
| Snapshot | `uptime-kuma-config` | Source backup/snapshot evidence. |
| Secret refs | `${VOLSYNC_WASABI_NAME}`, `${VOLSYNC_WASABI_ACCESSKEY}`, `${VOLSYNC_WASABI_BUCKET}`, `${VOLSYNC_WASABI_ENCRKEY}`, `${VOLSYNC_WASABI_PATH}`, `${VOLSYNC_WASABI_SECRETKEY}`, `${VOLSYNC_WASABI_URL}`, `${TZ}`, `${DOMAIN_0}`, `${CERTIFICATE_ISSUER}` | Variable names only; never decrypt or paste values into tracked docs. |

### Target Proposal

| Target field | Proposed value | Target owner / verification |
|---|---|---|
| Hostname | `uptime-kuma` | Homelab NixOS host identity. |
| Terraform key | `"uptime-kuma"` | Add under `terraform/locals.tf` during implementation. |
| VMID | `2130` | Operator must confirm uniqueness. |
| IPv4 | `10.2.100.30/24` | Operator must confirm availability. |
| Gateway | `10.2.100.1` | Matches the Monitoring UI VLAN target. |
| MAC | `BC:24:11:AD:21:30` | Operator must confirm uniqueness. |
| Node | `pm01` | Operator must confirm placement capacity. |
| VLAN | `2100` | Monitoring UI VLAN from docs/allocation-policy.md. |
| Bridge | `vmbr1` | Existing LXC network bridge. |
| Rootfs datastore | `ceph-rbd` | Existing Terraform LXC pattern. |
| Rootfs size | `20GiB` | Proposed app/data disk envelope. |
| CPU | `1` | Proposed low-duty-cycle service allocation. |
| Memory | `1024MiB` | Proposed first target memory envelope. |
| Tags | `["migration", "uptime-kuma"]` | Identifies service and migration context. |
| NixOS host path | `nixos/hosts/uptime-kuma/default.nix` | Add during implementation. |
| NixOS module path | `nixos/modules/uptime-kuma.nix` | Add during implementation if service module is used. |
| Service port | `3001` | Open only through the intended internal path. |
| Data path | `/var/lib/uptime-kuma:/app/data` | Restore local app data here before startup/cutover. |

Target implementation should map `terraform/locals.tf` to the Proxmox envelope,
`nixos/flake.nix` to `nixosConfigurations.uptime-kuma`,
`nixos/hosts/uptime-kuma/default.nix` to host identity/firewall/storage, and
`nixos/modules/uptime-kuma.nix` to service convergence. Terraform must not push
guest configuration; NixOS must own the service, firewall, filesystem, and SOPS
references.

### Implementation Task Map

| Task area | Owner | Implementation work | Verification / gate |
|---|---|---|---|
| Source verification | homelab read-only | Run `./scripts/kubernetes-talos.sh verify` against the pinned clustertool source and confirm the HelmRelease evidence remains recoverable. | Static checks pass; live checks may skip when context is unavailable. |
| Terraform envelope | homelab Terraform | Add `"uptime-kuma"` to `terraform/locals.tf` with the proposed node, VMID, IPv4, gateway, MAC, VLAN, bridge, rootfs, CPU, memory, tags, and key-file shape. | `terraform -chdir=terraform validate` passes after implementation. |
| NixOS flake entry | homelab NixOS | Add `nixosConfigurations.uptime-kuma` to `nixos/flake.nix` using the existing `mkHost` + `./profiles/lxc.nix` pattern. | `nix build ./nixos#nixosConfigurations.uptime-kuma.config.system.build.toplevel` passes. |
| Host config | homelab NixOS | Create `nixos/hosts/uptime-kuma/default.nix` for host identity, local storage, firewall, and encrypted secret references by name only. | Host config evaluates and exposes only intended SSH/service paths. |
| Service module | homelab NixOS | Create `nixos/modules/uptime-kuma.nix` or equivalent host-local service config with local `/var/lib/uptime-kuma` data and port `3001`. Pin any OCI image by digest if OCI is used. | Service starts and `curl -fsS http://10.2.100.30:3001/` succeeds after deployment. |
| Inventory/docs | homelab docs/inventory | Update `inventory/services.json`, `docs/service-inventory.md`, and related docs only after target state is implemented or status changes. | `python3 scripts/validate-inventory.py inventory/services.json` passes. |
| DNS/ingress cutover | external DNS/ingress owner | Repoint `uptime.${DOMAIN_0}` from Kubernetes internal ingress to the verified LXC/reverse-proxy path. | DNS/ingress confirmation for `uptime.${DOMAIN_0}` after target health passes. |
| Flux cleanup | clustertool / Flux | Perform any HelmRelease suspend, resume, delete, or durable cleanup only from clustertool after LXC verification. | Cleanup is delayed until rollback window and source recoverability requirements are satisfied. |

### Cutover Verification Gate

Do not change DNS/ingress until all applicable checks are complete:

```bash
terraform -chdir=terraform validate
nix build ./nixos#nixosConfigurations.uptime-kuma.config.system.build.toplevel
python3 scripts/validate-inventory.py inventory/services.json
./scripts/kubernetes-talos.sh verify
curl -fsS http://10.2.100.30:3001/
```

Additional required evidence:

- DNS/ingress confirmation for `uptime.${DOMAIN_0}` after the external owner
  points traffic to the LXC/reverse-proxy path.
- Backup/restore evidence for `/var/lib/uptime-kuma`, including source,
  timestamp, and proof that restored data is usable before service cutover.
- UI login/monitor list check proving auth and critical monitor definitions
  survived the restore.

### Monitoring Plan

Use existing checks before adding new monitoring systems:

- Source-side monitoring remains Flux HelmRelease status and any existing cluster
  Prometheus scrape while the Kubernetes source is recoverable.
- Target-side baseline is host logs from journald or container logs plus direct
  HTTP health on `http://10.2.100.30:3001/`.
- If existing Prometheus scrape paths cover LXC exporters, use the existing host
  exporter path and keep any carve-out narrow. If not, document manual checks for
  the first migration instead of creating a new monitoring platform.
- The final cutover gate must include the manual UI login/monitor list check even
  when logs or exporters are healthy.

### Rollback Plan

1. Keep the Kubernetes HelmRelease recoverable until LXC target health, restore
   evidence, UI login, monitor list, and DNS/ingress checks pass.
2. If cutover fails, stop or isolate the LXC target service without deleting
   `/var/lib/uptime-kuma` evidence.
3. Ask the DNS/ingress owner to repoint `uptime.${DOMAIN_0}` back to Kubernetes
   internal ingress.
   Required rollback wording: repoint `uptime.${DOMAIN_0}` back to Kubernetes internal ingress.
4. Perform any Flux suspend/resume/delete only from clustertool; homelab must not
   mutate durable Kubernetes resources directly.
5. Verify the Kubernetes UI and monitor list before retrying the LXC cutover.

## Parallel-Build Cutover Sequence

1. Score and select the service using the weighted evidence rubric.
2. Create the homelab implementation plan for Terraform and NixOS without making
   durable Kubernetes changes.
3. Add the Terraform LXC envelope and validate it.
4. Add the NixOS target host/service and build it.
5. Provision/converge the LXC target through the existing Terraform-to-NixOS
   bridge when the implementation plan reaches apply time.
6. Restore or seed data onto target local storage.
7. Verify target health, logs, data presence, auth, and monitoring checks.
8. Ask the DNS/ingress owner to cut traffic to the target only after target
   verification passes.
9. Keep Kubernetes source manifests and Flux path recoverable until post-cutover
   verification passes.
10. Plan any durable Kubernetes cleanup as clustertool/Flux-owned work.

## Rollback Requirements

- Every service-specific plan must state how to point traffic back to Kubernetes.
- The Kubernetes source path must remain recoverable until LXC cutover
  verification passes.
- Any clustertool suspend, delete, disable, or cleanup step must be separate from
  homelab target implementation and owned by clustertool/Flux.
- Restored LXC data must not overwrite the only usable backup or source copy.
- Rollback verification must include service health, DNS/ingress route, and the
  source app's critical data or UI checks.

## Verification Commands

Run the commands that apply to the service-specific plan:

```bash
python3 scripts/validate-inventory.py inventory/services.json
./scripts/kubernetes-talos.sh verify
terraform -chdir=terraform validate
nix build ./nixos#nixosConfigurations.&lt;target-host&gt;.config.system.build.toplevel
```

For the generic pattern document, also check the required rubric and ownership
strings:

```bash
grep -F "## Weighted Evidence Rubric" docs/migration-pattern.md
grep -F "Phase 3 triage labels are evidence inputs only" docs/migration-pattern.md
grep -F "Durable Kubernetes disable, suspend, delete, or cleanup work belongs in clustertool" docs/migration-pattern.md
```
