# Deploy pipeline: `terraform apply` is the only command

This repo's NixOS hosts are bootstrapped and redeployed end-to-end by
`terraform apply` in `terraform/`. One command,
every time — no interleaved manual steps.

For the monorepo split and adjacent runbooks, see
[`../../../docs/ownership-boundary.md`](../../../docs/ownership-boundary.md)
and [`README.md`](README.md).

The flow:

```
┌───────────────────┐     ┌──────────────────────┐     ┌────────────────────┐
│ terraform apply   │ ──▶ │ proxmox_virtual_     │ ──▶ │ null_resource.     │
│ (in terraform/)   │     │ environment_         │     │ nixos_deploy calls │
│                   │     │ container (LXC up)   │     │ bootstrap-host.sh  │
└───────────────────┘     └──────────────────────┘     └─────────┬──────────┘
                                                                 │
                             ┌───────────────────────────────────┘
                             ▼
                  ┌─────────────────────────┐
                  │ bootstrap-host.sh:      │
                  │ 1. wait for ssh         │
                  │ 2. if no age key on     │
                  │    host, push one from  │
                  │    secrets/host-sops-   │
                  │    keys.yaml            │
                  │ 3. nixos-rebuild switch │
                  │    --target-host        │
                  └─────────────────────────┘
```

`bootstrap-host.sh` is idempotent — on an already-configured host it
skips the key push and just applies the flake.

## Adding a new host (one-time, ~2 min)

Done once per new LXC, before the first `terraform apply`.

**1.** Add the host to `terraform/locals.tf`:

```hcl
"mcp-whatever" = {
  node             = "pve-1"
  vmid             = 220
  ipv4             = "10.0.2.20/24"
  gateway          = "10.0.2.1"
  mac_address      = "BC:24:11:AD:00:20"
  nixos_role       = "mcp-whatever"
  rootfs_datastore = "ceph-lxc"
  ssh_authorized_key_files = [pathexpand("~/.ssh/id_ed25519.pub")]
}
```

**2.** Add the host to the NixOS flake — create `hosts/mcp-whatever/default.nix`
plus any host-specific imports, and register it under
`nixosConfigurations` in `flake.nix` via `mkHost`.

**3.** Bootstrap the sops age identity:

```fish
cd ~/repo/hermes-deploy
./scripts/add-host.sh mcp-whatever
```

This generates an age keypair, publishes the pubkey into `.sops.yaml`,
stashes the privkey in `secrets/host-sops-keys.yaml` (encrypted with
your workstation key), and re-keys the host's own `secrets/*.yaml` if
it exists.

**4.** If `secrets/mcp-whatever.yaml` is still a plaintext placeholder,
populate real values and encrypt:

```fish
sops -e -i secrets/mcp-whatever.yaml
```

**5.** Commit:

```fish
git add .sops.yaml secrets/host-sops-keys.yaml secrets/mcp-whatever.yaml flake.nix hosts/mcp-whatever
git commit -m "feat: bootstrap mcp-whatever"
```

## Deploying

Every deploy — first-time or repeat, one host or many:

```fish
cd ~/repo/hermes-deploy/terraform
terraform apply
```

Terraform creates any missing LXCs, then `null_resource.nixos_deploy`
triggers `bootstrap-host.sh` for each. `timestamp()` in the triggers
block forces a rebuild even when no Terraform-visible state has
changed, so flake-side edits pick up without needing to `taint` the
resource.

### Re-deploy a single host

```fish
cd ~/repo/hermes-deploy/terraform
terraform apply -replace='null_resource.nixos_deploy["mcp-audit"]'
```

### Skip the NixOS deploy (bare provisioning only)

```fish
cd ~/repo/hermes-deploy/terraform
terraform apply -var='nixos_deploy_enabled=false'
```

### Redeploy from the NixOS side directly

If you're iterating on the flake and don't want to touch Terraform at
all, the bootstrap script works standalone:

```fish
cd ~/repo/hermes-deploy
./scripts/bootstrap-host.sh mcp-audit
```

## Failure modes and recovery

| symptom | cause | fix |
|---------|-------|-----|
| `error: no age key for <host>` | `add-host.sh` wasn't run for that host | run `./scripts/add-host.sh <host>` from the repo root |
| `ssh: connect to host X: Connection refused` | LXC still booting (usually ~20s) | bootstrap-host.sh has a 60s wait loop; if it still fails, `pct status <vmid>` on the Proxmox node |
| `sops-install-secrets: no age key found` | key didn't land in `/var/lib/sops-nix/key.txt` | `ssh root@<host> ls -la /var/lib/sops-nix/` — if empty, rerun with `rm /var/lib/sops-nix/key.txt` on the host and redeploy |
| `sops: error decrypting` | host's age pubkey isn't in `.sops.yaml` creation_rules | `sops updatekeys secrets/<host>.yaml` then redeploy |
| `nixos-rebuild: build failed` | flake eval or build error | fix in the NixOS repo, `terraform apply` again — bootstrap-host.sh only re-pushes the key if it's missing, so this loop is cheap |

## Ownership boundary note

`docs/ownership-boundary.md` originally stated that
Terraform does NOT push guest state. This pipeline relaxes that line
by calling `bootstrap-host.sh` from a `local-exec` provisioner. The
boundary is still respected in spirit — Terraform doesn't ship any
guest config itself, it just invokes a NixOS-repo script that does.
The alternative (two separate commands every deploy) produced enough
operator friction to justify the crossover.

## Key security posture

- Host age **privkeys** live in `secrets/host-sops-keys.yaml`, encrypted
  with the workstation age key ONLY. A host cannot decrypt another
  host's identity.
- Host age **pubkeys** are published in `.sops.yaml` as recipients for
  the per-host `secrets/<hostname>.yaml` file ONLY, not for each
  other's secrets.
- The workstation age key lives at `$SOPS_AGE_KEY_FILE` (default
  `~/.config/sops/age/keys.txt`) and is the only identity that can
  decrypt `secrets/host-sops-keys.yaml`. Losing it means regenerating
  every host identity.
- `bootstrap-host.sh` pipes privkeys over SSH directly to
  `install -m 600 /dev/stdin /var/lib/sops-nix/key.txt` — never writes
  plaintext to a disk file on the operator workstation.
