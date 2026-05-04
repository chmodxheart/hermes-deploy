# NixOS Guest Convergence

The `nixos/` subtree owns NixOS guest convergence for homelab hosts. Terraform
creates or updates the Proxmox-side LXC envelope; this flake owns what happens
inside each guest: users, services, packages, firewall rules, SOPS integration,
and host-specific role composition.

Hermes remains a first-class host, and the MCP audit-plane hosts remain
first-class NixOS targets. This file is the subtree entrypoint; full procedures
live in the ops runbooks.

## Layout

```
flake.nix              # inputs + nixosConfigurations.<host>
.sops.yaml             # age recipients per path
justfile               # fish-compatible recipes (check/build/switch/deploy)
modules/               # reusable NixOS service and policy modules
users/                 # login users and SSH keys
profiles/              # target environment profiles such as LXC or cloud VM
hosts/                 # host-specific composition and identity values
pkgs/                  # project-local packages consumed by modules
secrets/               # SOPS-encrypted YAML plus plaintext .example templates
docs/ops/              # NixOS guest-side runbooks
```

## Docs

- [`../docs/README.md`](../docs/README.md): shared whole-homelab docs index.
- [`../docs/ownership-boundary.md`](../docs/ownership-boundary.md): platform ownership and hard guardrails.
- [`docs/ops/README.md`](docs/ops/README.md): NixOS operator runbook index.
- [`docs/ops/deploy-pipeline.md`](docs/ops/deploy-pipeline.md): end-to-end Terraform-to-NixOS deploy flow.
- [`docs/ops/new-lxc-checklist.md`](docs/ops/new-lxc-checklist.md): add another NixOS LXC host.
- [`docs/ops/nats-bring-up.md`](docs/ops/nats-bring-up.md): one-time NATS cluster bootstrap.

## Prerequisites on your workstation

- Nix with flakes enabled.
- `sops`, `age`, `ssh-to-age`, `just`, and `fish`; the flake dev shell provides these.
- An age key at `$SOPS_AGE_KEY_FILE`, defaulting to `~/.config/sops/age/keys.txt`.

## Secret handling

- Commit plaintext only for `.example` templates with replacement markers.
- Commit real `secrets/*.yaml` files only after they are SOPS-encrypted.
- Do not commit decrypted SOPS material, generated credentials, private keys,
  Terraform variables, Flux deploy keys, Talos secrets, or private credentials
  as tracked plaintext.
- Use [`docs/ops/new-lxc-checklist.md`](docs/ops/new-lxc-checklist.md) for the
  two-stage host recipient and SOPS bootstrap pattern.

## Day-to-day

From `nixos/`:

```fish
just check                 # nix flake check --no-build
just build <host>          # build one host toplevel without activating
just dry-run <host>        # preview activation on the current machine
just switch <host>         # switch the current machine to a flake host
just deploy <host> <target> # deploy to a target over SSH
just edit-secrets          # edit SOPS-encrypted secrets
just show-recipient        # print your workstation age public recipient
just fmt                   # nixfmt across the tree
just update                # nix flake update
```

For end-to-end LXC bring-up, run `terraform apply` from `terraform/`; it invokes
the NixOS-owned `scripts/bootstrap-host.sh` bridge documented in
[`docs/ops/deploy-pipeline.md`](docs/ops/deploy-pipeline.md).

## Hermes and MCP audit-plane workflows

- Hermes host configuration lives at `hosts/hermes/default.nix`.
- MCP audit-plane host configuration lives under `hosts/mcp-*` and the shared
  `modules/mcp-*.nix` modules.
- Routine Terraform-driven deploys are documented in
  [`docs/ops/deploy-pipeline.md`](docs/ops/deploy-pipeline.md).
- NATS bootstrap and audit-plane verification runbooks remain linked from
  [`docs/ops/README.md`](docs/ops/README.md).

## Adding a cloud VM host later

1. Make `hosts/<name>/default.nix` and `hosts/<name>/disk-config.nix`.
2. Add an entry to `flake.nix` under `nixosConfigurations` that imports
   `./profiles/cloud-vm.nix` and `./hosts/<name>`.
3. Bootstrap via the chosen cloud/NixOS workflow for that host.
