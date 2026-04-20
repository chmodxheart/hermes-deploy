# End-State Data Flow

This is the intended runtime data-flow for the planned Hermes + audit-plane +
future MCP/gateway setup.

It mixes current hosts with planned future ones:

- `hermes` is the user-facing agent host.
- `mcp-nats01/02/03` are the durable NATS / JetStream substrate.
- `mcp-audit` is the audit sink host.
- future gateway / MCP LXCs publish into the same audit substrate.

```mermaid
flowchart LR
  subgraph Users[Users and clients]
    Chat[Discord / Slack / Telegram / LAN clients]
    Operator[Operator workstation]
  end

  subgraph Hermes[hermes LXC]
    HermesAPI[Hermes API :8642]
    HermesAgent[hermes-agent]
    HermesMem[Supermemory plugin]
  end

  subgraph Publishers[Audit publishers on each audit-plane host]
    App[Instrumented app / MCP wrapper / gateway]
    OtlpPub[Local OTLP HTTP receiver -> NATS publisher\n:4318 -> audit.otlp.traces.<host>]
    VectorPub[Local Vector journald publisher\n-> audit.journal.<host>]
  end

  subgraph NATS[NATS / JetStream cluster]
    N1[mcp-nats01]
    N2[mcp-nats02]
    N3[mcp-nats03]
  end

  subgraph Audit[mcp-audit LXC]
    StepCA[step-ca]
    OtlpIngest[langfuse-nats-ingest\nAUDIT_OTLP / audit.otlp.>]
    JournalIngest[Vector journal consumer\nAUDIT_JOURNAL / audit.journal.>]
    AuditMetrics[node_exporter + vector exporter]
    Langfuse[Langfuse web + worker]
    Postgres[Postgres]
    ClickHouse[ClickHouse]
    Redis[Redis]
    JournalFiles[/var/log/journal/remote]
  end

  subgraph External[External dependencies]
    ModelAPI[Custom model API]
    MinIO[MinIO]
    Prometheus[k8s Prometheus]
    ADDNS[AD DNS]
  end

  Chat --> HermesAPI
  HermesAPI --> HermesAgent
  Operator --> HermesAPI
  HermesAgent --> ModelAPI
  HermesAgent --> HermesMem

  App -->|OTLP HTTP / protobuf| OtlpPub
  App -->|journald events| VectorPub

  OtlpPub -->|JetStream publish| N1
  OtlpPub -->|JetStream publish| N2
  OtlpPub -->|JetStream publish| N3
  VectorPub -->|JetStream publish| N1
  VectorPub -->|JetStream publish| N2
  VectorPub -->|JetStream publish| N3

  N1 --> OtlpIngest
  N2 --> OtlpIngest
  N3 --> OtlpIngest
  N1 --> JournalIngest
  N2 --> JournalIngest
  N3 --> JournalIngest

  OtlpIngest -->|OTLP POST| Langfuse
  JournalIngest --> JournalFiles

  Langfuse --> Postgres
  Langfuse --> ClickHouse
  Langfuse --> Redis
  Langfuse --> MinIO

  StepCA -->|24h TLS certs for NATS + publishers| N1
  StepCA -->|24h TLS certs for NATS + publishers| N2
  StepCA -->|24h TLS certs for NATS + publishers| N3
  StepCA -->|24h TLS certs for local publishers| OtlpPub
  StepCA -->|24h TLS certs for local publishers| VectorPub

  Prometheus -->|scrapes node_exporter / vector / nats-exporter| N1
  Prometheus -->|scrapes node_exporter / vector / nats-exporter| N2
  Prometheus -->|scrapes node_exporter / vector / nats-exporter| N3
  Prometheus -->|scrapes node_exporter / vector| AuditMetrics

  N1 -. name resolution .-> ADDNS
  N2 -. name resolution .-> ADDNS
  N3 -. name resolution .-> ADDNS
  Audit -. name resolution .-> ADDNS
```

## Reading the diagram

- The intended steady state is that every telemetry-producing MCP, gateway, or
  NATS host emits:
  - traces via the local OTLP receiver on `127.0.0.1:4318`
  - journald events via the local Vector client
- Trace subjects are `audit.otlp.traces.<host>`.
- Journal subjects are `audit.journal.<host>`.
- The three `mcp-nats*` hosts are the durable event fabric, not the final sink.
- `mcp-audit` is both a local publisher for its own host telemetry and the sink
  host that consumes from JetStream and stores or forwards data.
- Langfuse persistence stays on `mcp-audit`:
  - Postgres for relational state
  - ClickHouse for trace/event analytics with TTLs
  - Redis for queue/cache state
  - external MinIO for object storage

## Boundary notes

- Hermes is intentionally outside the audit-plane ingress boundary.
- Audit-plane LXCs do not accept inbound traffic from the `hermes` LXC; that is
  enforced by the `assert-no-hermes-reach` flake check.
- `step-ca` is co-located on `mcp-audit` and issues the short-lived TLS certs
  used by NATS servers and audit-plane clients.
- Prometheus only scrapes the narrow exporter carve-outs on the audit-plane
  hosts; it does not scrape the Langfuse UI directly.

## Source map

- `nixos/hosts/hermes/default.nix`: Hermes API, agent, and external-memory wiring
- `nixos/modules/mcp-otel.nix`: shared OTel env for audit-plane workloads
- `nixos/modules/otlp-nats-publisher.nix`: local OTLP -> NATS trace hop
- `nixos/modules/vector-audit-client.nix`: local journald -> NATS hop
- `nixos/modules/nats-accounts.nix`: shared AUDIT account and creds materialization
- `nixos/modules/mcp-audit.nix`: Langfuse, ingest bridge, journal archival, TTLs
