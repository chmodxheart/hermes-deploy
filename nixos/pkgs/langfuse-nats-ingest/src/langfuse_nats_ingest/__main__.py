# pkgs/langfuse-nats-ingest/src/langfuse_nats_ingest/__main__.py
# Source: .planning/phases/01-audit-substrate/01-RESEARCH.md
#         §Code Examples Common Operation 2 (D-08 verbatim body)
# Source: https://github.com/nats-io/nats.py (JetStream pull subscribe)
# Source: https://langfuse.com/self-hosting/deployment/infrastructure/containers
#         (OTLP /api/public/otel/v1/traces)
#
# Pull messages off NATS audit.otlp.> and POST to Langfuse OTLP.
# Runs on mcp-audit as a single systemd service (nats-py + httpx).
#
# Invariants:
# - Connect to the cluster using JWT+NKey creds from /run/secrets/nats-ingest.creds
# - Durable pull consumer on stream AUDIT_OTLP, filter subject "audit.otlp.>"
# - POST message bodies to http://127.0.0.1:3000/api/public/otel/v1/traces
# - Ack only after 2xx from Langfuse; nak with redelivery backoff on 5xx.
import asyncio
import base64
import os
import ssl
import sys

import httpx
import nats
from nats.js.api import AckPolicy, ConsumerConfig

LANGFUSE_OTLP = "http://127.0.0.1:3000/api/public/otel/v1/traces"


def _headers() -> dict[str, str]:
    pk = os.environ["LANGFUSE_PUBLIC_KEY"]
    sk = os.environ["LANGFUSE_SECRET_KEY"]
    auth = base64.b64encode(f"{pk}:{sk}".encode()).decode()
    return {
        "Authorization": f"Basic {auth}",
        "Content-Type": "application/x-protobuf",
        "x-langfuse-ingestion-version": "4",
    }


async def _main() -> None:
    ssl_ctx = ssl.create_default_context(purpose=ssl.Purpose.SERVER_AUTH)
    ssl_ctx.load_verify_locations("/run/secrets/step-ca-root")
    nc = await nats.connect(
        servers=[
            "tls://mcp-nats-1.samesies.gay:4222",
            "tls://mcp-nats-2.samesies.gay:4222",
            "tls://mcp-nats-3.samesies.gay:4222",
        ],
        user_credentials="/run/secrets/nats-ingest.creds",
        tls=ssl_ctx,
    )
    js = nc.jetstream()
    psub = await js.pull_subscribe(
        subject="audit.otlp.>",
        durable="langfuse-nats-ingest",
        stream="AUDIT_OTLP",
        config=ConsumerConfig(
            ack_policy=AckPolicy.EXPLICIT, max_deliver=5, ack_wait=60
        ),
    )
    headers = _headers()
    async with httpx.AsyncClient(timeout=10.0) as http:
        while True:
            try:
                msgs = await psub.fetch(batch=50, timeout=5.0, heartbeat=2.0)
            except asyncio.TimeoutError:
                continue
            for m in msgs:
                try:
                    r = await http.post(LANGFUSE_OTLP, content=m.data, headers=headers)
                    if 200 <= r.status_code < 300:
                        await m.ack()
                    else:
                        delay = min(2 ** (m.metadata.num_delivered - 1), 60)
                        await m.nak(delay=delay)
                except Exception as e:
                    print(f"ingest error: {e}", file=sys.stderr, flush=True)
                    await m.nak(delay=10)


def run() -> None:
    asyncio.run(_main())


if __name__ == "__main__":
    run()
