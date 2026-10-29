"""FastAPI application: JSON API under /api, static frontend pages, basic auth.

Run with ``uvicorn scout.main:app`` or the ``scout-web`` console script
(systemd: ``basketball-scout-web.service``). Importing this module only builds the
app object; the data directories and database are set up when the server starts.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from scout import __version__, db
from scout.api import build_api_router
from scout.api.errors import install_error_handlers
from scout.api.pages import mount_static
from scout.api.pages import router as pages_router
from scout.auth import BasicAuthMiddleware, SameOriginMiddleware, log_auth_status
from scout.config import Settings, get_settings

logger = logging.getLogger(__name__)


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build the app. No filesystem or database work happens until startup.

    ``settings`` drives auth, upload limits and the health check; ``scout.db`` and
    ``scout.storage`` always read the process-wide ``get_settings()``.
    """
    settings = settings or get_settings()

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        _configure_logging(settings.log_level)
        settings.ensure_dirs()
        db.init_db(settings.database_path)
        log_auth_status(settings)
        logger.info(
            "Basketball Scout %s ready (processor=%s, queue=%s)", __version__, settings.processor, settings.queue_backend
        )
        yield

    app = FastAPI(
        title="Basketball Scout",
        version=__version__,
        lifespan=lifespan,
        docs_url="/api/docs",
        redoc_url=None,
        openapi_url="/api/openapi.json",
    )
    app.state.settings = settings
    install_error_handlers(app)
    app.include_router(build_api_router())
    app.include_router(pages_router)
    mount_static(app)
    app.add_middleware(BasicAuthMiddleware, settings=settings)
    # Added last = runs first: a cross-site change is refused before sign-in is checked.
    app.add_middleware(SameOriginMiddleware)
    return app


def run() -> None:
    """Console entry point: uvicorn with host/port/log level from settings."""
    import uvicorn

    settings = get_settings()
    uvicorn.run(
        app,
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level.lower(),
        proxy_headers=True,
        forwarded_allow_ips="127.0.0.1",
    )


def _configure_logging(level: str) -> None:
    """Send our loggers to stderr (journalctl) unless the host already configured logging."""
    if not logging.getLogger().handlers:
        logging.basicConfig(level=level.upper(), format="%(asctime)s %(levelname)s [%(name)s] %(message)s")


app = create_app()

if __name__ == "__main__":
    run()
