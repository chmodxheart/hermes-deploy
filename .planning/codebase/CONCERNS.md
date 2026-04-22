# Codebase Concerns

**Analysis Date:** 2026-04-22

**Repo:** `hermes-deploy` — solo-operator NixOS + Terraform monorepo for a
Proxmox LXC lab (5 commits, single author, single branch). Every concern below
is evaluated through that lens: no CI, no second operator, no staging, one
workstation holds the keys.

---

## Critical — Blocks or Breaks Deploy

### C1. Terraform and NixOS disagree about the container network

- **Files:**
  - `terraform/locals.tf:6-70` — every container has `ipv4 = "10.0.120.2x/24"`,
    `gateway = "10.0.120.1"`, `vlan_id = 1200`, `bridge = "vmbr1"`.
  - `nixos/hosts/mcp-audit/default.nix:21,35-38,146-149` — `lxcIp = "10.0.2.10"`,
    `auditPlaneAllowlist = ["10.0.2.10" .. "10.0.2.13"]`,
    `networking.extraHosts` maps `10.0.2.10 mcp-audit.samesies.gay` etc.
  - `nixos/hosts/mcp-nats0{1,2,3}/default.nix:20,34-39,201-206` — same `10.0.2.x`
    hardcoded block.
- **Problem:** Terraform provisions containers on `10.0.120.0/24 VLAN 1200`.
  NixOS configs assume `10.0.2.0/24`. The firewall allowlists, step-ca ACME
  allowlist, `/etc/hosts` bootstrap fallback, and cluster peer routes all
  reference addresses that don't exist on the container's actual interface.
- **Impact:** After `terraform apply` + `bootstrap-host.sh`, NATS cluster peers
  can't reach each other on 6222, Vector clients can't dial 4222, step-ca
  ACME won't accept requests. A fresh bring-up from main will not converge.
- **Fix approach:** Either make the NixOS host module derive its network from
  Terraform-exported facts (push through `nixos-handoff.md`), or align one
  side on the other and add a flake-check that greps the rendered nftables
  for `lxcIp` and asserts it matches the container's actual `ipv4`.

### C2. Auto-upgrade points at a different GitHub account than the remote

- **Files:**
  - `nixos/modules/common.nix:32-43` — `system.autoUpgrade.flake =
    "github:escidmore/hermes-deploy?dir=nixos"`, runs daily at 04:00 across
    every host that doesn't `mkForce` it off (i.e. `hermes`).
  - Actual git remote: `github-alt:chmodxheart/hermes-deploy`.
- **Problem:** Two different GitHub accounts. If `escidmore/hermes-deploy`
  doesn't exist or is stale, `hermes` silently fails auto-upgrades every night
  and nobody notices until a security update is needed. If it DOES exist and is
  someone else's fork, it runs their code as root on hermes daily.
- **Impact:** Either dead auto-upgrade (drift, unpatched kernel) or
  supply-chain compromise surface. Both are bad; the second is catastrophic.
- **Fix approach:** Verify which account is canonical, point every reference
  to it, and add a CI-ish check (even just a `just` recipe) that warns when
  the `autoUpgrade.flake` URL and the `origin` remote disagree. Consider
  disabling `allowReboot = false` + leaving auto-upgrade on for hermes while
  audit-plane hosts `mkForce` it off — this asymmetry is easy to forget.

### C3. Terraform state is local, on one laptop, unbacked

- **Files:**
  - `terraform/terraform.tfstate` (47 KB, present on disk, gitignored)
  - `terraform/terraform.tfstate.backup` (present on disk)
  - `terraform/versions.tf` — no `backend` block → defaults to local state.
  - `.gitignore:14-16` — `terraform/*.tfstate*` all ignored.
- **Problem:** The only copy of Terraform state lives at
  `~/repo/hermes-deploy/terraform/terraform.tfstate` on one workstation.
  Lose the disk, lose the ability to `terraform destroy` / `refresh` / manage
  the 4 audit-plane LXCs cleanly. `terraform import` across 4 containers
  with per-container `null_resource` is annoying but possible; the provider
  also treats unknown state as "create a new one," so the real risk is
  double-provisioning and a VMID collision.
