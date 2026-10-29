"""Health checks and court geometry for the calibration UI."""

from __future__ import annotations

import dataclasses
import logging
import shutil
import time
from typing import Any

from fastapi import APIRouter

from scout import __version__, db
from scout.analysis import geometry
from scout.api.deps import SettingsDep
from scout.jobs import queue as job_queue
from scout.schemas import HealthStatus

logger = logging.getLogger(__name__)

WORKER_STALE_AFTER_S = 120.0

router = APIRouter(tags=["system"])


# HEAD has a route of its own, so the OpenAPI operation ids stay unique. The GET route comes first (the
# lower decorator registers first): a 405 on this path names the methods of the first route.
@router.head("/health/live")
@router.get("/health/live")
def live() -> dict[str, str]:
    """Liveness probe (no auth, no database): the web process is up.

    Also answers HEAD, which several hosted uptime monitors send: the same headers as GET,
    and the server (uvicorn) leaves out the body.
    """
    return {"status": "ok"}


@router.get("/health", response_model=HealthStatus)
def health(settings: SettingsDep) -> HealthStatus:
    """What works and what does not; ``status`` is "degraded" when jobs cannot run."""
    queue_ok = _queue_ok()
    last_seen = db.last_worker_heartbeat()
    worker_age = round(time.time() - last_seen, 1) if last_seen is not None else None
    degraded = (
        not queue_ok
        or worker_age is None
        or worker_age > WORKER_STALE_AFTER_S
        or (settings.processor == "modal" and not settings.modal_configured)
    )
    return HealthStatus(
        status="degraded" if degraded else "ok",
        version=__version__,
        processor=settings.processor,
        queue_backend=settings.queue_backend,
        queue_ok=queue_ok,
        modal_configured=settings.modal_configured,
        claude_configured=settings.claude_configured,
        ffmpeg_available=shutil.which("ffmpeg") is not None,
        worker_last_seen_s=worker_age,
        auth_enabled=settings.auth_enabled,
        max_upload_bytes=settings.max_upload_bytes,
    )


def _queue_ok() -> bool:
    try:
        return bool(job_queue.get_queue().ping())
    except Exception:  # noqa: BLE001 - any failure means "queue down" on the health page
        logger.warning("Job queue ping failed", exc_info=True)
        return False


@router.get("/court/landmarks")
def court_landmarks(settings: SettingsDep) -> dict[str, Any]:
    """Court dimensions and the named floor points a coach can click to calibrate."""
    cfg = geometry.load_court_config(settings.court_config)
    return {
        "court": dataclasses.asdict(cfg),
        "landmarks": {name: [x, y] for name, (x, y) in geometry.landmarks(cfg).items()},
    }
