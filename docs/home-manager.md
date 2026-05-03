# Home Manager Source of Truth

Home Manager user state is owned by the external `~/repo/home-manager` flake. This
homelab repo references that source through `scripts/home-manager.sh` and docs; it
does not copy Home Manager modules, host files, encrypted secrets, or decrypted
user secret values into this repo.

## Current Source

- **Active source:** `~/repo/home-manager`
- **Current target:** `wsl-desktop`
- **Homelab integration:** referenced from homelab through `scripts/home-manager.sh`,
  not a copied subtree or Terraform/NixOS-owned configuration.

The Home Manager flake defines `homeConfigurations."wsl-desktop"` through a
shared `mkHome` helper and imports common user modules from `home.nix`.

## Homelab Wrapper Commands

Run these from the homelab repo root:

```bash
./scripts/home-manager.sh repo-path
./scripts/home-manager.sh verify wsl-desktop
./scripts/home-manager.sh build wsl-desktop
./scripts/home-manager.sh switch wsl-desktop
HOME_MANAGER_REPO=/path/to/home-manager ./scripts/home-manager.sh verify <target>
./scripts/home-manager.sh edit-secrets
```

`verify` is the safe default check. It confirms the external repo exists, the
target is exposed, `~/repo/home-manager/secrets/secrets.yaml` exists, and the
local `~/.config/sops/age/keys.txt` key file exists. It does not decrypt or print
secret values.

## wsl-desktop Workflow

1. Confirm which Home Manager source the homelab wrapper will use:

   ```bash
   ./scripts/home-manager.sh repo-path
   ```

2. Verify the active target and secret boundary before changing user state:

   ```bash
   ./scripts/home-manager.sh verify wsl-desktop
   ```

3. Build without activating when reviewing changes:

   ```bash
   ./scripts/home-manager.sh build wsl-desktop
   ```

4. Switch only when ready to apply the Home Manager user environment:

   ```bash
   ./scripts/home-manager.sh switch wsl-desktop
   ```

## Adding a Non-NixOS Machine

Add new non-NixOS machines in `~/repo/home-manager`, not in this repo:

1. Create `hosts/<hostname>.nix` for host-specific settings.
2. Add the target to `flake.nix`:

   ```nix
   homeConfigurations."<hostname>" = mkHome {
     system = "x86_64-linux";
     hostname = "<hostname>";
   };
   ```

3. Reuse the shared imports from `home.nix` instead of duplicating modules:
   - `modules/cli-tools.nix`
   - `modules/git.nix`
   - `modules/shell/bash.nix`
   - `modules/shell/fish.nix`
   - `modules/shell/nushell.nix`
   - `modules/shell/starship.nix`
   - `modules/editor/neovim.nix`
   - `modules/terminal/zellij.nix`

4. Verify the new target from homelab with an explicit source override if needed:

   ```bash
   HOME_MANAGER_REPO=/path/to/home-manager ./scripts/home-manager.sh verify <target>
   ```

## Secret Boundary

- `~/repo/home-manager/secrets/secrets.yaml` stays SOPS-encrypted and belongs to
  the Home Manager repo.
- `~/.config/sops/age/keys.txt` remains local private key material and must not be
  copied or committed here.
- Homelab docs and scripts may reference encrypted secret paths, but must not
  commit decrypted values or run verification that prints secret contents.
- Use `./scripts/home-manager.sh edit-secrets` when an operator intentionally
  needs to edit the encrypted Home Manager secrets file through `sops`.

## Ownership Rules

- Home Manager owns user-level workstation state.
- Terraform owns Proxmox envelopes only.
- NixOS owns guest convergence only.
- Flux owns Kubernetes workloads that remain in-cluster.
- This repo coordinates Home Manager operator workflow by reference until an
  explicit future phase changes the ownership model.
