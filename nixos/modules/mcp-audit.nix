# modules/mcp-audit.nix
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-05 (external MinIO)
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-06 (oci-containers + digest pin)
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-08 (Python ingest service)
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-09 (ClickHouse TTLs)
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-10 (disk-check timer)
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-12 (PBS excludes)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pattern 4 (oci-containers)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Code Examples Common Operation 1/2/4
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P1/P3/P4/P7/A5/A9
# Source: .planning/phases/01-audit-substrate/01-PATTERNS.md §modules/mcp-audit.nix
#
# Audit-sink host module. Imported by hosts/mcp-audit/default.nix.
# Declares the full Langfuse v3 stack (native Postgres 17 + ClickHouse 25.10 +
# Redis 8 + oci-containers langfuse-web/worker digest-pinned), the Python
# langfuse-nats-ingest service (D-08 / FOUND-07 hardening), the ClickHouse
# TTL boot-oneshot and weekly re-apply timer (D-09 + Q5 resolution), the
# disk-check timer (D-10), and the Vector consumer side (audit.journal.>
# -> /var/log/journal/remote/).
#
# D-05 amendment: NO in-LXC MinIO container. Langfuse env (sops-provided)
# points at https://minio.samesies.gay -- outbound carve-out lives in the
# host-level nftables (hosts/mcp-audit/default.nix).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  # D-06 digest pins (researcher-verified 2026-04-17).
  # 2026-04-17 -- https://github.com/langfuse/langfuse/releases/tag/v3.169.0
  # Tag: 3.169.0
  langfuseWebDigest = "sha256:cdfdca609912edffd616503e43427395fcf135423422440d74c89d9d552b74f9";
  # 2026-04-17 -- https://github.com/langfuse/langfuse/releases/tag/v3.169.0
  # Tag: 3.169.0
  langfuseWorkerDigest = "sha256:f8a9eb480b31cc513ad9ed9869eeb3416cb7bdf00c598665c008c460566115d1";

  # D-05: MinIO is EXTERNAL -- no in-LXC container here.

  # Shared ExecStartPre gate: wait for Langfuse web healthcheck before
  # touching the ClickHouse schema (migrations must land first).
  waitForLangfuseWeb = pkgs.writeShellScript "wait-for-langfuse-web" ''
    set -euo pipefail
    for _ in $(seq 1 120); do
      if ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:3000/api/public/health >/dev/null 2>&1; then
        exit 0
      fi
      sleep 5
    done
    echo "langfuse-web not healthy after 10min" >&2
    exit 1
  '';

  applyClickhouseTtls = pkgs.writeShellScript "apply-clickhouse-ttls" ''
    set -euo pipefail
    # shellcheck disable=SC2155 -- clickhouse-client reads password from arg
    ${pkgs.clickhouse}/bin/clickhouse-client \
      --user langfuse \
      --password "$(cat /run/secrets/clickhouse-password)" \
      --database langfuse \
      --multiquery < ${../hosts/mcp-audit/clickhouse-schema.sql}
  '';

  # Weekly re-apply (Q5): `ALTER TABLE ... MODIFY TTL` is a metadata-only no-op
  # when TTL already matches -- re-running restores the invariant if a
  # Langfuse version bump silently dropped it.
  reapplyClickhouseTtls = pkgs.writeShellScript "reapply-clickhouse-ttls" ''
    set -euo pipefail
    if ! ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:3000/api/public/health >/dev/null 2>&1; then
      echo "langfuse-web not healthy -- skipping TTL re-apply" >&2
      exit 0
    fi
    ${pkgs.clickhouse}/bin/clickhouse-client \
      --user langfuse \
      --password "$(cat /run/secrets/clickhouse-password)" \
      --database langfuse \
      --multiquery < ${../hosts/mcp-audit/clickhouse-schema.sql}
  '';

  # Langfuse user ALTER from sops (Postgres). Postgres starts first; we
  # flip the password out of the placeholder once the secret is on disk.
  setLangfusePgPassword = pkgs.writeShellScript "set-langfuse-pg-password" ''
    set -euo pipefail
    # shellcheck disable=SC2155 -- psql reads password via SQL escape
    pw=$(cat /run/secrets/postgres-password)
    ${config.services.postgresql.package}/bin/psql \
      --username postgres \
      --dbname postgres \
      --no-psqlrc \
      --command "ALTER USER langfuse WITH PASSWORD '$pw';"
  '';

  # ClickHouse langfuse-user provisioning from sops.
  createClickhouseLangfuseUser = pkgs.writeShellScript "create-clickhouse-langfuse-user" ''
    set -euo pipefail
    # Wait for ClickHouse TCP to accept before issuing DDL.
    for _ in $(seq 1 60); do
      if ${pkgs.clickhouse}/bin/clickhouse-client --query "SELECT 1" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    # shellcheck disable=SC2155 -- password flows via SQL escape
    pw=$(cat /run/secrets/clickhouse-password)
    ${pkgs.clickhouse}/bin/clickhouse-client --query \
      "CREATE USER IF NOT EXISTS langfuse IDENTIFIED BY '$pw';"
    ${pkgs.clickhouse}/bin/clickhouse-client --query \
      "GRANT ALL ON *.* TO langfuse;"
  '';
