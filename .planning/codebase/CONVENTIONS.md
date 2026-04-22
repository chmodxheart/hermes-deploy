# Coding Conventions

**Analysis Date:** 2026-04-22

## Repository Layout

**Monorepo with two sibling subtrees + shared glue:**

- `terraform/` — Proxmox LXC provisioning (run `terraform` from here).
- `nixos/` — NixOS guest configuration as a flake (run `nix`/`just` from here).
- `scripts/` — operator scripts that cross the Terraform↔NixOS boundary
  (run from repo root as `./scripts/<name>.sh`).
- `docs/` — cross-cutting contracts (ownership boundary, handoff, template workflow).
- `.planning/` — untracked GSD planning artifacts (excluded via global
  gitignore + repo `.gitignore`).

**Ownership boundary is enforced, not advisory.** `docs/ownership-boundary.md`
is the canonical contract; Terraform bootstraps root + SSH keys, then hands
off to NixOS for user creation and hardening. See
`terraform/modules/lxc-container/main.tf` header comment.

## Nix Style

**Formatter:** `nixfmt-rfc-style` is pinned as `formatter.${system}` in
`nixos/flake.nix`. Run with `just fmt` (invokes `nix fmt`).

**Language server:** `nil` (available via `nix develop`).

**File patterns observed across `nixos/`:**

- **Attribute-set module signature** — every module file starts with a
  destructured signature selecting only what it uses:

  ```nix
  {
    config,
    lib,
    pkgs,
    ...
  }:
  ```

  `inputs` is added when the module consumes flake inputs
  (e.g. `nixos/modules/common.nix`). Modules that don't use one of
  `config`/`lib`/`pkgs` omit it — don't destructure unused names.

- **Leading comment block** — non-trivial modules open with a
  `# Source:` header citing the `.planning/phases/.../...` decisions and
  patterns the module implements, plus an "Invariants" and a
  "Deliberately NOT in this module" section. See
  `nixos/modules/nats-cluster.nix` for the canonical example.

- **Options first, config second.** Reusable modules expose a typed
  `options.services.mcp<Thing>` block with `lib.mkOption`, then a
  `config = lib.mkIf cfg.enable { ... }` body. `cfg = config.services.<name>`
  is the standard alias.

- **Enforce invariants at eval time.** Use `assertions = [ { assertion = …;
  message = "…"; } ];` inside `config` for per-host preconditions (e.g.
  `nixos/modules/nats-cluster.nix` rejects an account literally named
  `anonymous`). Use `throw` from inside a `checks.${system}` derivation for
  cross-host flake-level invariants (see `nixos/flake.nix` `step-ca-cert-duration-24h`,
  `mcp-audit-pbs-excludes`).

- **Nullable options for staged rollouts.** When a value isn't available
  yet (e.g. `systemAccountPublicKey` before nsc bootstrap), type it as
  `lib.types.nullOr lib.types.str`, default `null`, and gate usage with
  `lib.optionalAttrs (cfg.foo != null) { ... }` so `nix flake check`
  still evaluates cleanly.

- **Inline shell via `pkgs.writeShellScript`.** Wrapper scripts called
  from `ExecStart`/`ExecStartPre` are written inline with `set -euo pipefail`,
  absolute `${pkgs.curl}/bin/curl`-style paths, and a bounded retry loop
  when probing a dependency (see `waitForStepCa` in `nats-cluster.nix`).

- **`lib.mkDefault` / `lib.mkForce` are deliberate.** Use `mkDefault` for
  profile values callers may override (e.g. `networking.useNetworkd` in
  `common.nix`); use `mkForce` only when overriding an upstream module's
  default (e.g. `jetstream.store_dir` override in `nats-cluster.nix`)
  and leave an inline comment explaining why.

**Module naming:**