- **Impact:** Disk loss = Terraform drift that has to be reconciled by hand.
  Recovery path exists but is undocumented; runbook below does not cover it.
- **Fix approach:** Research already recommends
  `s3 backend + use_lockfile = true` (see
  `terraform/.planning/research/STACK.md`). Even pointing it at the local
  MinIO (`minio.samesies.gay`) would upgrade this from "one disk" to "one
  disk + one MinIO bucket + snapshots." Until then: at minimum, encrypt-and-
  copy `terraform.tfstate` into Proxmox Backup Server or an age-encrypted
  blob in `host-sops-keys.yaml` sibling file so it travels with the repo.

### C4. `hermes_repo_path` hardcoded to one machine

- **File:** `terraform/main.tf:43-47`
  ```hcl
  variable "hermes_repo_path" {
    default = "/home/eve/repo/hermes-deploy"
  }
  ```
- **Problem:** Any operator whose clone lives elsewhere (second laptop, VM,
  disaster-recovery machine) has to override this every apply or patch
  the default. Combined with C3, the single-disk risk is amplified: recovery
  requires cloning to the same absolute path.
- **Fix approach:** Default to `path.root` or a relative resolver:
  `"${path.module}/.."` (works because `scripts/` is `../scripts/` from
  `terraform/`). No functionality loss; removes the machine-pinning.

---

## High — Security / State Integrity

### H1. `.git-backups/` ships two bare git repos inside the monorepo

- **Files:**
  - `.git-backups/nixos.git/` (3.1 MB)
  - `.git-backups/terraform.git/` (860 KB)
  - `.gitignore:3` ignores `.git-backups/` (good — not committed).
- **Problem:** These appear to be pre-merge snapshots of the split repos
  before they were folded into the monorepo. They're on-disk but nothing
  in the repo references them, no doc explains whether they're safe to
  delete, and they still resolve `git log`-level history that might
  contain secrets predating the current SOPS setup.
