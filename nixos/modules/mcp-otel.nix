# modules/mcp-otel.nix
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-14
# Source: opentelemetry.io/docs/specs/semconv/gen-ai/
#
# Shared OTel SDK env block. Imported by mcp-audit (for its own service
# spans), every mcp-nats-*, and every MCP/gateway LXC landing in Phase 2+.
# D-14 note: single-consumer-and-self exception to the three-consumers-
# before-abstracting rule, justified by zero-logic nature (pure env vars).
#
# OTLP endpoint is Vector's local receiver (D-07). Vector spools to JetStream;
# NATS transports to mcp-audit; langfuse-nats-ingest delivers to Langfuse.
{ config, lib, ... }:
{
  environment.sessionVariables = {
    OTEL_SEMCONV_STABILITY_OPT_IN = "gen_ai_latest_experimental";
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true";
    OTEL_RESOURCE_ATTRIBUTES = "service.namespace=mcp,service.name=${config.networking.hostName},deployment.environment=prod";
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://127.0.0.1:4318";
    OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf";
  };
}