- Files are `kebab-case.nix` (`mcp-otel.nix`, `nats-cluster.nix`, `pbs-excludes.nix`).
- Option namespaces use `services.mcp<ProperCase>` (camelCase after the
  `mcp` prefix) — `services.mcpNatsCluster`, `services.mcpAuditPbs`.
- Hosts live at `nixos/hosts/<hostname>/default.nix`.
- Profiles live at `nixos/profiles/<role>.nix` (`lxc.nix`, `cloud-vm.nix`).

**Flake conventions:**

- Every input uses `inputs.<name>.inputs.nixpkgs.follows = "nixpkgs"` to
  keep a single nixpkgs across the closure (`nixos/flake.nix` lines 7-17).
- Hosts are assembled through an `mkHost { hostName, modules }` helper
  that injects `common.nix`, `users/eve.nix`, and `sops-nix.nixosModules.sops`
  automatically — host-level `modules` only declare what's host-specific.
- `specialArgs = { inherit inputs hostName; }` — never `inherit pkgs`;
  modules pin their own `pkgs` via the standard function signature.
- `system = "x86_64-linux"`; multi-system support is not in scope.

## Terraform / HCL Style

**Formatter/linter:** `terraform fmt` + `tflint` with the recommended
ruleset (`terraform/.tflint.hcl`). Both are mandatory pre-plan.

**Version pinning (`terraform/versions.tf`):**

- `required_version = "~> 1.14.0"` — pessimistic pin to the current
  stable line.
- Providers pinned with `~>` in both root and every module
  (`terraform/modules/lxc-container/main.tf` repeats the `required_providers`
  block — modules are self-describing, not reliant on root inheritance).

**File layout per Terraform module:**

- `main.tf` — resources and composition only.
- `locals.tf` — data-only local values (e.g. the `containers` inventory
  attrset).
- `providers.tf` — `provider "…" {}` blocks; no resources.
- `versions.tf` — `terraform { required_version; required_providers }`.
- `outputs.tf` — module outputs.
- `variables.tf` / `provider-variables.tf` / `template-variables.tf` —
  variable declarations, split by concern.
- `terraform.tfvars.example` committed; actual `*.tfvars` gitignored
  (see root `.gitignore`).
- `contracts/*.schema.json` and `examples/*.example.json` hold JSON
  schemas + fixtures the module validates against.

**HCL patterns observed:**

- **`for_each` over static resources.** The root module drives every
  container from `local.containers`:

  ```hcl
  module "lxc_container" {
    for_each = local.containers
    source   = "./modules/lxc-container"
    name     = each.key
    node     = each.value.node
    ...
  }
  ```

- **`try(each.value.<key>, <default>)` for optional attrs.** Keeps the
  inventory schema forgiving without introducing a separate variable
  per field (`terraform/main.tf` lines 13-32).

- **`locals` for derivations inside modules.** See
  `terraform/modules/lxc-container/main.tf` — `resolved_hostname`,
  `all_ssh_keys`, `resolved_tags` are computed once, then referenced.

- **`lifecycle.precondition` for invariants.** The LXC module refuses to
  plan if no SSH key is supplied — fails fast at plan time, not runtime.

- **Security posture hardcoded, not configurable.** The LXC module pins
  `unprivileged = true`, `features { nesting = true }`, and
  `started = true`. A header comment flags the SAFE-01 posture. Do not
  add variables to loosen these — open a new module instead.

- **`null_resource` + `local-exec` bridges to NixOS.** `main.tf`'s
  `null_resource.nixos_deploy` calls `scripts/bootstrap-host.sh` with
  `triggers.rebuild_at = timestamp()` so every apply redeploys. To force
  a single-host redeploy: `terraform apply -replace='null_resource.nixos_deploy["<host>"]'`.

**Naming:**

- Resources: snake_case (`proxmox_virtual_environment_container.this`).
- Variables: snake_case with descriptive prefixes
  (`virtual_environment_endpoint`, `rootfs_datastore`, `memory_mib`).
