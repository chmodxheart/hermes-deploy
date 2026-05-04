# NATS cluster bring-up runbook

> Source: `.planning/phases/01-audit-substrate/01-09-PLAN.md` Wave 5
> Covers: one-time bootstrap of the three-node NATS cluster
> (`mcp-nats-{1,2,3}`), including nsc operator/account setup, sops
> age-key substitution, Mikrotik MAC reservations, and AD DNS records.
> Applies to a **fresh check-out** — skip any step already completed.

## 0. Prerequisites

- Proxmox access (VE UI + `pct` CLI on a cluster node).
- Mikrotik router admin (CapsMan, DHCP → static MAC reservations).
- Samba AD DC admin (`samba-tool dns add` from a DC).
- `sops`, `age`, `ssh-to-age`, `nsc` on the operator workstation
  (`nix shell nixpkgs#{sops,age,ssh-to-age,nsc}`).
- The repo cloned locally.

## 1. Declare the three Proxmox LXCs in Terraform

Terraform owns Proxmox envelopes. For `mcp-nats01`, `mcp-nats02`, and
`mcp-nats03`, declare or update the container inventory in
`terraform/locals.tf`, then run Terraform from the Terraform subtree:

```fish
cd <homelab-repo>/terraform
terraform plan
terraform apply
```

For the supported end-to-end deploy flow, see
[`deploy-pipeline.md`](deploy-pipeline.md). Do not create these containers with
manual `pct create` commands unless you are doing an explicitly documented
recovery outside normal repo ownership.

## 2. Pin DHCP on the Mikrotik

```bash
/ip dhcp-server lease add \
  mac-address=<NEW_MAC> \
  address=10.0.2.11 \
  server=samesies-lan \
  comment="mcp-nats01 audit plane"
```

Repeat for `.12` / `.13`. Pin matters because:

- `networking.extraHosts` in `hosts/mcp-nats-*/default.nix` pairs
  these IPs with the audit-plane hostnames.
- The NATS cluster `routes` list resolves peers by hostname; a
  DHCP-reassignment would break cluster formation.

## 3. Create AD DNS records

On any samba AD DC:

```bash
for n in 1 2 3; do
  samba-tool dns add dc1 samesies.gay \
    mcp-nats-$n A 10.0.2.1$n -U administrator
done
```

Verify from an audit-plane host: `getent hosts mcp-nats01.samesies.gay`.

## 4. Publish each host age identity into `.sops.yaml`

Use the repo bootstrap helper from the repo root. It generates a dedicated host
age identity, stores the private key encrypted in
`nixos/secrets/host-sops-keys.yaml`, publishes the public recipient in
`nixos/.sops.yaml`, and re-keys the host secret file when present:

```fish
cd <homelab-repo>
./scripts/add-host.sh mcp-nats01
./scripts/add-host.sh mcp-nats02
./scripts/add-host.sh mcp-nats03
```

Manual `.sops.yaml` edits are reserved for documented recovery or recipient
rotation. The normal path must leave `scripts/bootstrap-host.sh` able to deliver
the encrypted per-host private key during deploy.

## 5. One-time `nsc` operator bootstrap (node 1 only)

```bash
# Create the operator, the shared AUDIT account, and the least-privilege users.
# Uses the local nsc store (~/.nsc) — never checked in.
nsc add operator --generate-signing-key AuditOperator
nsc edit operator --service-url nats://mcp-nats01.samesies.gay:4222

nsc add account --name AUDIT
nsc add user --account AUDIT --name vector-mcp-nats01 \
  --allow-pub 'audit.otlp.traces.mcp-nats01,audit.journal.mcp-nats01'
nsc add user --account AUDIT --name vector-mcp-nats02 \
  --allow-pub 'audit.otlp.traces.mcp-nats02,audit.journal.mcp-nats02'
nsc add user --account AUDIT --name vector-mcp-nats03 \
  --allow-pub 'audit.otlp.traces.mcp-nats03,audit.journal.mcp-nats03'
nsc add user --account AUDIT --name langfuse-ingest --allow-sub 'audit.otlp.>'
nsc add user --account AUDIT --name admin

# Export temporary creds for SOPS-encrypted repo secrets or local ignored stores.
nsc generate creds --account AUDIT --name vector-mcp-nats01 \
  > vector-mcp-nats01.creds
nsc generate creds --account AUDIT --name vector-mcp-nats02 \
  > vector-mcp-nats02.creds
nsc generate creds --account AUDIT --name vector-mcp-nats03 \
  > vector-mcp-nats03.creds
nsc generate creds --account AUDIT --name langfuse-ingest \
  > langfuse-ingest.creds
nsc generate creds --account AUDIT --name admin \
  > nats-admin.creds
```

