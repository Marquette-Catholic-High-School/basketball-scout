"""HTTP layer: JSON API routers (all under ``/api``) and the HTML page routes.

One module per area; the route table is in docs/ARCHITECTURE.md ("HTTP API").
"""

from __future__ import annotations

from fastapi import APIRouter

from scout.api import exports, games, jobs, media, reports, rosters, system, tracks, uploads


def build_api_router() -> APIRouter:
    router = APIRouter(prefix="/api")
    for module in (system, games, uploads, jobs, media, rosters, tracks, exports, reports):
        router.include_router(module.router)
    return router
