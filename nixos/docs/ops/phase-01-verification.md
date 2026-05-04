# Phase 1 live-host verification manual

> Companion to `VERIFICATION.md`. Sequences the 5 `human_verification`
> items on top of the existing runbooks
> ([`nats-bring-up.md`](nats-bring-up.md),
> [`new-lxc-checklist.md`](new-lxc-checklist.md),
> [`langfuse-minio-bucket.md`](langfuse-minio-bucket.md)).
>
> **Ownership boundary** (see
> [`../../../docs/ownership-boundary.md`](../../../docs/ownership-boundary.md)):
> Terraform in `terraform/` owns Proxmox-side LXC provisioning
> (node, VMID, MAC, IP, rootfs, CPU/memory, SSH bootstrap keys). The
> `nixos/` tree owns guest configuration (users, services, secrets, sops).
> The two subtrees talk through the `nixos_hosts` contract
> (`terraform/contracts/nixos-hosts.schema.json`, `schema_version 1.0.0`).
>
> Run order is top-to-bottom: each section assumes the previous one
> passed. All tests are in `tests/`; env vars for each are listed at the
> top of the script.
>
> Start from [`README.md`](README.md) if you need the wider NixOS ops doc map.

## 0. One-time prerequisites

These must be true before starting verification. Most trace back to the
bring-up runbooks (NixOS side) and the Terraform root module (Proxmox
side).

**0.1 Build the NixOS LXC template and register it in Proxmox storage.**
One-time — rerun only on NixOS channel bumps.

```fish
cd ~/repo/homelab/nixos
nixos-rebuild build-image \
  --image-variant proxmox-lxc \
  --flake .#mcp-audit   # any audit-plane host works as the template source
```

Upload the resulting `.tar.xz` to Proxmox storage with content type
`vztmpl`, then record the file ID (`local:vztmpl/<filename>`) — you'll
pass it to Terraform next. See `docs/template-workflow.md`.

**0.2 Provision the four LXCs via Terraform.** Edit
`terraform/locals.tf` — add one entry to `local.containers` per
audit-plane host. Replace the placeholder `lab-nixos-01` entry with
(or add alongside):

```hcl
"mcp-audit" = {
  node             = "pve-1"
  vmid             = 210
  ipv4             = "10.0.2.10/24"
  gateway          = "10.0.2.1"
  mac_address      = "BC:24:11:AD:00:10"
  nixos_role       = "mcp-audit"
  rootfs_datastore = "ceph-lxc"
  rootfs_size_gib  = 200
  cpu_cores        = 6
  memory_mib       = 12288
  tags             = ["audit-plane", "mcp"]
  ssh_authorized_key_files = [pathexpand("~/.ssh/id_ed25519.pub")]
}

"mcp-nats01" = {
  node             = "pve-1"
  vmid             = 211
  ipv4             = "10.0.2.11/24"
  gateway          = "10.0.2.1"
  mac_address      = "BC:24:11:AD:00:11"
  nixos_role       = "mcp-nats"
  rootfs_datastore = "ceph-lxc"
  rootfs_size_gib  = 30
  cpu_cores        = 2
  memory_mib       = 4096
  tags             = ["audit-plane", "nats"]
  ssh_authorized_key_files = [pathexpand("~/.ssh/id_ed25519.pub")]
}
# Repeat for mcp-nats02 (pve-2, VMID 212, .12, MAC …:12) and mcp-nats03
# (pve-3, VMID 213, .13, MAC …:13). Node pinning matters — one NATS LXC
# per Proxmox node so R3 survives a single-node loss.
```

Apply:

```fish
cd ~/repo/homelab/terraform
# terraform.tfvars must have the Proxmox endpoint, API token, and
# template_file_id from 0.1 — see terraform.tfvars.example.
terraform init
terraform plan -out=phase1.plan
terraform apply phase1.plan
```

**Expect:** four `proxmox_virtual_environment_container.lxc` resources
created, one per `local.containers` entry. `terraform output nixos_hosts`
renders a contract payload keyed by the four host names.

**0.3 DNS + DHCP pinned.** Terraform sets static IPs and MACs, but the
samba AD and Mikrotik still need matching records. `nats-bring-up.md §2–§3`:

```fish
# Mikrotik — one lease per container, using the MAC from locals.tf
/ip dhcp-server lease add mac-address=BC:24:11:AD:00:10 address=10.0.2.10 server=samesies-lan comment="mcp-audit"
# …repeat for .11/.12/.13

# Samba AD — on any DC
for n in audit nats-1 nats-2 nats-3
  samba-tool dns add dc1 samesies.gay mcp-$n A 10.0.2.1$n -U administrator
end
```

Sanity check: `getent hosts mcp-audit.samesies.gay` returns `10.0.2.10`.