The generated `.creds`, JWTs, PEMs, passwords, and environment values are
temporary local material. They may enter only SOPS-encrypted
`nixos/secrets/*.yaml` files or local ignored stores such as `~/.nsc`. Plaintext
generated credential files must not be committed. Follow the two-stage SOPS
pattern from [`new-lxc-checklist.md`](new-lxc-checklist.md): placeholders may be
tracked only as examples or encrypted files, then real values are populated and
encrypted before tracking.

## 6. Generate and encrypt the bootstrap secret files

From the repo root, run:

```bash
./scripts/init-secrets.sh --dry-run --force
./scripts/init-secrets.sh --force
```

This helper now does the bootstrap generation directly instead of copying the
examples by hand. It will:

- create or reuse the shared `AUDIT` account and the users from step 5
- generate/write encrypted `secrets/nats-operator.yaml`
- generate/write encrypted `secrets/mcp-audit.yaml`
- generate/write encrypted `secrets/mcp-nats01.yaml`
- generate/write encrypted `secrets/mcp-nats02.yaml`
- generate/write encrypted `secrets/mcp-nats03.yaml`
- leave only the explicitly deferred/manual values as placeholders

Use the dry run first to confirm which `nsc` users will be created or reused
and which encrypted files would be replaced, without modifying the local
`~/.nsc` store or the repo secrets.

Commit the SOPS-encrypted files once they look correct.

## 7. Uncomment the system-account public-key line

In each `hosts/mcp-nats-*/default.nix`, replace the commented stub:

```nix
# services.mcpNatsCluster.systemAccountPublicKey = "<set by Plan 09 nsc bootstrap>";
```

with the real value you just minted.

## 8. Deploy

```bash
nixos-rebuild switch --flake .#mcp-nats01 --target-host root@mcp-nats01.samesies.gay
nixos-rebuild switch --flake .#mcp-nats02 --target-host root@mcp-nats02.samesies.gay
nixos-rebuild switch --flake .#mcp-nats03 --target-host root@mcp-nats03.samesies.gay
```

## 8.5. Fill the real `step_ca_root_cert` after first bootstrap

`scripts/init-secrets.sh` intentionally leaves `step_ca_root_cert` as a
placeholder on the first pass because the real PEM does not exist until
`mcp-audit` has bootstrapped `step-ca`.

After the first successful `mcp-audit` bootstrap:

```bash
ssh root@mcp-audit.samesies.gay cat /etc/step-ca/certs/root_ca.crt
```

Paste that PEM into:

- `secrets/mcp-audit.yaml`
- `secrets/mcp-nats01.yaml`
- `secrets/mcp-nats02.yaml`
- `secrets/mcp-nats03.yaml`

Then re-encrypt/redeploy.

Verify clustering from any peer:

```bash
ssh root@mcp-nats01 nats --creds /run/secrets/nats-admin.creds server list
# Expect three rows, all "current: true".
```

## 9. Create the JetStream streams (once)

```bash
ssh root@mcp-nats01 \
  nats --creds /run/secrets/nats-admin.creds stream add AUDIT_OTLP \
    --subjects 'audit.otlp.>' --storage file --replicas 3 \
    --retention limits --max-age 91d --discard old

ssh root@mcp-nats01 \
  nats --creds /run/secrets/nats-admin.creds stream add AUDIT_JOURNAL \
    --subjects 'audit.journal.>' --storage file --replicas 3 \
    --retention limits --max-age 31d --discard old
```

## 10. Smoke test

```bash
tests/audit04-nats-mtls.sh                 # anon handshake rejected
tests/audit04-nats-anon.sh                 # anon pub rejected
STAGE=true tests/nats-node-loss.sh         # destructive; staging only
```

Cluster is ready when all three return `OK`.
