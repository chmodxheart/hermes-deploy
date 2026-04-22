# Testing & Validation

**Analysis Date:** 2026-04-22

## Overview

This repo has **no unit-test framework** in the traditional sense — there is
no `jest.config`, no `pytest`, no `cargo test`. Validation is layered across
four planes instead:

1. **Nix eval-time assertions** — invariants encoded as `nix flake check`
   derivations that fail the build when a host's rendered config violates a
   policy (AUDIT-NN / D-NN decision records).
2. **Terraform static checks** — `terraform fmt`, `terraform validate`,
   `tflint`, `lifecycle.precondition` blocks.
3. **On-host integration probes** — bash scripts under `nixos/tests/` that
   SSH into the deployed host and assert runtime behaviour (systemd units
   active, Prometheus rules registered, OTLP spans round-tripping through
   Langfuse).
4. **Deployment idempotence** — every operator script is safe to re-run;
   re-applying a clean Terraform state should produce zero Nix-side drift.

There is **no CI/CD**. There is **no pre-commit tooling**. Both are gaps
(see *Gaps* below).

## Nix Eval-Time Checks

**Location:** `nixos/flake.nix` `checks.${system}` attrset (lines 116-384).

**Run:**
```fish
# From nixos/
just check              # nix flake check --no-build
nix flake check         # full check including derivation builds
```

**Pattern.** Every check filters `self.nixosConfigurations` to the hosts it
applies to, produces a per-host derivation that either `touch $out` on pass
or `exit 1` with a `FAIL:` message on the policy violation, then aggregates
them under one root derivation via `nativeBuildInputs = perHost`. A single
bad host fails the aggregate.

**Active checks (as of this analysis):**

| Check | Scope | Enforces |
|-------|-------|----------|
| `assert-no-hermes-reach` | every `mcp-*` host | D-11: no nftables `accept` rule references the hermes source IP (`10.0.1.91`). Delegates to `nixos/tests/nft-no-hermes.nix`. |
| `assert-prom-carveout-narrow` | every `mcp-*` host | D-17: `networking.nftables.tables.prom-scrape` exists, has a concrete source IP, and contains no `0.0.0.0/0` / wildcard `saddr`. |
| `nats-no-anonymous` | every `mcp-nats-*` host | D-03: `services.nats.enable = true`, rendered settings contain no `allow_anonymous: true`, and include a `resolver.type = "full"` block. Greps the JSON-serialized settings — catches the toggle even though `services.nats` has no `configFile` option. |
| `mcp-audit-pbs-excludes` | every `mcp-*` host | FOUND-06 / D-12: `services.mcpAuditPbs.excludePaths` is a superset of the 8-path default (`/run`, `/var/run`, `/proc`, `/sys`, `/dev`, `/tmp`, `/var/cache`, `/run/secrets`). Hosts may extend, never shrink. Uses `lib.subtractLists` to compute missing paths and `throw`s with the diff. |
| `step-ca-cert-duration-24h` | any host with `services.step-ca.enable = true` | D-04: both `defaultTLSCertDuration` and `maxTLSCertDuration` are `"24h"`. Vacuous when no step-ca host exists yet. |
| `langfuse-image-pinned-by-digest` | every `mcp-*` host | D-06: every `virtualisation.oci-containers.containers.langfuse-*.image` matches `@sha256:[0-9a-f]{64}` — tag-only refs and `:latest` fail. |
| `otel-module-consistent` | every `mcp-*` host | AUDIT-05 / D-14: the four static OTEL env vars on `environment.sessionVariables` match the expected values. `throw`s at eval time with the diff. |

**Helper modules under `nixos/tests/`:**

- `nft-no-hermes.nix` — pure Nix function `{ pkgs, hostConfig, hermesIp,
  hostName } -> derivation` used by `assert-no-hermes-reach`. Accepts
  `hostConfig = null` as a documented no-op (passes vacuously) so
  `flake.nix` can invoke it generically even when no `mcp-*` host has
  been added.

**Writing a new check.** Follow the existing pattern:

1. Add a new attribute under `checks.${system}` in `nixos/flake.nix`.
2. Filter `self.nixosConfigurations` to the hosts in scope.
3. For per-host shell assertions, return `pkgs.runCommand "<name>-${h}" { ... } '' ... ''`.
4. For pure-Nix assertions, `throw` inside a `let` so the error surfaces
   during `nix eval` and not mid-build.