**0.4 Bootstrap each host's sops age identity.** See
`deploy-pipeline.md` for the full flow. Run once per host:

```fish
cd ~/repo/homelab
./scripts/add-host.sh mcp-audit
./scripts/add-host.sh mcp-nats01
./scripts/add-host.sh mcp-nats02
./scripts/add-host.sh mcp-nats03
```

Each invocation generates a dedicated age keypair, publishes the pubkey
into `.sops.yaml`, and stashes the privkey (encrypted with your
workstation key) in `secrets/host-sops-keys.yaml`.

**0.5 Populate and encrypt the per-host secrets yamls.** Fill real
values into each plaintext placeholder, then encrypt:

```fish
# Edit with real values (postgres/clickhouse/redis passwords, JWTs, etc.)
$EDITOR secrets/mcp-audit.yaml
sops -e -i secrets/mcp-audit.yaml
# Repeat for mcp-nats-*, nats-operator.
```

Keys required (full list in each yaml):
- `secrets/nats-operator.yaml` — operator JWT + system_account pubkey + admin creds (`nats-bring-up.md §5`)
- `secrets/mcp-nats-*.yaml` — per-server TLS bootstrap + account JWTs
- `secrets/mcp-audit.yaml` — postgres/clickhouse/redis passwords, `langfuse_web_env`, `langfuse_worker_env`, `nats-ingest.creds`, step-ca intermediate password

Commit everything: `.sops.yaml`, `secrets/host-sops-keys.yaml`,
`secrets/*.yaml`.

**0.6 Deploy — one command.** Terraform's `null_resource.nixos_deploy`
handles LXC creation + sops key push + `nixos-rebuild switch` end-to-end
per host via `scripts/bootstrap-host.sh`.

```fish
cd ~/repo/homelab/terraform
terraform apply
```

If you want to iterate on just the NixOS side without touching
Terraform, run `./scripts/bootstrap-host.sh <hostname>` from the repo
root for the same standalone flow.

**0.7 Operator workstation tooling.**

```fish
nix shell nixpkgs#natscli nixpkgs#openssl nixpkgs#curl nixpkgs#jq
```

Copy a valid admin creds bundle to `~/.nats/admin.creds` (from sops or
generated via `nsc generate creds -a SYS -n admin`).

**0.8 SSH agent has your key.** All `tests/*.sh` use `ssh` with
BatchMode; agent must be unlocked before you start.

---

## 1. Verification 1 — NATS cluster forms + streams exist

**Proves:** NATS-01 (R3 cluster), NATS-02 (nsc+JWT), the declarative
side of D-02.

**1.1 Cluster peers are current.**

```fish
nats --creds ~/.nats/admin.creds \
  --server tls://mcp-nats01.samesies.gay:4222 \
  server list
```

**Expect:** 3 rows, `current: true` on all three, cluster name
`mcp-audit-cluster`.
**Fail signals:** fewer than 3 rows → cluster didn't form (check
`journalctl -u nats` on each node for cert or JWT errors); `current:
false` → peer is behind on jetstream replication (wait 30s, retry).

**1.2 Create the two streams.** One-time after first cluster boot.

```fish
nats --creds ~/.nats/admin.creds \
  --server tls://mcp-nats01.samesies.gay:4222 \
  stream add AUDIT_OTLP \
    --subjects 'audit.otlp.>' \
    --storage file --replicas 3 \
    --max-age 91d --retention limits \
    --defaults

nats --creds ~/.nats/admin.creds \
  --server tls://mcp-nats01.samesies.gay:4222 \
  stream add AUDIT_JOURNAL \
    --subjects 'audit.journal.>' \
    --storage file --replicas 3 \
    --max-age 31d --retention limits \
    --defaults
```

**1.3 Confirm stream health.**

```fish
nats --creds ~/.nats/admin.creds \
  --server tls://mcp-nats01.samesies.gay:4222 \
  stream info AUDIT_OTLP --json | jq '.config.num_replicas, .cluster.leader'
```

**Expect:** `3` and a non-empty leader name. Repeat for `AUDIT_JOURNAL`.

---

## 2. Verification 2 — Anonymous publish rejected + mTLS enforced

**Proves:** AUDIT-04, NATS-04, D-03.

**2.1 Run the anon-reject test.**

```fish
nix shell nixpkgs#natscli -c env \
  NATS_HOST=mcp-nats01.samesies.gay \
  bash tests/audit04-nats-anon.sh
```

**Expect:** `OK: mcp-nats01.samesies.gay:4222 rejected anonymous publish`.
**Fail signal:** anything containing `Published` or a successful ack →
the server accepted an anonymous connection; re-check
`/run/secrets/nats-operator-jwt` on each nats host and
`services.nats.settings.resolver.type == "full"`.

