# pkgs/langfuse-nats-ingest/default.nix
# Source: .planning/phases/01-audit-substrate/01-CONTEXT.md D-08
# Source: https://nixos.org/manual/nixpkgs/stable/#python (buildPythonApplication)
#
# Nix derivation exposing the langfuse-nats-ingest console script via
# flake.packages.${system}.langfuse-nats-ingest. Consumed by
# modules/mcp-audit.nix as `${inputs.self.packages.${pkgs.system}.langfuse-nats-ingest}/bin/langfuse-nats-ingest`.
{ python3Packages }:

python3Packages.buildPythonApplication {
  pname = "langfuse-nats-ingest";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ python3Packages.setuptools ];

  dependencies = with python3Packages; [
    nats-py
    httpx
  ];

  # No test suite in-tree; flake-check `otlp-roundtrip-placeholder.nix`
  # exercises the wire format via tests/fixtures/sample-gen-ai-span.bin.
  doCheck = false;

  meta = {
    description = "NATS JetStream audit.otlp.> -> Langfuse OTLP bridge";
    mainProgram = "langfuse-nats-ingest";
  };
}