- Inventory keys: kebab-case hostnames (`"mcp-nats01"`, `"mcp-audit"`).

## Shell Script Standards

**Shebang:** `#!/usr/bin/env bash` for every script under `scripts/` and
`nixos/tests/` (no `/bin/bash`). Test scripts do not use fish.

**Mandatory prologue:** `set -euo pipefail` is universal — every script
reviewed (`scripts/add-host.sh`, `scripts/bootstrap-host.sh`,
`scripts/init-secrets.sh`, all `nixos/tests/audit*.sh`, inline
`pkgs.writeShellScript` bodies in Nix modules).

**File header:** each script opens with its invocation, purpose, and
prereqs:

```bash
#!/usr/bin/env bash
# scripts/<name>.sh <args>
#
# <one-paragraph description>
#
# Prereqs on PATH: sops, python3, nix, ssh.
# Prereqs in env: SOPS_AGE_KEY_FILE (workstation key).

set -euo pipefail
```

**Style patterns:**

- **Positional args with defaulted error:** `hostname="${1:?Usage: $0 <hostname>}"`.
- **Env-var defaults with `:=`:**
  `: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"` then `export`.
- **Absolute repo root resolution** from `$BASH_SOURCE`:
  `script_dir="$(cd "$(dirname "$0")" && pwd)"; repo_root="$(cd "$script_dir/.." && pwd)"`.
- **Prereq loop** over binaries, failing with a remediation hint:
  `for bin in age sops python3 jq; do command -v "$bin" || { echo "error: ..."; exit 1; }; done`.
- **Tmpfs + trap for secrets:** secret-touching scripts create `mktemp -d`,
  `trap 'shred -u "$tmp/key.age" 2>/dev/null || true; rm -rf "$tmp"' EXIT`
  before writing any key material (see `scripts/add-host.sh` lines 55-57).
- **`local` for function-scoped variables.** Functions in
  `scripts/init-secrets.sh` declare every variable with `local`.
- **shellcheck-clean.** `# shellcheck disable=SC<n>` must be accompanied
  by a comment explaining why. No disables without justification.
- **Idempotent by design.** Every operator script is safe to re-run
  (`add-host.sh` refuses to clobber, `bootstrap-host.sh` skips the key
  push when `/var/lib/sops-nix/key.txt` already exists).
- **Skip vs fail.** Integration tests in `nixos/tests/` exit `0` with a
  `skip: <reason>` message when preconditions aren't met (unreachable
  host, placeholder token) and only `exit 1` on real assertion failure
  (`nixos/tests/audit01-datastores.sh`).

**fish usage is scoped.** The `nixos/justfile` sets `shell := ["fish", "-c"]`
for recipes, and `just deploy` uses inline fish inside a `#!/usr/bin/env fish`
heredoc — but all standalone scripts remain bash so they run unchanged on
Proxmox hosts (which ship bash, not fish). Don't introduce fish into the
`scripts/` tree.

## Secrets Handling

**Primary mechanism:** `sops-nix` with per-host age identities.

- **Workstation key** lives at `~/.config/sops/age/keys.txt` and is
  referenced via `SOPS_AGE_KEY_FILE`. The public recipient is pinned
  as `&evelyn` in `nixos/.sops.yaml`.
- **Per-host age keys** are generated by `scripts/add-host.sh <host>`,
  registered in `nixos/.sops.yaml` under a `&<host>` YAML anchor, and
  the private half is stored encrypted-to-workstation-only in
  `nixos/secrets/host-sops-keys.yaml`.
- **First-boot delivery** is `scripts/bootstrap-host.sh`: it extracts
  the host's privkey from the encrypted keystore and installs it at
  `/var/lib/sops-nix/key.txt` (mode 600, owned by root) before the
  first `nixos-rebuild switch`.
