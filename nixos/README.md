# Evelyn's NixOS configurations

Flake-based NixOS configs for multiple deployment targets. The first host is
`hermes` — a privileged Proxmox LXC running `hermes-agent` with Supermemory as
its external memory provider.

## Layout

```
flake.nix              # inputs + nixosConfigurations.<host>
.sops.yaml             # age recipients per path
justfile               # fish-compatible recipes (check/build/switch/deploy)
modules/
  common.nix           # baseline every host gets (sshd, firewall, packages)
users/
  eve.nix              # login user + SSH key
profiles/
  lxc.nix              # Proxmox LXC tweaks (imports proxmox-lxc.nix, podman)
  cloud-vm.nix         # qemu-guest + disko scaffold for cloud providers
hosts/
  hermes/default.nix   # Proxmox LXC with hermes-agent + supermemory
secrets/
  hermes.yaml.example  # template — copy, fill, sops-encrypt
```

## Docs

- [`../docs/README.md`](../docs/README.md): shared Terraform/NixOS contract docs.
- [`docs/ops/README.md`](docs/ops/README.md): NixOS operator runbook index.
- [`docs/ops/deploy-pipeline.md`](docs/ops/deploy-pipeline.md): end-to-end deploy flow.
- [`docs/ops/new-lxc-checklist.md`](docs/ops/new-lxc-checklist.md): add another NixOS LXC host.

## Prerequisites on your workstation

- Nix with flakes enabled.
- `sops`, `age`, `ssh-to-age`, `just`, `fish` — all covered by the flake's
  `devShell`: `nix develop`.
- An age key at `~/.config/sops/age/keys.txt`. The current public recipient is
  already pinned in `.sops.yaml`:

  ```
  age1pzn74xh6lknymmrv3hv39cs6zm7nefarx5pf8cgd5flnjsss847s6unxz2
  ```

  If rotated, update `.sops.yaml` and re-run `sops updatekeys secrets/hermes.yaml`.

## First-time secrets bootstrap

```fish
cp secrets/hermes.yaml.example secrets/hermes.yaml
# Fill in real values (see "What goes in each key" below), then:
sops -e -i secrets/hermes.yaml
git add secrets/hermes.yaml
```

`secrets/hermes.yaml.example` is committed (plaintext, REPLACE_ME values).
`secrets/hermes.yaml` gets committed only after it is sops-encrypted.

### What goes in each key

| Key | Contains |
|-----|----------|
| `hermes_env` | dotenv: model provider URL/key, `SUPERMEMORY_API_KEY`, Exa key, Discord bot token/channel/users, API server key |
| `hermes_auth_json` | the JSON blob from `~/.hermes/auth.json` (hermes-agent OAuth tokens) |

## Bringing up the `hermes` LXC

The Proxmox host runs bash, not fish.

### 1. Create the container

```bash
ctid=701
ctname=hermes
ctt="hecate:vztmpl/nixos-image-lxc-proxmox-25.11pre-git-x86_64-linux.tar.xz"
cts=ceph-rbd

pct create $ctid $ctt \
    --hostname=$ctname \
    --ostype=nixos --unprivileged=0 --features nesting=1 \
    --net0 name=eth0,bridge=main,ip=dhcp \
    --arch=amd64 --swap=2048 --memory=4096 --cores=4 \
    --storage=$cts

pct resize $ctid rootfs +30G
```

Notes:
- The template is Hydra's `nixos.proxmoxLXC.x86_64-linux` job for release-25.11.
  **Do not use `lxdContainerImage` or any `nixos-generators` output** — the
  latter has a known Dec-2024 bug where `nixos-rebuild` silently doesn't apply
  changes.
- Sizing is generous rather than minimal: hermes-agent's ubuntu container
  plus its Nix python env and Node/npm tools under the writable layer are
  the main consumers. CPU/memory needs spike during tool use (browser,
  code execution sandboxes) — scale up if you plan to lean on those.

### 2. Inject the flake before first boot

```bash
pct mount "$ctid"
target="/var/lib/lxc/$ctid/rootfs"
rm -rf "$target/etc/nixos"
mkdir -p "$target/etc/nixos"

# Option A — rsync the monorepo NixOS subtree:
rsync -a /root/repo/hermes-deploy/nixos/ "$target/etc/nixos/"

# Option B — clone the monorepo and copy the subtree you need:
git clone https://github.com/escidmore/hermes-deploy /root/repo/hermes-deploy
rsync -a /root/repo/hermes-deploy/nixos/ "$target/etc/nixos/"

pct unmount "$ctid"
pct start "$ctid"
pct enter "$ctid"
```

