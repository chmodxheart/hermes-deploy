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
- The repo cloned locally; branch is Phase-1 (`gsd/phase-01-audit-substrate`).

## 1. Create the three Proxmox LXCs

For `hostName ∈ {mcp-nats01, mcp-nats02, mcp-nats03}`:

```bash
# On any Proxmox node.
pct create <vmid> \
  local:vztmpl/nixos-25.11-proxmox-lxc.tar.xz \
  --hostname mcp-nats-N \
  --net0 name=eth0,bridge=vmbr0,hwaddr=<NEW_MAC>,ip=dhcp \
  --cores 2 --memory 2048 --rootfs local-lvm:32 \
  --unprivileged 1 --features nesting=1
```

Target VMIDs: 2011 / 2012 / 2013. Record the `hwaddr` — you'll pin
it on the Mikrotik in step 2.

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

## 4. Publish each host's age pubkey into `.sops.yaml`

Each LXC boots with an ed25519 host key. Convert it to an age pubkey:

```bash
ssh root@mcp-nats01.samesies.gay cat /etc/ssh/ssh_host_ed25519_key.pub \
  | ssh-to-age
```

Paste the resulting `age1...` into `.sops.yaml` under `keys:` and
add the host to the `creation_rules` for
`secrets/mcp-nats01.yaml` (and, for node 1 only, the operator file).

Commit the `.sops.yaml` change on a branch. Run
`sops updatekeys secrets/mcp-nats-*.yaml secrets/nats-operator.yaml`
to re-encrypt existing entries for the new recipient.

## 5. One-time `nsc` operator bootstrap (node 1 only)

```bash
# Create the operator, account, and service-role users. Uses the local
# nsc store (~/.nsc) — never checked in.
nsc add operator --generate-signing-key AuditOperator
nsc edit operator --service-url nats://mcp-nats01.samesies.gay:4222

nsc add account --name AuditAccount
nsc add user --account AuditAccount --name vector-publisher
nsc add user --account AuditAccount --name langfuse-ingest
nsc add user --account AuditAccount --name admin

# Export keys + creds + resolver config.
nsc generate creds --account AuditAccount --name vector-publisher \
  > vector-publisher.creds
nsc generate creds --account AuditAccount --name langfuse-ingest \
  > langfuse-ingest.creds
nsc generate creds --account AuditAccount --name admin \
  > nats-admin.creds
nsc generate config --mem-resolver --sys-account SYS \
  > resolver.conf
```

## 6. Populate `secrets/nats-operator.yaml`

Copy `secrets/nats-operator.yaml.example` to `secrets/nats-operator.yaml`
(if not already present) and fill the fields from step 5's outputs:

- `nats_operator_jwt` ← `~/.nsc/stores/AuditOperator/AuditOperator.jwt`
- `nats_system_account_public_key` ← `nsc describe account SYS`
  (`Account ID` line)
- `nats_resolver_preload` ← contents of `resolver.conf`
- `nats_vector_creds` ← `vector-publisher.creds`
- `nats_ingest_creds` ← `langfuse-ingest.creds`
- `nats_admin_creds` ← `nats-admin.creds`

Then:

```bash
sops -e -i secrets/nats-operator.yaml
sops -e -i secrets/mcp-nats-{1,2,3}.yaml
```

Commit the encrypted files.

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
