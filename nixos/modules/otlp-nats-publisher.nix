{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.services.mcpOtlpNatsPublisher;
  natsUrl = lib.concatStringsSep "," (map (p: "tls://${p}.samesies.gay:4222") cfg.natsPeers);
in
{
  options.services.mcpOtlpNatsPublisher = {
    enable = lib.mkEnableOption "OTLP traces to NATS publisher";

    natsPeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "mcp-nats01"
        "mcp-nats02"
        "mcp-nats03"
      ];
      description = "NATS cluster peers used by the local OTLP traces publisher.";
    };

    bindHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address for the local OTLP HTTP listener.";
    };

    bindPort = lib.mkOption {
      type = lib.types.int;
      default = 4318;
      description = "Port for the local OTLP HTTP listener.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.mcp-otlp-nats-publisher = {
      description = "Publish local OTLP traces into NATS JetStream";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "nats-jwt-sync.service"
        "vector-client-cert.service"
      ];
      requires = [
        "nats-jwt-sync.service"
        "vector-client-cert.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "5s";
        User = "vector";
        Group = "vector";
        Environment = [
          "OTLP_NATS_BIND_HOST=${cfg.bindHost}"
          "OTLP_NATS_BIND_PORT=${toString cfg.bindPort}"
          "OTLP_NATS_SUBJECT=audit.otlp.traces.${config.networking.hostName}"
          "OTLP_NATS_SERVERS=${natsUrl}"
          "OTLP_NATS_CA_FILE=/run/secrets/step-ca-root"
          "OTLP_NATS_CERT_FILE=/run/vector-certs/client.crt"
          "OTLP_NATS_KEY_FILE=/run/vector-certs/client.key"
          "OTLP_NATS_CREDS_FILE=/run/secrets/nats-client.creds"
        ];
        ExecStart = "${inputs.self.packages.${pkgs.system}.otlp-nats-publisher}/bin/otlp-nats-publisher";
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
  };
}