### 3. First rebuild (no secrets yet)

The LXC has no SSH host key at this point, so sops can't decrypt anything
on-host. Comment out the `sops.secrets.*` blocks in `hosts/hermes/default.nix`
for the very first build, or just accept that `hermes-agent.service` (and any
other service depending on decrypted secrets) will fail to start — the system
itself will come up fine.

```bash
source /etc/set-environment
passwd root
nixos-rebuild switch --flake /etc/nixos#hermes
```

### 4. Teach sops about the host

Still on the Proxmox host, from inside the container or by `pct enter`:

```bash
cat /etc/ssh/ssh_host_ed25519_key.pub
```

Back on your workstation:

```fish
# Convert the host SSH key to an age recipient
echo "ssh-ed25519 AAAA..." | ssh-to-age
```

Add the resulting `age1...` recipient to `.sops.yaml` under `&hermes`, uncomment
the `- *hermes` line in the `creation_rules`, then re-encrypt:

```fish
sops updatekeys secrets/hermes.yaml
git add .sops.yaml secrets/hermes.yaml
git commit -m "sops: add hermes host recipient"
git push
```

### 5. Second rebuild (with secrets)

On the LXC:

```bash
cd /etc/nixos && git pull
nixos-rebuild switch --flake /etc/nixos#hermes
```

Re-enable the `sops.secrets` blocks in `hosts/hermes/default.nix` if you
commented them out in step 3, then rebuild once more. After this, secrets
decrypt to `/run/secrets/*` on boot and `services.hermes-agent` pulls
`ubuntu:24.04`, bootstraps the container's writable layer (apt + uv venv), and
starts. The `hermes-agent-container-extras` oneshot then pip-installs
`supermemory` and apt-installs `libopus0` into that layer — first run is slow
(a minute or two), subsequent runs are no-ops.

Verify:

```bash
systemctl status hermes-agent hermes-agent-container-extras
journalctl -u hermes-agent -e
podman exec -u hermes hermes-agent /home/hermes/.venv/bin/pip show supermemory
cat /var/lib/hermes/.hermes/supermemory.json
```

## Steady-state

- `system.autoUpgrade` runs daily at 04:00 from `github:escidmore/hermes-deploy?dir=nixos`. It
  pulls the flake, rebuilds, and switches — no reboot. To disable: set
  `system.autoUpgrade.enable = false` in the relevant host.
- `nix.gc` prunes generations older than 14 days weekly.
- Fail2ban is on for sshd.

## Day-to-day

From `nixos/`:

```fish
just check              # nix flake check
just build              # build hermes without activating
just switch             # nixos-rebuild switch on the current machine
just dry-run            # preview changes
just deploy hermes <ip> # ssh deploy (wheel/nopasswd required on target)
just edit-secrets       # sops edit secrets/hermes.yaml
just show-recipient     # print your own age public recipient
just fmt                # nixfmt across the tree
just update             # nix flake update
```

## Memory provider notes

Hermes uses Supermemory as its external memory backend. Two things about the
deployment worth knowing:

1. **Plugin pip deps aren't in the Nix env.** The `supermemory` PyPI package
   is declared in `plugins/memory/supermemory/plugin.yaml` but isn't bundled
   into the hermes-agent Nix Python environment. We run hermes-agent in
   **container mode** (`services.hermes-agent.container.enable = true`) and
   pip-install `supermemory` into the container's writable uv-managed venv at
   `/home/hermes/.venv`. `PYTHONPATH` is injected via `podman --env` so the
   Nix-provided Python sees the venv's site-packages. This same escape hatch
   works for any other plugin whose pip deps aren't packaged upstream.

2. **`supermemory.json` is templated separately from `config.yaml`.** The
   hermes-agent NixOS module only writes `config.yaml` (from
   `services.hermes-agent.settings`). Per-plugin configs live alongside it in
   `$HERMES_HOME` and have no module option, so we write
   `/var/lib/hermes/.hermes/supermemory.json` via `systemd.tmpfiles.settings`
   with `L+` to a `pkgs.writeText` blob — keeps it declarative without
   fighting the module.

## Adding a cloud VM host later

1. Make `hosts/<name>/default.nix` and `hosts/<name>/disk-config.nix` (the
   disko layout).
2. Add an entry to `flake.nix` under `nixosConfigurations` that imports
   `./profiles/cloud-vm.nix` and `./hosts/<name>`.
3. Bootstrap via `nixos-anywhere --flake .#<name> root@<ip>`.
