# modules/mcp-prom-exporters.nix
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-16 (exporter set)
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-17 (narrow Prom carve-out)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pattern S5 (declarative nftables)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P5 (declarative tables only)
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md §Pitfalls P7 (ClickHouse /metrics)
#
# Baseline Prometheus surface shared by every audit-plane LXC:
#   * services.prometheus.exporters.node (host metrics)
#   * nftables allow rule scoped to a single k8s-Prom source IP plus an
#     exporter port set — hosts extend exporterPorts for service-specific
#     exporters (nats-exporter 7777, postgres_exporter 9187, redis_exporter
#     9121, ClickHouse built-in /metrics 9363 — wired per-host in Plans
#     01-05 / 01-06).
#
# Decision anchors: D-17 requires a concrete source IP and a concrete port
# set — no wildcards. The assertion below fails the build if a host forgets
# to set promSourceIp (single point of enforcement for the invariant).
#
# Banned in this module (Pitfall 5 / NixOS #207058): the
# networking.firewall legacy escape-hatches and the legacy CLI shim. They
# silently flush the ruleset in certain syntax edge cases. The common.nix
# baseline already sets networking.nftables.enable = true; we just add a
# declarative table alongside.
{ config, lib, ... }:
let
  cfg = config.services.mcpPromExporters;
in
{
  options.services.mcpPromExporters = {
    enable = lib.mkEnableOption "baseline Prometheus exporters + D-17 nftables carve-out";

    promSourceIp = lib.mkOption {
      type = lib.types.str;
      description = ''
        Source IP of the k8s Prometheus scraper (Cilium egress gateway or
        the Prom-pod host IP). Required — D-17 forbids wildcards, so there
        is deliberately no default.
      '';
      example = "10.42.0.14";
    };

    exporterPorts = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [
        9100 # node_exporter (this module enables it)
        9598 # Vector prometheus_exporter sink (host wires the sink)
      ];
      description = ''
        TCP ports allowed through nftables from `promSourceIp`. Extend in
        per-host modules for service-specific exporters:
          * 7777 — nats-exporter (mcp-nats-*)
          * 9187 — postgres_exporter (mcp-audit)
          * 9121 — redis_exporter (mcp-audit)
          * 9363 — ClickHouse built-in /metrics (mcp-audit; see RESEARCH P7
            — no services.prometheus.exporters.clickhouse module exists)
      '';
    };

    vectorExporterPort = lib.mkOption {
      type = lib.types.int;
      default = 9598;
      description = ''
        Port the Vector prometheus_exporter sink binds on the LXC IP (NOT
        127.0.0.1 — per RESEARCH Pitfall 6, Prometheus must reach it from
        outside). The host module wires the actual Vector sink config; this
        option exists so it stays consistent with exporterPorts.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # D-17 enforcement: a missing source IP is a wildcard by default; fail
    # the build loudly. Plan 01-07 populates a second-layer flake-check
    # that greps the rendered ruleset for 0.0.0.0/0.
    assertions = [
      {
        assertion = cfg.promSourceIp != "";
        message = ''
          services.mcpPromExporters.promSourceIp must be set (D-17 requires
          a concrete source IP — no wildcards).
        '';
      }
    ];

    # Skip the upstream module's auto-opened firewall port: common.nix's
    # stock firewall sits on the legacy compat layer and would drop 9100.
    # The declarative nftables table below re-allows 9100 from
    # promSourceIp only.
    services.prometheus.exporters.node = {
      enable = true;
      openFirewall = false;
      listenAddress = "0.0.0.0";
      port = 9100;
    };

    # Declarative per-table config per Pitfall 5 / FOUND-03. Rendered chain
    # (with exporterPorts = [9100 9598 7777] and promSourceIp = "10.42.0.14"):
    #   chain input {
    #     type filter hook input priority 0;
    #     ip saddr 10.42.0.14 tcp dport { 9100, 9598, 7777 } accept
    #   }
    networking.nftables.tables.prom-scrape = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority filter;
          ip saddr ${cfg.promSourceIp} tcp dport { ${lib.concatStringsSep ", " (map toString cfg.exporterPorts)} } accept
        }
      '';
    };
  };
}
