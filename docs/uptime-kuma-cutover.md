# Uptime Kuma Cutover Runbook

This runbook is the operator sequence for moving Uptime Kuma from the
Flux-owned Kubernetes source to the NixOS LXC target. It records commands,
evidence fields, and ownership gates only. Do not paste decrypted VolSync,
Wasabi, SOPS, age, Flux, Talos, Terraform, DNS, or application credential values
into this file, tickets, commits, or planning artifacts.

## Scope And Ownership

| Area | Owner | Runbook boundary |
|---|---|---|
| Proxmox envelope | Terraform in `terraform/` | Terraform owns VMID `2130`, IP `10.2.100.30/24`, node, CPU, memory, disk, bridge, VLAN, MAC, tags, and root SSH key references. |
| Guest convergence | NixOS flake and `scripts/bootstrap-host.sh` | NixOS owns packages, service state, filesystem policy, users, secrets, and nftables. |
| Kubernetes source | clustertool/Flux | Homelab references `external/clustertool/clusters/main/kubernetes/apps/uptime-kuma/app/helm-release.yaml`; durable changes remain clustertool/Flux-owned. |
| DNS/ingress | External DNS/ingress owner | Homelab requests and records route changes for `uptime.${DOMAIN_0}` but does not own the authoritative control plane. |
| Restore secrets | Backup and secret owners | Record encrypted variable names, source names, target paths, timestamps, and pass/fail facts only. |

The target is host `uptime-kuma`, VMID `2130`, IP `10.2.100.30/24`, service
URL `http://10.2.100.30:3001/`, local data path `/var/lib/uptime-kuma`, and DNS
name `uptime.${DOMAIN_0}`. The Kubernetes source restore reference is the
VolSync/restic snapshot `uptime-kuma-config` in
`external/clustertool/clusters/main/kubernetes/apps/uptime-kuma/app/helm-release.yaml`.

## Preconditions

Before cutover work starts, confirm and record:

1. `terraform/locals.tf` still contains the `"uptime-kuma"` envelope with VMID
   `2130`, IP `10.2.100.30/24`, and `nixos_deploy_enabled = false`.
2. The Terraform envelope has been reviewed or applied by the Terraform owner.
3. The NixOS target still builds from `nixosConfigurations.uptime-kuma`.
4. The source path exists and remains clustertool/Flux-owned:
   `external/clustertool/clusters/main/kubernetes/apps/uptime-kuma/app/helm-release.yaml`.
5. The restore source name is `uptime-kuma-config`; no decrypted backup values are
   copied into homelab files.
6. The allowed HTTP source is `10.0.1.2`; the negative source is `10.0.1.9`.
7. The operator has a rollback window approved before durable Kubernetes cleanup
   is requested.

Recommended static checks before a live attempt:

```bash
terraform -chdir=terraform validate
nix build --no-link ./nixos#nixosConfigurations.uptime-kuma.config.system.build.toplevel
./scripts/kubernetes-talos.sh verify
```

If any prerequisite cannot be proven, cutover is blocked. Record the missing
evidence in the template below and do not request DNS/ingress changes.

## Provision And Converge Target

Terraform applies the Proxmox envelope. NixOS convergence is explicit because
Phase 6 chose `nixos_deploy_enabled = false` for `uptime-kuma`; do not silently
change that flag in this runbook sequence.

1. From the repo root, have the Terraform owner provision or update the Proxmox
   LXC envelope for host `uptime-kuma`.
2. After the target is reachable over SSH and the host age key is available,
   converge the NixOS guest explicitly:

   ```bash
   ./scripts/bootstrap-host.sh uptime-kuma
   ```

3. Record the convergence evidence: command, timestamp, actor/source, result,
   and any secret-free summary.
4. Do not treat successful convergence as cutover readiness until restore,
   target verification, UI login, monitor list, rollback, and DNS/ingress gates
   below all pass.

## Restore Or Seed Data

