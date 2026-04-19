import os
import ssl

from aiohttp import web
import nats


async def _publish_trace(request: web.Request) -> web.Response:
    body = await request.read()
    if not body:
        return web.Response(status=400, text="empty OTLP trace request body")

    await request.app["jetstream"].publish(request.app["subject"], body)
    return web.Response(status=202)


async def _unsupported_signal(_request: web.Request) -> web.Response:
    return web.Response(status=501, text="only OTLP traces are supported")


async def _health(_request: web.Request) -> web.Response:
    return web.Response(status=200, text="ok")


async def _connect_nats(app: web.Application) -> None:
    ssl_ctx = ssl.create_default_context(purpose=ssl.Purpose.SERVER_AUTH)
    ssl_ctx.load_verify_locations(app["ca_file"])
    ssl_ctx.load_cert_chain(app["cert_file"], app["key_file"])
    nc = await nats.connect(
        servers=app["servers"],
        user_credentials=app["creds_file"],
        tls=ssl_ctx,
    )
    app["nats"] = nc
    app["jetstream"] = nc.jetstream()


async def _disconnect_nats(app: web.Application) -> None:
    await app["nats"].drain()


def _build_app() -> web.Application:
    app = web.Application()
    app["bind_host"] = os.environ.get("OTLP_NATS_BIND_HOST", "127.0.0.1")
    app["bind_port"] = int(os.environ.get("OTLP_NATS_BIND_PORT", "4318"))
    app["subject"] = os.environ["OTLP_NATS_SUBJECT"]
    app["servers"] = [s for s in os.environ["OTLP_NATS_SERVERS"].split(",") if s]
    app["ca_file"] = os.environ["OTLP_NATS_CA_FILE"]
    app["cert_file"] = os.environ["OTLP_NATS_CERT_FILE"]
    app["key_file"] = os.environ["OTLP_NATS_KEY_FILE"]
    app["creds_file"] = os.environ["OTLP_NATS_CREDS_FILE"]
    app.on_startup.append(_connect_nats)
    app.on_cleanup.append(_disconnect_nats)
    app.router.add_get("/healthz", _health)
    app.router.add_post("/v1/traces", _publish_trace)
    app.router.add_post("/v1/logs", _unsupported_signal)
    app.router.add_post("/v1/metrics", _unsupported_signal)
    return app


def run() -> None:
    app = _build_app()
    web.run_app(app, host=app["bind_host"], port=app["bind_port"])


if __name__ == "__main__":
    run()