5. Aggregate per-host derivations with `nativeBuildInputs = perHost`.
6. Include a comment header citing the decision record
   (`# AUDIT-NN + D-NN — <policy>`).

## Terraform Validation

**Lint config:** `terraform/.tflint.hcl`:

```hcl
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
```

**Baseline commands (run from `terraform/`):**

```bash
terraform fmt -check -recursive
terraform validate
tflint
terraform plan -out=tfplan
```

All four are expected to be clean before `terraform apply`. There is no
automation around this — it's operator discipline.

**Built-in invariants:**

- `terraform/modules/lxc-container/main.tf` uses a
  `lifecycle.precondition` block to require at least one SSH key per
  container — fails at plan time if the inventory omits keys.
- Version pins are pessimistic (`~>`): `terraform ~> 1.14.0`, provider
  `bpg/proxmox ~> 0.102.0`, `hashicorp/null ~> 3.2.4`. A minor-version
  provider bump requires an explicit lockfile regeneration.

**State:** `terraform/terraform.tfstate` is committed (local backend).
This is a gap — see *Gaps*.

## On-Host Integration Probes

**Location:** `nixos/tests/*.sh`, plus `nixos/tests/fixtures/` for
binary payloads (e.g. `sample-gen-ai-span.bin` for the OTLP round-trip).

**Run style:** scripts take target and credential config through env
vars with defaults, and skip cleanly when preconditions aren't met:

```bash
: "${STAGE_HOST:=mcp-audit.samesies.gay}"
: "${PROM_TOKEN:=REPLACE_ME}"

if [[ "$PROM_TOKEN" == "REPLACE_ME" ]]; then
  echo "skip: PROM_TOKEN not set" >&2
  exit 0
fi
```

**Probe inventory:**

| Script | Phase | Asserts |
|--------|-------|---------|
| `audit01-datastores.sh` | AUDIT-01 | `postgresql.service`, `clickhouse.service`, `redis-langfuse.service` are active on `$STAGE_HOST`. |
| `audit01-langfuse-up.sh` | AUDIT-01 | Langfuse web/worker up. |
| `audit02-disk-alert.sh` / `audit02-prom-alert.sh` / `audit02-ttl.sh` | AUDIT-02 / D-10 | Prometheus `MCPAuditDiskHigh` rule is registered via `/api/v1/rules`. TTL policy present. |
| `audit03-hermes-probe.sh` / `audit03-nft-assert.sh` | AUDIT-03 / D-11 | Hermes cannot reach the audit plane (runtime complement to `assert-no-hermes-reach`). |
| `audit04-nats-anon.sh` / `audit04-nats-mtls.sh` | AUDIT-04 / D-03 | NATS rejects anonymous publishers; mTLS is required. |
| `audit05-otlp-e2e.sh` | AUDIT-05 / D-15 SC-3 | Posts `tests/fixtures/sample-gen-ai-span.bin` to Langfuse OTLP and confirms `gen_ai.tool.name` survives. Requires `LF_PK` / `LF_SK`. |
| `nats-node-loss.sh` / `nats-restart-zero-drop.sh` | AUDIT-04 | JetStream durability under node loss / restart. |
| `restore-check.sh` | AUDIT-06 | PBS restore workflow produces a usable artifact. |

**Conventions for new probes:**

- `#!/usr/bin/env bash` + `set -euo pipefail` + a source-citing header.
- Gate on reachability (`ssh -o BatchMode=yes -o ConnectTimeout=3 "$host"
  true`) and secret placeholders before asserting.
- Use `OK: <what>` / `FAIL: <what>` / `skip: <why>` consistently — the
  output format is expected to be `grep`-friendly.
- Exit `0` for pass or skip, `1` for real failure. Never conflate the
  two.

## Deployment Verification

**`just dry-run <host>`** — runs `nixos-rebuild dry-activate` to preview
what would change without touching the system.

**`just build <host>`** — builds the toplevel derivation (`nix build
.#nixosConfigurations.<host>.config.system.build.toplevel`) without
activating. The output symlink is `nixos/result` (gitignored).

**`just deploy <host> <target>`** — SSH-deploys via
`nixos-rebuild switch --target-host ... --use-remote-sudo --fast`.
Delegates to `scripts/bootstrap-host.sh` when the target matches the
host's declared name (so first-boot key delivery runs).