Restore or seed Uptime Kuma application data from Kubernetes source
`uptime-kuma-config` into the target local path `/var/lib/uptime-kuma` before any
DNS/ingress request.

Required restore evidence:

| Field | Required value |
|---|---|
| Source manifest | `external/clustertool/clusters/main/kubernetes/apps/uptime-kuma/app/helm-release.yaml` |
| Restore source | `uptime-kuma-config` |
| Target host/path | `uptime-kuma:/var/lib/uptime-kuma` |
| Actor/source | Operator identity and source workstation or automation host |
| Timestamp | UTC timestamp for restore or seed completion |
| Result | Pass/fail plus secret-free summary |
| App evidence | UI login and expected monitor list after restore |

Do not restore in a way that overwrites the only usable source copy or backup.
Do not record decrypted VolSync, Wasabi, SOPS, age, Flux, Talos, DNS, Terraform,
or app credential values. If restore cannot be performed by the executor or
operator in the current environment, cutover is blocked. The operator checkpoint
must include source, target, timestamp, result, UI login evidence, and monitor
list evidence before moving on.

## Target Verification Gate

All checks in this section must pass before requesting DNS/ingress changes.

From the allowed source `10.0.1.2`, verify HTTP health:

```bash
curl -fsS http://10.2.100.30:3001/
```

On the deployed `uptime-kuma` host, verify service state and logs:

```bash
systemctl status uptime-kuma
journalctl -u uptime-kuma
```

From the negative source `10.0.1.9`, the same HTTP request should fail because
Phase 7 host-owned nftables allows tcp/3001 only from `10.0.1.2`:

```bash
curl -fsS http://10.2.100.30:3001/
```

Manual UI gate:

1. Visit `http://10.2.100.30:3001/` from the allowed path.
2. Log in with operator-held Uptime Kuma credentials.
3. Confirm the expected monitor list is present after restore.
4. Record only pass/fail facts and non-secret monitor names or counts as allowed
   by the operator; do not paste credentials or sensitive monitor secrets.

The gate passes only when HTTP health, service status, logs, negative-source
blocking, UI login, monitor list, restore evidence, and rollback path evidence
are all complete.

## DNS/Ingress Cutover Request

External DNS/ingress owners remain authoritative for `uptime.${DOMAIN_0}`. Make
the request only after the target verification gate passes.

Request content:

- Repoint `uptime.${DOMAIN_0}` from Kubernetes internal ingress to the verified
  LXC or reverse-proxy path for `http://10.2.100.30:3001/`.
- Include the restore evidence timestamp, target HTTP check result, service/log
  result, UI login result, monitor-list result, and rollback instructions.
- Ask the External DNS/ingress owner to confirm when traffic reaches the target.

After confirmation, verify `uptime.${DOMAIN_0}` from the intended client path and
record the timestamp, actor/source, result, and secret-free summary.

## Rollback

Rollback remains available until the rollback window is satisfied and the source
is intentionally handed off for clustertool/Flux cleanup.

1. Stop or isolate the LXC target service without deleting `/var/lib/uptime-kuma`
   evidence.
2. Ask the DNS/ingress owner to repoint uptime.${DOMAIN_0} back to Kubernetes
   internal ingress.
3. Verify the Kubernetes route, UI login, and expected monitor list after traffic
   returns to Kubernetes.
4. Keep the LXC restore evidence and logs for diagnosis.
5. Do not delete source manifests, backup paths, or restored LXC data as part of
   emergency rollback.

Required rollback wording for requests: repoint uptime.${DOMAIN_0} back to
Kubernetes internal ingress.

## Rollback Window

Set the rollback window before durable Kubernetes cleanup is requested. The
window starts only after DNS/ingress confirmation for `uptime.${DOMAIN_0}` and
post-cutover UI/monitor-list verification pass.

Minimum evidence before closing the rollback window:

