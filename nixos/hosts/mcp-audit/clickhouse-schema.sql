-- hosts/mcp-audit/clickhouse-schema.sql
-- Source: https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree#table_engine-mergetree-ttl
-- Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-09
-- Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Code Examples Common Operation 1
--
-- Apply once after Langfuse v3 schema migrations complete; re-apply idempotent.
-- `ALTER TABLE ... MODIFY TTL` is a metadata-only op when the target TTL already
-- matches -- safe to re-run weekly via `clickhouse-ttl-reapply.timer` (Q5).

ALTER TABLE traces       MODIFY TTL toDateTime(created_at) + INTERVAL 90  DAY DELETE;
ALTER TABLE observations MODIFY TTL toDateTime(created_at) + INTERVAL 90  DAY DELETE;
ALTER TABLE scores       MODIFY TTL toDateTime(created_at) + INTERVAL 365 DAY DELETE;
ALTER TABLE event_log    MODIFY TTL toDateTime(created_at) + INTERVAL 30  DAY DELETE;

-- Hygiene on ClickHouse's own log tables (7 days).
ALTER TABLE system.query_log  MODIFY TTL toDateTime(event_time) + INTERVAL 7 DAY DELETE;
ALTER TABLE system.metric_log MODIFY TTL toDateTime(event_time) + INTERVAL 7 DAY DELETE;
ALTER TABLE system.trace_log  MODIFY TTL toDateTime(event_time) + INTERVAL 7 DAY DELETE;
ALTER TABLE system.text_log   MODIFY TTL toDateTime(event_time) + INTERVAL 7 DAY DELETE;
