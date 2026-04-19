{ python3Packages }:

python3Packages.buildPythonApplication {
  pname = "otlp-nats-publisher";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ python3Packages.setuptools ];

  dependencies = with python3Packages; [
    aiohttp
    nats-py
  ];

  doCheck = false;

  meta = {
    description = "Receive OTLP traces over HTTP and publish raw protobuf bytes to NATS";
    mainProgram = "otlp-nats-publisher";
  };
}