- Target route for `uptime.${DOMAIN_0}` remains healthy for the agreed duration.
- UI login and expected monitor list remain valid after cutover.
- Service logs show no restore, data-directory, or port-binding failures.
- Backup owner confirms the target-side backup or recovery expectation.
- Rollback steps remain documented and tested enough for the operator to execute.

If any item fails, keep the Kubernetes source recoverable and do not request
durable cleanup.

## Durable Kubernetes Cleanup Boundary

Durable Kubernetes suspend, delete, disable, or cleanup work is
clustertool/Flux-owned. Homelab may record the handoff and evidence, but it must
not add direct durable Kubernetes mutation commands or perform cleanup from this
repo.

Cleanup handoff requirements:

1. Restore evidence from `uptime-kuma-config` to `/var/lib/uptime-kuma` is
   complete.
2. Target verification, DNS/ingress confirmation, UI login, and monitor-list
   checks are complete.
3. Rollback window evidence is complete and accepted.
4. The requested cleanup path points back to clustertool/Flux-owned source files,
   especially
   `external/clustertool/clusters/main/kubernetes/apps/uptime-kuma/app/helm-release.yaml`.

Until those requirements pass, keep the Kubernetes HelmRelease and Flux path
recoverable.

## Evidence Log

Checkpoint outcome: `approved-cutover` at 2026-05-04T14:51:14Z.

The operator-approved checkpoint response confirms these secret-free live facts:

- Restore or seed from `uptime-kuma-config` to `/var/lib/uptime-kuma` was
  completed and verified without recording backup, SOPS, age, Flux, Talos,
  Terraform, DNS, or application credential values.
- Allowed-source access from `10.0.1.2` to `http://10.2.100.30:3001/` passed.
- Host service health and logs for `uptime-kuma` were validated with no reported
  restore, data-directory, or port-binding failures.
- Denied WSL-source access from `10.0.1.9` to tcp/3001 failed as intended.
- The Uptime Kuma UI login and expected monitor list were validated by the
  operator without recording credentials or sensitive monitor details.
- External DNS/ingress routing for `uptime.${DOMAIN_0}` was confirmed to reach
  the LXC target or intended reverse-proxy path.
- Rollback readiness was confirmed: the LXC service can be stopped or isolated
  without deleting `/var/lib/uptime-kuma`, and traffic can be repointed back to
  Kubernetes internal ingress if the rollback window fails.

Kubernetes source remains recoverable until the rollback window is satisfied;
durable suspend/delete cleanup remains clustertool/Flux-owned.

## Evidence Log Template

Copy one row per gate. Keep summaries secret-free.

| Gate | Command/path | Timestamp (UTC) | Actor/source | Result | Secret-free summary |
|---|---|---|---|---|---|
| Terraform envelope | `terraform -chdir=terraform validate` or apply evidence |  |  |  |  |
| NixOS convergence | `./scripts/bootstrap-host.sh uptime-kuma` |  |  |  |  |
| Source recoverability | `./scripts/kubernetes-talos.sh verify` |  |  |  |  |
| Restore/seed | `uptime-kuma-config` to `/var/lib/uptime-kuma` |  |  |  |  |
| HTTP allowed source | `curl -fsS http://10.2.100.30:3001/` from `10.0.1.2` |  |  |  |  |
| Service status | `systemctl status uptime-kuma` |  |  |  |  |
| Service logs | `journalctl -u uptime-kuma` |  |  |  |  |
| Negative source | `curl -fsS http://10.2.100.30:3001/` from `10.0.1.9` should fail |  |  |  |  |
| UI login | `http://10.2.100.30:3001/` |  |  |  |  |
| Monitor list | Uptime Kuma UI monitor list |  |  |  |  |
| DNS/ingress | `uptime.${DOMAIN_0}` External DNS/ingress confirmation |  |  |  |  |
| Rollback | repoint uptime.${DOMAIN_0} back to Kubernetes internal ingress |  |  |  |  |
| Rollback window | agreed window and target health evidence |  |  |  |  |
| Cleanup handoff | clustertool/Flux-owned cleanup request |  |  |  |  |