**`terraform apply`** — end-to-end bring-up; creates the LXC, then the
`null_resource.nixos_deploy` trigger fires `scripts/bootstrap-host.sh`
for every container. `triggers.rebuild_at = timestamp()` forces the
deploy to re-run on every apply (idempotent by design). To force a
redeploy of a single host without changing Terraform:

```bash
terraform apply -replace='null_resource.nixos_deploy["mcp-audit"]'
```

**Post-apply verification checklist:**

1. `just check` from `nixos/` — flake invariants hold.
2. `ssh <host> systemctl --failed` — no failed units.
3. `ssh <host> journalctl -u <service> -e` for any service depending
   on `/run/secrets/*` — confirms sops-nix decrypted on boot.
4. Run the relevant `nixos/tests/audit*.sh` probes.

## Developer Workstation Setup

`nix develop` inside `nixos/` provides the toolchain:

```nix
devShells.${system}.default = pkgs.mkShell {
  packages = with pkgs; [ age nil nixos-rebuild nixfmt-rfc-style sops ssh-to-age just ];
};
```

This is the canonical environment — don't rely on system-installed
versions.

## Gaps

These are **real holes** in the validation story. Each one is a candidate
for a future phase.

- **No CI.** No `.github/workflows/`, no GitLab CI, no Drone config. Every
  check (`just check`, `terraform validate`, `tflint`, shellcheck, probes)
  runs only if the operator remembers to run it. Locally this is fine for
  a solo lab; any collaborator or unattended drift detection needs CI.

- **No pre-commit hooks.** There is no `.pre-commit-config.yaml` at any
  level. `shellcheck`, `shfmt`, `nixfmt`, `terraform fmt`, `tflint`,
  `actionlint`, and `zizmor` are all available in nixpkgs but unwired.
  `prek` (Rust-based pre-commit replacement) is the suggested tool per
  the user's global standards. `nixos/.pre-commit-config.yaml` is
  gitignored (`.gitignore` line 32) — suggesting an aborted attempt.

- **No `terraform plan` diff check in any workflow.** Plans are produced
  manually and reviewed by eye.

- **Terraform state is local and committed.** `terraform/terraform.tfstate`
  and `terraform.tfstate.backup` are tracked in git (not in `.gitignore` —
  the gitignore lists `*.tfstate` at repo root but the files live at
  `terraform/terraform.tfstate` and predate the ignore). State should be
  moved to an S3-compatible remote backend with `use_lockfile = true`
  before any second operator is added. Current `.gitignore` already lists
  `terraform/*.tfstate` — the tracked state file appears to pre-date that
  rule. **Committed state may leak secrets** and is a security concern.

- **No schema validation for `terraform/locals.tf` inventory.** The repo
  ships `terraform/contracts/nixos-hosts.schema.json` and an
  `examples/nixos-hosts.example.json`, but nothing validates `locals.tf`
  against the schema. A typo in `ipv4` or `mac_address` only surfaces at
  `terraform apply`.

- **No automated shellcheck/shfmt sweep.** Individual scripts contain
  targeted `# shellcheck disable=` directives (e.g.
  `scripts/add-host.sh:56`, `nixos/tests/audit01-datastores.sh:23`), so
  the authors clearly run shellcheck — but there's no enforcement.

- **No automated run of `nixos/tests/*.sh` after deploy.** The probes
  exist but aren't wired to `terraform apply`'s post-hook or to `just
  deploy`. Running them is manual.

- **No backup/restore drill automation.** `restore-check.sh` exists but
  runs on-demand only — there's no scheduled drill.

- **Coverage gaps for unfinished phases.** `nats-cluster.nix` documents
  `Plan 01-07 adds a flake-check grepping the rendered settings for the
  anonymous-enable toggle as defense-in-depth` — the check exists
  (`nats-no-anonymous`), but similar defense-in-depth sweeps for other
  modules (OTEL, Langfuse digest pinning for non-`mcp-*` hosts) are not
  yet written.

- **No secrets-leak pre-commit scan.** No `gitleaks` / `trufflehog` /
  `detect-secrets` hook. The sops workflow is strong, but a `git add`
  of a plaintext `secrets/*.yaml` would slip through.

---

*Testing analysis: 2026-04-22*