- **Every host module** imports `sops-nix.nixosModules.sops` via the
  `mkHost` helper and gets `modules/common.nix` config:

  ```nix
  sops = {
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.generateKey = false;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];  # fallback
    defaultSopsFormat = "yaml";
  };
  systemd.tmpfiles.rules = [ "d /var/lib/sops-nix 0700 root root -" ];
  ```

**`.sops.yaml` conventions:**

- One YAML anchor per human/host recipient under `keys:`.
- One `creation_rule` per encrypted file, with a `path_regex` pinned to
  `secrets/<name>\.ya?ml$`.
- Every rule grants `*evelyn` **plus** exactly the hosts that need to
  decrypt that file. Cluster secrets (e.g. `nats-operator.yaml`) grant
  every `mcp-nats-*` member; per-host secrets grant only that host.

**Never-commit list:**

- `nixos/secrets/*.yaml` unless sops-encrypted (check for a `sops:` key
  at the bottom of the file before `git add`).
- `nixos/keys.txt`, `nixos/*.age`, `terraform/*.tfvars` — all gitignored
  at the repo root (`.gitignore` lines 16-34).
- `nixos/secrets/host-sops-keys.yaml` is committed **only** sops-encrypted
  (encrypts-to-`*evelyn`-only).
- Commit the `.example` versions (e.g. `terraform/terraform.tfvars.example`,
  `nixos/secrets/hermes.yaml.example`) with `REPLACE_ME_*` placeholders.

**Secret generation:** `scripts/init-secrets.sh` is the one-shot
bootstrap for the NATS/audit plane — it generates random credentials
via `openssl rand`, calls `nsc` for JWT material, writes plaintext YAML
through a per-target `generate_*` function into a `mktemp -d`, then
`sops --encrypt --in-place` before `mv`ing the ciphertext into place.
Existing files are never overwritten without `--force`. Dry-run is the
default diagnostic mode.

**Never put secrets into:**

- Terraform variables or state — `.tfstate` files are gitignored, but
  secrets leak into plan logs and `.terraform/` regardless. Use env
  vars for `TF_VAR_*` and inject from an external store.
- Nix `configuration.nix` — secrets are always read from
  `/run/secrets/<name>` at service start, never embedded.
- LLM / agent context — the project's security architecture (see root
  `README.md`) is built around never letting credentials enter model
  context. This applies to code assistants too.

## Error Handling

- **Nix:** prefer build-time failure. Use `throw` inside `let` blocks
  or `assertions` in `config` to stop `nix flake check`. Avoid
  `lib.warn` for policy — warnings get ignored.
- **Terraform:** use `lifecycle.precondition` / `postcondition` for
  invariants that must hold at plan time. Fail fast rather than
  producing a broken resource.
- **Shell:** rely on `set -euo pipefail`. Write explicit `exit 1` with
  a `>&2` error message + remediation hint when detecting a
  precondition failure (`scripts/add-host.sh` lines 47-51).

## Comments

**Write comments that will still be true next year.**

- Cite the decision record (`D-03`, `AUDIT-05`, `Pitfall P9`) that
  motivates each non-obvious invariant — see the opening block of
  `nixos/modules/nats-cluster.nix` and the inline comments throughout.
- Explain **why** something is forbidden or deliberately absent
  ("Deliberately NOT in this module" sections); future contributors
  will otherwise re-add it.
- `FIXME(Plan NN-NN)` tags reference an open planning task
  (`hosts/mcp-audit/default.nix` line 27 `promSourceIp` placeholder).

## Git / Commit Conventions

- Feature branches + PRs; never push directly to `main`.
- Conventional-commit-adjacent subjects seen in `scripts/add-host.sh`
  suggested next-step (`feat: bootstrap age identity for $hostname`),
  but no enforcement tooling.
- `.planning/` is **never** committed — it's listed in the root
  `.gitignore` and in the user's global gitignore.

---

*Convention analysis: 2026-04-22*
