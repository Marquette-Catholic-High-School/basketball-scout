"""FastAPI application: JSON API under /api, static frontend pages, basic auth.

Run with ``uvicorn scout.main:app`` (systemd: ``basketball-scout-web.service``).
"""

from __future__ import annotations

from fastapi import FastAPI

from scout.config import Settings


def create_app(settings: Settings | None = None) -> FastAPI:
    raise NotImplementedError


def run() -> None:
    """Console entry point: uvicorn with host/port from settings."""
    raise NotImplementedError
