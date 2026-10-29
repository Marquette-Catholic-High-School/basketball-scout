"""HTML pages and the /static mount.

The pages are plain files in ``scout/static``; the JavaScript on each page calls the
JSON API (so ``/games/<id>`` is served even for an unknown id and the page shows the
404). Everything is sent with ``Cache-Control: no-cache`` so browsers re-check the
files after an update instead of running stale JavaScript.
"""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import APIRouter, FastAPI
from fastapi.responses import FileResponse, HTMLResponse, Response
from starlette.staticfiles import StaticFiles
from starlette.types import Scope

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"
NO_CACHE = {"Cache-Control": "no-cache"}
# Pages may only be framed by this site: stops another site from showing them in an
# invisible frame and tricking the coach into clicking "Delete" (nginx is optional).
PAGE_HEADERS = {**NO_CACHE, "Content-Security-Policy": "frame-ancestors 'self'"}

_PLACEHOLDER = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Basketball Scout</title></head>
<body style="font-family: sans-serif; max-width: 40rem; margin: 3rem auto;">
<h1>Basketball Scout</h1>
<p>This page ({name}) is not installed on the server yet.</p>
<p>Ask the administrator to run <code>scripts/update.sh</code>.</p>
</body></html>
"""

router = APIRouter(include_in_schema=False)


class NoCacheStaticFiles(StaticFiles):
    """StaticFiles that asks browsers to revalidate (ETag / Last-Modified) every time."""

    def file_response(
        self, full_path: str | os.PathLike[str], stat_result: os.stat_result, scope: Scope, status_code: int = 200
    ) -> Response:
        response = super().file_response(full_path, stat_result, scope, status_code)
        response.headers.update(PAGE_HEADERS)  # the pages are reachable here too (/static/index.html)
        return response


def mount_static(app: FastAPI) -> None:
    app.mount("/static", NoCacheStaticFiles(directory=STATIC_DIR, check_dir=False), name="static")


def page(name: str) -> Response:
    """Serve ``scout/static/<name>``, or a small 503 placeholder when it is missing."""
    path = STATIC_DIR / name
    if not path.is_file():
        return HTMLResponse(_PLACEHOLDER.format(name=name), status_code=503, headers=PAGE_HEADERS)
    return FileResponse(path, media_type="text/html", headers=PAGE_HEADERS)


@router.get("/")
def games_page() -> Response:
    return page("index.html")


@router.get("/upload")
def upload_page() -> Response:
    return page("upload.html")


@router.get("/games/{game_id}")
def game_page(game_id: str) -> Response:
    return page("game.html")


@router.get("/games/{game_id}/roster")
def roster_page(game_id: str) -> Response:
    return page("roster.html")
