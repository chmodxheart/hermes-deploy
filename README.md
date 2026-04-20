# hermes-deploy

Top-level monorepo for the Proxmox LXC lab.

This repo is the deployment system as a whole: Terraform provisions the
Proxmox-side container envelope, NixOS converges the guest systems, and shared
scripts/docs define the operator workflow across both.

# Security architecture

Untrusted data is sanitized, processed by a quarantined LLM with no tools or
credentials, and converted to typed structured data. The privileged agent
reasons over those typed handles — never the raw text — and every tool call
passes through a policy gate before reaching capability-limited write tools.
Credentials live outside the LLM context entirely. Everything is logged.

## Five things to notice

1. **Two LLMs, two jobs.** Quarantined sees untrusted text but can't act.
   Privileged can act but never sees untrusted text. Neither alone is
   exploitable.
2. **Sanitization is the only door in.** Unicode allowlist, domain checks,
   provenance tagging — every untrusted byte passes through it.
3. **Read outputs loop back to sanitization.** API responses contain
   user-generated content. Trusting your own tools' outputs is the mistake
   that defeats most security architectures.
4. **The policy gate is non-optional.** Permission tiers, classifier,
   data-flow rules, human review for bulk/destructive — the privileged LLM
   cannot reach trusted actions any other way.
5. **Credentials never enter LLM context.** A compromised model can't leak
   what it never saw.

**Design philosophy:** assume the model will be compromised, and make sure
the worst outcome is bounded, reversible, and visible.

# Research behind the design

Rough order of "if you only read one":

- **[The lethal trifecta for AI agents][trifecta]** — Simon Willison, 2025.
  Private data + untrusted content + external action = exploit class. Every
  public 2025 agent exploit fits this pattern.
- **[Design Patterns for Securing LLM Agents][patterns]** — Beurer-Kellner
  et al., June 2025 (IBM/Invariant/ETH/Google/Microsoft). Catalogs six
  controller-level patterns; the quarantined/privileged split here is the
  foundational one.
- **[CaMeL: Defeating Prompt Injections by Design][camel]** — Google
  DeepMind, March 2025. Capability-based architecture with information-flow
  control. 77% utility on AgentDojo with provable security vs 84%
  undefended.
- **[Claude Code Auto Mode][automode]** — Anthropic engineering, March
  2026. Documents the reasoning-blind classifier + deny-and-continue
  pattern. Killer datapoint: users approve 93% of permission prompts when
  shown them, making naive confirmation theatrical.
- **[LLMail-Inject][llmail]** — Microsoft et al., 2025. 839 teams,
  208,095 adaptive attacks defeated layered defenses (Spotlighting +
  PromptShield + LLM-judge + TaskTracker). Reason classifiers are warning
  signals here, not gates.
- **[MCPTox][mcptox]**, August 2025. Up to 72.8% attack success via poisoned
  tool descriptions; Claude-3.7-Sonnet refused them <3% of the time. Reason
  for description pinning.
- **[The Summer of Johann][johann]** — Willison's summary of Rehberger's
  Month of AI Bugs, August 2025. One working 0-day per day against Claude
  Code, OpenHands, Cursor, Copilot, Codex, Devin, and Anthropic's own
  Filesystem and Slack MCPs. None had architectural separation.
- **[Mitigating prompt injections in browser use][browser]** — Anthropic,
  November 2025. 1.4% ASR with full mitigation stack is the best published
  browser-agent number anywhere. Anthropic's own framing: *"no browser
  agent is immune to prompt injection."* Realistic goal: bounded blast
  radius, not zero compromise.

[trifecta]: https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/
[patterns]: https://arxiv.org/abs/2506.08837
[camel]: https://arxiv.org/abs/2503.18813
[automode]: https://www.anthropic.com/engineering/claude-code-auto-mode
[llmail]: https://arxiv.org/abs/2506.09956
[mcptox]: https://arxiv.org/abs/2508.14925
[johann]: https://simonwillison.net/2025/Aug/15/the-summer-of-johann/
[browser]: https://www.anthropic.com/research/prompt-injection-defenses

# Why NATS as the audit connector

NATS isn't carrying audit data, it's **enforcing audit invariants**.
Cryptographic identity, publish-only scope, and durable replay are security
properties of the transport itself, not features layered on top.

- **Subject-scoped publish auth + short-lived mTLS from step-ca** — a
  compromised host can publish only to its own subject, cannot impersonate
  another. Identity is cryptographic, not advisory.
- **Publish-only permissions** — a compromised publisher cannot read,
  modify, or delete past audit events. The trail is structurally
  append-only, not policy-append-only.
- **JetStream durability** — if Langfuse, ClickHouse, or a journal sink
  goes down, events buffer instead of disappearing. No blank spots during
  incidents — exactly when you need the trail intact.
- **Multi-consumer fan-out** — adding a SIEM consumer, alerting rule, or
  forensic replay sink is a config change, not new instrumentation on every
  host.
- **Replay over history** — new policy (e.g. "alert on Odoo write within 5
  minutes of a tainted browser read") runs retroactively against stream
  history. Most audit pipelines lose this the moment data hits long-term
  storage.
- **Publisher–consumer decoupling** — compromise of an app host reaches
  NATS only, never Langfuse/Postgres/ClickHouse directly. Compromise of the
  audit ingestion side cannot reach back into application hosts.
- **Subject hierarchy = data classification for free** — `audit.otlp.*`,
  `audit.journal.*`, future `audit.security.*` get distinct retention,
  replication, and ACLs without separate transports.

## Layout

- `terraform/` provisions Proxmox containers.
- `nixos/` defines guest operating system configuration.
- `scripts/` holds shared operator workflows used across both areas.
- `docs/` holds cross-cutting contract and workflow docs.

## Canonical Paths

- Run Terraform from `terraform/`.
- Run NixOS flake commands from `nixos/`.
- Run shared scripts from the repo root as `./scripts/<name>.sh`.

## Common Workflow

1. Build or refresh the NixOS Proxmox LXC template as documented in `docs/template-workflow.md`.
2. Model or update host inventory in `terraform/locals.tf`.
3. Add or update host definitions and secrets in `nixos/`.
4. Bootstrap per-host age identities from the repo root with `./scripts/add-host.sh <hostname>`.
5. Run `terraform apply` from `terraform/` for end-to-end bring-up.

## Docs

- `docs/README.md`: shared docs index.
- `docs/ownership-boundary.md`: Terraform vs NixOS responsibilities.
- `docs/template-workflow.md`: supported template artifact flow.
- `docs/nixos-handoff.md`: Terraform-to-NixOS host contract.
- `nixos/docs/ops/README.md`: NixOS operator runbook index.
- `nixos/docs/ops/deploy-pipeline.md`: operator runbook for one-command deploys.