in
{
  config = {
    # ---------------------------------------------------------------------
    # 1. Native Postgres 17 (D-06)
    # ---------------------------------------------------------------------
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17;
      ensureDatabases = [ "langfuse" ];
      ensureUsers = [
        {
          name = "langfuse";
          ensureDBOwnership = true;
        }
      ];
      # Password is set via sops oneshot below -- no hard-coded initialScript
      # (would commit a literal placeholder into /nix/store).
    };

    # Oneshot that stamps the Langfuse PG password from sops after postgres
    # starts. `After = postgresql.service` and before any consumer.
    systemd.services.langfuse-pg-password-set = {
      description = "Set Langfuse Postgres password from sops";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        ExecStart = setLangfusePgPassword;
      };
    };

    sops.secrets."postgres-password" = {
      key = "postgres_password";
      path = "/run/secrets/postgres-password";
      owner = "postgres";
      group = "postgres";
      mode = "0400";
    };

    # ---------------------------------------------------------------------
    # 2. Native ClickHouse (D-06, P3, P7 built-in Prometheus endpoint)
    # ---------------------------------------------------------------------
    services.clickhouse.enable = true;

    # P7: no services.prometheus.exporters.clickhouse module exists; wire
    # the server's built-in /metrics endpoint via config.d drop-in (safer
    # than services.clickhouse.extraConfig which is finicky on 25.x).
    environment.etc."clickhouse-server/config.d/prometheus.xml".text = ''
      <?xml version="1.0"?>
      <clickhouse>
        <prometheus>
          <port>9363</port>
          <endpoint>/metrics</endpoint>
          <metrics>true</metrics>
          <asynchronous_metrics>true</asynchronous_metrics>
          <events>true</events>
          <errors>true</errors>
        </prometheus>
      </clickhouse>
    '';

    systemd.services.clickhouse-langfuse-user = {
      description = "Create Langfuse ClickHouse user from sops";
      wantedBy = [ "multi-user.target" ];
      after = [ "clickhouse.service" ];
      requires = [ "clickhouse.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "clickhouse";
        Group = "clickhouse";
        ExecStart = createClickhouseLangfuseUser;
      };
    };

    sops.secrets."clickhouse-password" = {
      key = "clickhouse_password";
      path = "/run/secrets/clickhouse-password";
      owner = "clickhouse";
      group = "clickhouse";
      mode = "0400";
    };

    # ---------------------------------------------------------------------
    # 3. Native Redis 8 -- NAMED instance (P4: services.redis.servers.<name>)
    # ---------------------------------------------------------------------
    services.redis.servers.langfuse = {
      enable = true;
      port = 6379;
      bind = "127.0.0.1";
      settings.maxmemory-policy = "noeviction"; # required by Langfuse BullMQ
      requirePassFile = "/run/secrets/redis-password";
    };

    sops.secrets."redis-password" = {
      key = "redis_password";
      path = "/run/secrets/redis-password";
      owner = "redis-langfuse";
      group = "redis-langfuse";
      mode = "0400";
    };

    # ---------------------------------------------------------------------
    # 4. Langfuse app-tier via oci-containers (D-06 digest-pinned)
    # ---------------------------------------------------------------------
    virtualisation.oci-containers.containers = {
      langfuse-web = {
        # D-06: `@sha256:` digest pin + human-readable tag comment.
        image = "langfuse/langfuse@${langfuseWebDigest}";
        # tag 3.169.0 -- published 2026-04-17
        extraOptions = [ "--network=host" ]; # A5: localhost reach to datastores
        # AUDIT-01 invariant: bind ONLY on 127.0.0.1:3000. SSH port-forward
        # to reach the UI. No nftables rule ever opens 3000 inbound.
        ports = [ "127.0.0.1:3000:3000" ];
        environmentFiles = [ config.sops.secrets.langfuse-web-env.path ];
        # env keys (from secrets/mcp-audit.yaml.example):
        #   DATABASE_URL, NEXTAUTH_URL, NEXTAUTH_SECRET, SALT, ENCRYPTION_KEY
        #   CLICKHOUSE_URL, CLICKHOUSE_MIGRATION_URL, CLICKHOUSE_USER, CLICKHOUSE_PASSWORD
        #   REDIS_CONNECTION_STRING
        #   LANGFUSE_S3_EVENT_UPLOAD_{BUCKET,REGION,ACCESS_KEY_ID,
        #     SECRET_ACCESS_KEY,ENDPOINT=https://minio.samesies.gay (D-05),
        #     FORCE_PATH_STYLE=true (A9), PREFIX}
      };
      langfuse-worker = {
        image = "langfuse/langfuse-worker@${langfuseWorkerDigest}";
        # tag 3.169.0 -- published 2026-04-17
        extraOptions = [ "--network=host" ];
        environmentFiles = [ config.sops.secrets.langfuse-worker-env.path ];
      };
    };

    # D-06 module-level enforcement: both images MUST be digest-pinned.
    # `flake.nix checks.langfuse-image-pinned-by-digest` provides
    # defense-in-depth at `nix flake check` time.
    assertions = [
      {
        assertion = lib.hasInfix "@sha256:" config.virtualisation.oci-containers.containers.langfuse-web.image;
        message = "modules/mcp-audit.nix: langfuse-web image must be @sha256:... digest-pinned (D-06)";
      }
      {
        assertion = lib.hasInfix "@sha256:" config.virtualisation.oci-containers.containers.langfuse-worker.image;
        message = "modules/mcp-audit.nix: langfuse-worker image must be @sha256:... digest-pinned (D-06)";
      }
    ];

    sops.secrets."langfuse-web-env" = {
      key = "langfuse_web_env";
      path = "/run/secrets/langfuse-web-env";
      owner = "root";
      group = "root";
      mode = "0400";
    };
    sops.secrets."langfuse-worker-env" = {
      key = "langfuse_worker_env";
      path = "/run/secrets/langfuse-worker-env";
      owner = "root";
      group = "root";
      mode = "0400";
    };

    # ---------------------------------------------------------------------
    # 5. langfuse-nats-ingest Python service (D-08, FOUND-07 hardening)
    # ---------------------------------------------------------------------
    users.users.langfuse-ingest = {
      isSystemUser = true;
      group = "langfuse-ingest";
      description = "langfuse-nats-ingest (audit.otlp.> -> Langfuse OTLP)";
    };
    users.groups.langfuse-ingest = { };

    sops.secrets."langfuse-ingest-env" = {
      key = "langfuse_ingest_env";
      path = "/run/secrets/langfuse-ingest-env";
      owner = "langfuse-ingest";
      group = "langfuse-ingest";
      mode = "0400";
    };
    sops.secrets."nats-ingest-creds" = {
      key = "nats_ingest_creds";
      path = "/run/secrets/nats-ingest.creds";
      owner = "langfuse-ingest";
      group = "langfuse-ingest";
      mode = "0400";
    };

    systemd.services.langfuse-nats-ingest = {
      description = "NATS audit.otlp.> -> Langfuse OTLP";
      wantedBy = [ "multi-user.target" ];
      after = [
        "podman-langfuse-web.service"
        "network-online.target"
        "nats-jwt-sync.service"
      ];
      wants = [
        "podman-langfuse-web.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "5s";
        User = "langfuse-ingest";
        Group = "langfuse-ingest";
        EnvironmentFile = config.sops.secrets.langfuse-ingest-env.path;
        ExecStart = "${inputs.self.packages.${pkgs.system}.langfuse-nats-ingest}/bin/langfuse-nats-ingest";
        # FOUND-07 hardening (CONTEXT §Claude's Discretion -- baseline early).
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };

    # ---------------------------------------------------------------------
    # 6. ClickHouse TTL oneshot + weekly re-apply (D-09, Q5 resolution)
    # ---------------------------------------------------------------------
    systemd.services.clickhouse-langfuse-ttl = {
      description = "Apply Langfuse ClickHouse TTL DDL (D-09)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "clickhouse.service"
        "podman-langfuse-web.service"
        "clickhouse-langfuse-user.service"
      ];
      wants = [ "podman-langfuse-web.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "clickhouse";
        Group = "clickhouse";
        ExecStartPre = waitForLangfuseWeb;
        ExecStart = applyClickhouseTtls;
      };
    };

    # Q5: weekly re-apply survives Langfuse-upgrade schema mutations. The
    # ALTER TABLE ... MODIFY TTL DDL is idempotent when the target TTL
    # already matches; if Langfuse recreates a table without one, the
    # weekly run restores it. `Persistent = true` picks up missed runs.
    systemd.services.clickhouse-ttl-reapply = {
      description = "Weekly Langfuse ClickHouse TTL re-apply (Q5)";
      serviceConfig = {
        Type = "oneshot";
        User = "clickhouse";
        Group = "clickhouse";
        ExecStart = reapplyClickhouseTtls;
      };
    };
    systemd.timers.clickhouse-ttl-reapply = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        Unit = "clickhouse-ttl-reapply.service";
      };
    };

    # ---------------------------------------------------------------------
    # 7. Disk-check timer (D-10) -- 15-min cadence, journald WARN >= 70%
    # ---------------------------------------------------------------------
    systemd.services.mcp-audit-disk-check = {
      description = "mcp-audit disk utilization check (D-10)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "disk-check.sh" (
          builtins.readFile ../hosts/mcp-audit/disk-check.sh
        );
      };
    };
    systemd.timers.mcp-audit-disk-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "15m";
        Unit = "mcp-audit-disk-check.service";
      };
    };

    # ---------------------------------------------------------------------
    # 8. Vector consumer side (D-08) -- audit.journal.> -> journal-remote
    # ---------------------------------------------------------------------
    # vector-audit-client.nix (imported by the host) already declares the
    # publish-side (opentelemetry/journald -> NATS). NixOS module merging
    # composes these additional source+sink entries into the same Vector
    # settings attrset. One Vector instance, both roles.
    services.vector.settings.sources.nats_journal_consumer = {
      type = "nats";
      url = "tls://mcp-nats01.samesies.gay:4222,tls://mcp-nats02.samesies.gay:4222,tls://mcp-nats03.samesies.gay:4222";
      subject = "audit.journal.>";
      queue = "audit-journal-consumer";
      jetstream.enabled = true;
      jetstream.stream = "AUDIT_JOURNAL";
      acknowledgements.enabled = true;
      auth.strategy = "credentials_file";
      auth.credentials_file.path = "/run/secrets/nats-client.creds";
      tls.enabled = true;
      tls.ca_file = "/run/secrets/step-ca-root";
      tls.crt_file = "/run/vector-certs/client.crt";
      tls.key_file = "/run/vector-certs/client.key";
      decoding.codec = "json";
    };
    services.vector.settings.sinks.journal_remote_files = {
      type = "file";
      inputs = [ "nats_journal_consumer" ];
      path = "/var/log/journal/remote/{{ .host_fields.service_name | default: 'unknown' }}/messages.%Y-%m-%d.log";
      encoding.codec = "json";
      acknowledgements.enabled = true;
    };
    systemd.tmpfiles.settings."30-journal-remote"."/var/log/journal/remote".d = {
      user = "vector";
      group = "vector";
      mode = "0750";
    };

    # ---------------------------------------------------------------------
    # 9. PBS exclude list extension (D-12) -- audit-specific scratch dirs
    # ---------------------------------------------------------------------
    # Default eight (FOUND-06) + Langfuse/Postgres/Podman scratch.
    services.mcpAuditPbs.excludePaths = [
      "/run"
      "/var/run"
      "/proc"
      "/sys"
      "/dev"
      "/tmp"
      "/var/cache"
      "/run/secrets"
      "/var/lib/podman/tmp"
      "/var/lib/postgresql/17/pg_stat_tmp"
      "/var/lib/clickhouse/tmp"
    ];
  };
}