- **Impact:** Stale data, source of operator confusion ("which is the
  real tree?"), possible plaintext-secret exposure if they were ever
  committed before the SOPS migration.
- **Fix approach:** Either move to an off-repo archive (external drive +
  age-encrypt) or document the provenance in `docs/README.md` and keep
  them. Right now they exist without explanation.

### H2. `.sops.yaml` does not cover `mcp-audit-pbs-excludes`-style future secrets, and `host-sops-keys.yaml` can only be decrypted by Evelyn's key

- **File:** `nixos/.sops.yaml:10-13`
  ```yaml
  - path_regex: secrets/host-sops-keys\.ya?ml$
    key_groups:
      - age:
          - *evelyn
  ```
- **Problem:** The file that seeds every other host's age key is encrypted
  to exactly one recipient — the workstation age key at
  `~/.config/sops/age/keys.txt`. If that key is lost, no host can have its
  age identity recovered, which means no encrypted secret can be decrypted
  anywhere, which means no deploy. Bus factor = 1 key on 1 disk.
- **Impact:** Total loss of deploy capability if the workstation disk dies
  and the age key wasn't backed up separately.
- **Fix approach:** Add a second recipient (a YubiKey-age identity, a
  paper-backup age key stashed offline, or a second workstation). Document
  the recovery procedure in `nixos/docs/ops/`. Right now the README assumes
  the workstation key exists and says "If rotated, update `.sops.yaml`"
  but gives no instructions for *losing* it.

### H3. `terraform/terraform.tfvars` contains the Proxmox API token on disk

- **File:** `terraform/terraform.tfvars` (254 bytes, gitignored, present on
  disk). Based on `terraform.tfvars.example`, it contains
  `virtual_environment_api_token = "..."`.
- **Problem:** Plaintext API token on a single workstation disk. Not in
  git, but not in any SOPS file either. Nothing encrypts or rotates it.
  Research doc `research/STACK.md` already flags this: *"Hardcoded
  credentials in backend/provider config. Terraform docs warn that
  backend-config secrets can leak into `.terraform` and plan files."*
- **Impact:** Full Proxmox API compromise if the workstation is breached,
  and possible leakage into `.terraform/` cache or plan files.
- **Fix approach:** Load via environment — provider already supports
  `PROXMOX_VE_API_TOKEN` — and source it from a SOPS-decrypted dotenv or
  `pass`. Remove `terraform.tfvars` entirely once env-only works.

### H4. Hermes first-boot requires commenting out sops blocks in-tree

- **File:** `nixos/README.md:118-130` — step 3 literal instruction:
  *"Comment out the `sops.secrets.*` blocks in
  `hosts/hermes/default.nix` for the very first build"*
- **Problem:** The documented bring-up mutates committed Nix source as a
  bootstrap step. Easy to forget to revert; easy to accidentally commit
  the "commented-out-for-bootstrap" state. There is no module-option
  toggle for this.
- **Fix approach:** Thread a `services.hermes-agent.bootstrap = true`
  style flag through the module so bootstrap mode is declarative, or
  move to the same pattern used by the audit plane
  (`validateSopsFiles = false` + pre-seeded
  `/var/lib/sops-nix/key.txt` via `scripts/bootstrap-host.sh`).

### H5. SSH authorized key sourced from `~/.ssh/id_ed25519.pub` at apply time

- **File:** `terraform/locals.tf:20,36,52,68` — every container uses
  `ssh_authorized_key_files = [pathexpand("~/.ssh/id_ed25519.pub")]`.
- **Problem:** The operator's SSH key is baked into every new LXC at
  create time. If that key is rotated, the containers don't learn — no
  re-apply path short of `terraform apply -replace=...` on every
  container. Also makes "recover from another machine" hard, since the
  *other* machine's key isn't in any container.
- **Fix approach:** Declare the operator's public key once in NixOS
  (`users/eve.nix` already does `users.users.eve.openssh.authorizedKeys`)
  and make Terraform's initial authorized keys a documented bootstrap
  seed only. Document rotation explicitly.

---

## Medium — Fragility and Operator Risk

### M1. Four FIXMEs paper over unvalidated production IPs

- **Files:**
  - `nixos/hosts/mcp-{audit,nats01,nats02,nats03}/default.nix:26-29`
    ```
    # D-17 narrow Prom carve-out. FIXME(Plan 01-09): substitute real Cilium
    # egress gateway IP before production rebuild; this placeholder is in the
    # common Cilium pod-CIDR range but is not verified against live infra.
    promSourceIp = "10.42.0.14";
    ```
  - Same four files, line 44-47 — `sshAllowlist = "10.0.1.0/24"` with
    FIXME to narrow to Evelyn's workstation IP.
- **Problem:** `10.42.0.14` is a literal guess. The flake-check
  `assert-prom-carveout-narrow` only asserts the carve-out is *concrete*,
  not that it matches reality — so a wrong IP passes checks but allows
  no Prometheus scrape through (or worse, allows a different tenant's
  pod through).
- **Impact:** Broken Prometheus scraping on first bring-up; LAN-wide
  SSH surface until manually tightened.
- **Fix approach:** Resolve the Cilium egress gateway IP, put it in
  Terraform `locals` as a top-level fact, and have NixOS read it from
  the handoff contract. One place to update instead of four.

### M2. `null_resource.nixos_deploy` uses `timestamp()` as a trigger

- **File:** `terraform/main.tf:60-68`
  ```hcl
  triggers = {
    container_vmid = module.lxc_container[each.key].host.vmid
    rebuild_at     = timestamp()
  }
  ```
- **Problem:** Every `terraform plan` shows `~ rebuild_at` for every
  host; every `terraform apply` re-runs `bootstrap-host.sh` on every
  host, which runs `nixos-rebuild switch`. This is deliberate (so flake
  changes deploy without a Terraform-visible diff) but it means:
  (a) every plan has noise, (b) every apply is O(hosts) slow even when
  nothing changed, (c) there's no way to apply to just one host without
  `-target=` or `-replace=`.
- **Impact:** Operator friction, slow iteration, no good "nothing
  changed" signal.
- **Fix approach:** Replace `timestamp()` with a hash of the NixOS
  flake inputs (`nixos/flake.lock`'s mtime or its rev). Or move the
  "re-deploy on NixOS change" concern out of Terraform entirely and
  run `bootstrap-host.sh` as a separate `just deploy` recipe.

### M3. `bootstrap-host.sh` decrypts every host's age key to extract one

- **File:** `scripts/bootstrap-host.sh:73-75`
  ```sh
  privkey=$(sops --decrypt "$nixos_root/secrets/host-sops-keys.yaml" \
            | python3 -c '... yaml.safe_load(sys.stdin)["'"$hostname"'"] ...')
  ```
- **Problem:** The entire decrypted YAML (every host's age private key)
  transits through a python interpreter on the workstation, then only
  one key is piped to SSH. The plaintext lives in python's memory for
  the duration and could be captured by any process sharing the user's
  ptrace scope. Also: `"$hostname"` is string-interpolated into a
  python literal; a hostname with `"` or `\` would break or inject.
  (Hostnames come from `$1` → CLI; currently safe because only
  Evelyn calls it, but brittle.)
- **Fix approach:** `sops --decrypt --extract '["mcp-nats01"]'` does
  the selection inside sops without exposing sibling keys. Remove the
  python middle-step entirely.

### M4. `secrets/mcp-audit.yaml` and `secrets/nats-operator.yaml` are committed but `mcp-audit.yaml.example` exists

- **Files:** `nixos/secrets/mcp-audit.yaml` (encrypted, committed),
  `nixos/secrets/mcp-audit.yaml.example` (plaintext template, committed),
  ditto for `nats-operator`, `mcp-nats0{1,2,3}`.
- **Problem:** All `.yaml` files verified SOPS-encrypted
  (`ENC[AES256_GCM,...]` prefix on every value). Good. But the convention
  isn't enforced anywhere. A future `sops -e -i` forgotten step and an
  unencrypted `secrets/foo.yaml` gets committed. No pre-commit hook, no
  CI check, no `git diff` hook that blocks unencrypted `secrets/*.yaml`.
- **Fix approach:** Add a pre-commit hook (or even a committed
  `scripts/check-secrets-encrypted.sh` called from a `just` recipe)
  that scans `nixos/secrets/*.yaml` for `ENC[AES256_GCM` and refuses
  to commit otherwise.

### M5. `init-secrets.sh` generates state but isn't idempotent for secret rotation

- **File:** `scripts/init-secrets.sh:135-152`
- **Problem:** `random_alnum 32` generates postgres/clickhouse/redis
  passwords. The script short-circuits (`--force`-gated) on existing
  encrypted files, which is correct — but there is no complementary
  rotation script. Rotating the postgres password requires hand-
  decrypting, editing, re-encrypting, and coordinating with the running
  services. No runbook exists for this in `nixos/docs/ops/`.
- **Fix approach:** Either accept "secrets rotate by hand, here's the
  runbook" as an explicit ADR and write the runbook, or add a
  `scripts/rotate-secrets.sh` that handles the common paths.

### M6. `nats-operator.yaml` contains NATS operator + admin JWT, decryptable by all three nats-cluster hosts

- **File:** `nixos/.sops.yaml:24-30`
  ```yaml
  - path_regex: secrets/nats-operator\.ya?ml$
    key_groups:
      - age: [*evelyn, *mcp-nats01, *mcp-nats02, *mcp-nats03]
  ```
- **Problem:** Any single compromised nats host can decrypt the operator
  JWT + admin credentials for the whole cluster. That's how NATS JWT
  resolver works (needs it on every server), so it's not avoidable
  without a different resolver — but the blast radius of *one* host
  root = *all* cluster accounts is worth flagging.
- **Fix approach:** Document this explicitly in the README as an
  accepted trade-off. Consider splitting the `admin` creds into their
  own file decryptable only by workstation (they only need to run from
  workstation anyway).

---

## Low — Cleanliness and Bus-Factor

### L1. `docs/ownership-boundary.md` forbids what `main.tf` does

- **Files:**
  - `docs/ownership-boundary.md:17` — *"Do not use guest bootstrap
    provisioners such as `remote-exec` or `file` to push guest state from
    Terraform."*
  - `terraform/main.tf:55-77` — `null_resource.nixos_deploy` uses
    `local-exec` to run `bootstrap-host.sh` which does exactly that.
    Acknowledged at line 36-40: *"Relaxes the ownership boundary
    documented in ../docs/ownership-boundary.md so `terraform apply` is
    the single operator command."*
- **Problem:** The doc says don't; the code does. The comment flags the
  deviation but the doc itself hasn't been updated. Future operator
  reads the doc, believes the boundary is clean, gets surprised.
- **Fix approach:** Update `ownership-boundary.md` with a "Documented
  exceptions" section that names `null_resource.nixos_deploy` and links
  to the comment in `main.tf`.

### L2. Five hosts, one branch, one author, five commits, no tags

- **Evidence:**
  - `git log --oneline` shows 5 commits total.
  - `git remote -v` shows one origin (`chmodxheart/hermes-deploy`).
  - Commit subjects: "hermes/nixos config updates" / "Some doc updates and
    creds setup" — narrative-style, not scoped-style.
- **Problem:** No feature branches, no PRs, no tags for known-good
  revisions, no CHANGELOG. When auto-upgrade deploys from `main` and
  something breaks, there is no `v0.1.0` to roll back to; rollback means
  `git reset --hard <sha>` and hoping Nix can garbage-collect back.
- **Fix approach:** Tag known-good states (`v0.1.0-hermes-up`,
  `v0.2.0-audit-plane-up`). Pin `system.autoUpgrade.flake` to a rev or
  tag in production. Solo-operator doesn't need PRs, but named
  anchors cost nothing.

### L3. Two untracked `.planning/` trees: one at repo root, one at `terraform/.planning/`

- **Evidence:** `.planning/` at `/home/eve/repo/hermes-deploy/.planning/`
  and at `/home/eve/repo/hermes-deploy/terraform/.planning/`. Both
  gitignored. The terraform one has extensive Phase 1 / Phase 2
  artifacts (PLAN, SUMMARY, CONTEXT, DISCUSSION-LOG).
- **Problem:** Not a bug — GSD planning by design stays untracked. But
  the concrete concern: *there is no committed record anywhere of why
  any decision was made.* All the "D-02 / D-17 / AUDIT-03" references
  in NixOS host comments point at `.planning/phases/01-audit-substrate/
  01-CONTEXT.md`, which is not in git. Lose `.planning/` = lose the
  reasoning behind every FIXME in the codebase.
- **Fix approach:** Either commit `.planning/` (overrides the global
  ignore), or periodically export a `DECISIONS.md` to `docs/` that
  captures the D-NN invariants referenced from code comments. Right
  now code says "Source: D-11" and there is no D-11 you can grep for
  in-tree.

### L4. No tests for scripts

- **Files:** `scripts/add-host.sh` (160 lines),
  `scripts/bootstrap-host.sh` (97 lines), `scripts/init-secrets.sh`
  (475 lines).
- **Problem:** These scripts are the bring-up path. A typo in
  `init-secrets.sh`'s nsc account creation breaks cluster auth.
  There's a `--dry-run` mode but no automated test harness; the
  `nixos/tests/*.sh` tests are post-deploy integration tests, not
  script unit tests.
- **Fix approach:** `shellcheck` and `shfmt` on all three, wired into
  a `just check-scripts` recipe. A bats harness around the happy
  paths for `add-host.sh` would catch regressions in the fiddly
  `.sops.yaml` YAML surgery.

### L5. `--fast` on nixos-rebuild swallows nixpkgs-bumping drift

- **File:** `scripts/bootstrap-host.sh:91-95`
  ```sh
  "${rebuild_cmd[@]}" switch \
    --flake "$nixos_root#${hostname}" \
    --target-host "$target" \
    --use-remote-sudo \
    --fast
  ```
- **Problem:** `--fast` skips the initial build of
  `nixos-rebuild` itself, which means a nixpkgs bump that changes
  `nixos-rebuild`'s own deps silently uses the old binary. On a
  cold clone, behavior may differ from a warm clone.
- **Fix approach:** Drop `--fast` from the canonical deploy path, or
  document the reason and flip it off whenever the flake input moves.

---

## Undocumented Behavior

### U1. `hermes` host is NOT in `terraform/locals.tf`

- **Files:**
  - `nixos/flake.nix:59-66` — `nixosConfigurations.hermes` exists.
  - `terraform/locals.tf` — only `mcp-audit`, `mcp-nats0{1,2,3}`. No
    `hermes`.
- **Reality:** `hermes` was provisioned manually per `nixos/README.md`
  §"Bringing up the `hermes` LXC" (raw `pct create` commands), not by
  Terraform. The monorepo README implies `terraform apply` is the
  single bring-up command; it isn't, for hermes.
- **Fix:** Document explicitly. Either Terraform-ize hermes (add to
  `locals.tf`) or note "hermes is legacy, managed by hand, not owned
  by Terraform."

### U2. `MCP_DOMAIN = "samesies.gay"` is hardcoded in at least three places

- `terraform/main.tf:74` — `environment = { MCP_DOMAIN = "samesies.gay" }`
- `scripts/bootstrap-host.sh:18` — `domain="${MCP_DOMAIN:-samesies.gay}"`
- `scripts/init-secrets.sh:81` — `service_url="...:4222}"` hardcodes
  `mcp-nats01.samesies.gay`.
- Plus every NixOS module (nats-cluster, otlp-nats-publisher, etc.)
  hardcodes `.samesies.gay` suffixes.
- **Problem:** Not a bug for a solo operator who owns one domain; a
  fragility for future migration. Changing the domain requires grep
  across ~10 files in 3 languages.
- **Fix:** A single `MCP_DOMAIN` fact threaded from Terraform inventory
  through the NixOS `specialArgs`.

---

## Recovery Plan Gaps

The repo documents bring-up but not recovery. Missing runbooks:

| Scenario | Covered? | Notes |
|---|---|---|
| Workstation disk dies, age key lost | **No** | Total deploy-capability loss. No paper-backup or second-recipient documented. |
| `terraform.tfstate` lost | **No** | Manual `terraform import` loop required across 4 containers + 4 null_resources. |
| Single NATS host dies | Partial | `nixos/tests/nats-node-loss.sh` + `nats-restart-zero-drop.sh` exist; rebuild-from-scratch runbook does not. |
| `mcp-audit` dies (hosts step-ca root) | **No** | Every peer's TLS chains through this box. Losing it means re-issuing every cert via a new CA. |
| Proxmox cluster loss | **No** | Nothing in this repo is multi-site. PBS backups presumably exist outside this repo; unclear. |
| `escidmore/hermes-deploy` repo deleted | **No** | `autoUpgrade` silently fails every night. No alert. |

**Fix approach:** Add `nixos/docs/ops/disaster-recovery.md` covering
each row. The `nixos/tests/restore-check.sh` script suggests some
restore automation exists but the doc side is missing.

---

## Bus Factor

- **1 operator.** Single author across all 5 commits.
- **1 workstation.** Age key, Terraform state, Proxmox API token all
  live at `/home/eve/...` on one machine.
- **1 age recipient** decrypts `host-sops-keys.yaml`, which is the
  root of the whole secret tree.
- **1 domain** (`samesies.gay`) hardcoded across ~10 files.
- **1 git remote** (`github-alt:chmodxheart/hermes-deploy`), which is
  not the remote that `autoUpgrade` pulls from.

Nothing here is wrong for a personal lab. Listing it so the costs of
"I'll harden it later" are visible and named.

---

*Concerns audit: 2026-04-22*