**2.2 Run the mTLS-required test.**

```fish
env NATS_HOST=mcp-nats01.samesies.gay bash tests/audit04-nats-mtls.sh
```

**Expect:** `OK: mcp-nats01.samesies.gay:4222 rejected unauthenticated
TLS (mTLS enforced)`.
**Fail signal:** `Verify return code: 0 (ok)` → server did not demand a
client certificate; check `services.nats.settings.tls.verify == true`
and that `nats-server-cert.service` completed on the host.

**2.3 Positive control.** Prove the *valid* path works:

```fish
nats --creds ~/.nats/admin.creds \
  --server tls://mcp-nats01.samesies.gay:4222 \
  pub audit.otlp.test.verification 'hi from verification'
```

**Expect:** `Published 20 bytes to "audit.otlp.test.verification"`.

**2.4 Hermes one-way spot-check** (belt-and-suspenders — the
declarative side is already proven by `assert-no-hermes-reach`):

```fish
env HERMES_HOST=hermes.samesies.gay \
    TARGET_HOST=mcp-nats01.samesies.gay \
    TARGET_PORT=4222 \
  bash tests/audit03-hermes-probe.sh

env STAGE_HOST=mcp-audit.samesies.gay HERMES_IP=10.0.1.91 \
  bash tests/audit03-nft-assert.sh
```

**Expect:** both print `OK`; second prints the current nftables chain
summary.

---

## 3. Verification 3 — OTLP round-trip under 2s (end-to-end data path)

**Proves:** AUDIT-05, the pipeline Vector → NATS → `langfuse-nats-ingest`
→ Langfuse (SC-3 in the ROADMAP diff).

**3.1 Langfuse containers healthy.**

```fish
ssh root@mcp-audit.samesies.gay 'podman ps --format "{{.Names}} {{.Status}}"'
```

**Expect:** `langfuse-web Up …` and `langfuse-worker Up …`, both with
`(healthy)`.

**3.2 Web UI reachable via tunnel.**

```fish
env STAGE_HOST=mcp-audit.samesies.gay bash tests/audit01-langfuse-up.sh
```

**Expect:** `OK: langfuse /api/public/health -> 200`.

**3.3 Datastores up.**

```fish
env STAGE_HOST=mcp-audit.samesies.gay bash tests/audit01-datastores.sh
```

**Expect:** three `OK:` lines (postgresql, clickhouse, redis-langfuse).

**3.4 Mint a Langfuse API key.** Open the tunnelled web UI
(`http://127.0.0.1:13000`), log in, create a test project, generate a
public/secret key pair. Store them as env vars for the next step.

**3.5 Run the OTLP round-trip test.**

```fish
env STAGE_HOST=mcp-audit.samesies.gay \
    LF_PK=pk-lf-… \
    LF_SK=sk-lf-… \
  bash tests/audit05-otlp-e2e.sh
```

**Expect:** `OK: gen_ai.tool.call span present in langfuse within Ns`
(N ≤ 10).
**Fail signals:**
- `403` from the OTLP endpoint → LF_PK/LF_SK don't match project
- Span never appears → check `journalctl -u langfuse-nats-ingest
  --since '5 min ago' -f` for ack or HTTP 5xx lines
- Takes > 10s → check `nats stream info AUDIT_OTLP` for backlog
  (`num_pending`)

---

## 4. Verification 4 — ClickHouse TTLs applied + disk-check WARN path

**Proves:** AUDIT-02, D-09, D-10.

**4.1 Gate-check that Langfuse migrations completed.**

```fish
ssh root@mcp-audit.samesies.gay \
  "clickhouse-client --user langfuse --database langfuse \
     --query 'SELECT count() FROM system.tables WHERE database = \\'langfuse\\''"
```

**Expect:** a number ≥ 4 (traces, observations, scores, event_log, plus
internal tables).

**4.2 TTLs present on all four tables.**

```fish
env STAGE_HOST=mcp-audit.samesies.gay bash tests/audit02-ttl.sh
```

**Expect:** `OK: traces / observations / scores / event_log carry the
D-09 intervals`.
**Fail signal:** any table prints `FAIL: <table> TTL missing …` → the
`clickhouse-langfuse-ttl.service` oneshot hasn't run. Check
`systemctl status clickhouse-langfuse-ttl` on the host; it should have
`Active: inactive (dead, SUCCESS)` after the first boot post-migration.
If it failed, trigger manually:

```fish
ssh root@mcp-audit.samesies.gay systemctl start clickhouse-langfuse-ttl
```

Then re-run the test.

**4.3 Disk-check timer is active.**

```fish
ssh root@mcp-audit.samesies.gay \
  'systemctl list-timers mcp-audit-disk-check.timer --no-pager'
```

**Expect:** one row, `ACTIVATES: mcp-audit-disk-check.service`, `LEFT:
<15m or less>`.

**4.4 Observation-path sanity.**

```fish
env STAGE_HOST=mcp-audit.samesies.gay bash tests/audit02-disk-alert.sh
```

**Expect either:**
- `no WARN in last 30m — disk is below 70% threshold` (healthy), or
- `OBSERVED: N WARN line(s) …` (the observation path is firing; not a
  test failure — it means a real disk is filling up).

**4.5 Synthetic fill — only if you want to force a WARN.** Destructive
enough that it's not in the test script. On a staging host only:

```fish
ssh root@mcp-audit.samesies.gay \
  'fallocate -l 80G /var/lib/clickhouse/zzz-fill.bin \
   && systemctl start mcp-audit-disk-check.service \
   && journalctl -t mcp-audit-disk-check --since "2 min ago" \
   && rm /var/lib/clickhouse/zzz-fill.bin'
```

**Expect:** a `WARN /var/lib/clickhouse 80% > 70%` line in journalctl
output. Remove the fill file immediately after.

**4.6 Prom-alert mirror** (if Prometheus is configured). Skip this if
you don't have a Prom token yet — the primary signal is the nixos-side
journal WARN.

```fish
env PROM_API_URL=https://prometheus.samesies.gay/api/v1 \
    PROM_TOKEN=<bearer> \
  bash tests/audit02-prom-alert.sh
```

**Expect:** `OK: MCPAuditDiskHigh rule is registered …`.

---

## 5. Verification 5 — PBS restore excludes decrypted secrets

**Proves:** FOUND-06, D-12. Destructive — runs against PBS, requires a
spare staging VMID.

**5.1 Prerequisites.**
- Logged into a Proxmox node (`pct` / `pvesm` on PATH).
- PBS datastore reachable (`pvesm status | grep pbs`).
- At least one snapshot of the prod `mcp-audit` VMID (from §0.2 that's
  `210` in the example `locals.tf`).
- A free staging VMID **outside the Terraform-managed range** — pick
  something like `99999` that is not listed in
  `terraform/locals.tf`. A `terraform plan` run after the
  restore-test must remain clean; Terraform state is keyed on VMID, so
  reusing a managed VMID for a staging restore would cause drift on the
  next apply.

**5.2 Run the restore test.**

```fish
env STAGE=true \
    SRC_VMID=210 \
    STAGE_VMID=99999 \
    SNAPSHOT=latest \
    PBS_STORE=pbs \
  bash tests/restore-check.sh
```

**Expect:**
```
-- restoring 210 @ latest -> 99999
-- mounting staged rootfs
-- scanning excluded paths (must all be empty)
OK: /run is empty
OK: /var/run is empty
OK: /run/secrets is empty
…
-- scanning for plaintext secret markers (none must appear)
OK: no BEGIN OPENSSH PRIVATE KEY markers
OK: no BEGIN PRIVATE KEY markers
OK: no LANGFUSE_SECRET_KEY= markers
-- cleanup
```

**Fail signals:**
- `FAIL: /run/secrets contains N entries` → the PBS exclude list isn't
  being rendered; check `/etc/vzdump.conf.d/pxar-exclude` on the source
  host and `systemctl cat pbs-backup` for the `ExecStartPre`.
- Any plaintext-marker FAIL → the exclude list is narrower than it
  should be; fix `modules/pbs-excludes.nix` defaults and re-backup.

**5.3 Boot-time sops re-decrypt check** (manual, after the restore).

```fish
pct start 99999
pct exec 99999 -- ls /run/secrets/
```

**Expect:** the directory either doesn't exist yet or is populated from
a fresh sops decrypt (host key was available). If empty AND
`sops-install-secrets.service` failed, confirm the age key for
`mcp-audit` is committed under `.sops.yaml` → the LXC cannot decrypt
without it, which is the intended fail-safe.

**5.4 Cleanup.**

```fish
pct stop 99999
pct destroy 99999
```

---

## 6. Final sign-off checklist

When all five sections return `OK`:

- [ ] §1 — 3-peer cluster healthy + both streams replicas=3
- [ ] §2 — anon publish rejected, mTLS handshake fails without client cert, hermes probes fail to connect
- [ ] §3 — OTLP span round-trips within 10s
- [ ] §4 — 4 TTLs present, disk-check timer active, observation path wired
- [ ] §5 — PBS restore excludes decrypted secrets; host requires sops to boot

At this point: update `VERIFICATION.md` frontmatter
`status: human_needed → status: verified`, re-encode the 5
`human_verification:` blocks with `status: verified` and a timestamp,
and run `/gsd-transition` to apply
`docs/ops/phase-close-diffs/*.diff.md` against the root planning docs.
