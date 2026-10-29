"""Request body caps.

Without nginx in front (the default install) nothing else limits a request: FastAPI
reads a JSON body into memory, and a multipart form is spooled to a temporary file
before the roster route can look at the file's size. ``BodyLimitMiddleware`` counts the
bytes as they arrive (a chunked body has no Content-Length) and answers 413
``REQUEST_TOO_LARGE`` as soon as a body passes its cap: 4 MB for a multipart form (the
roster import, whose route then takes files up to 2 MB) and 1 MB for anything else.
GET and HEAD requests are left alone, and so are film chunks
(``PUT /api/uploads/{id}/chunk``): they stream to disk, and the route caps each one at
the upload's remaining size and twice its chunk size.
"""

from __future__ import annotations

import logging
import re

from starlette.datastructures import Headers
from starlette.responses import Response
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from scout.api.errors import error_response
from scout.errors import ErrorCode, ScoutError

logger = logging.getLogger(__name__)

MB = 1024 * 1024
MAX_BODY_BYTES = 1 * MB  # JSON, and anything else that is not a multipart form
MAX_MULTIPART_BODY_BYTES = 4 * MB
_UNCAPPED_METHODS = frozenset({"GET", "HEAD"})
_CHUNK_PATH = re.compile(r"/api/uploads/[^/]+/chunk")


class BodyLimitMiddleware:
    """Pure ASGI middleware, so a film chunk still streams straight through to its route."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        method = scope.get("method", "GET")
        if scope["type"] != "http" or method in _UNCAPPED_METHODS or _is_chunk_upload(method, scope):
            await self.app(scope, receive, send)
            return
        headers = Headers(scope=scope)
        limit = _body_limit(headers.get("content-type", ""))
        length = headers.get("content-length", "").strip()
        if length.isascii() and length.isdigit() and int(length) > limit:  # fail early, before reading
            await _refuse(scope, limit)(scope, receive, send)
            return
        received = 0
        cut_off = False  # the body passed the cap: the app gets no more of it
        answered = False  # ...and the 413 was sent, so whatever the app answers is dropped
        started = False

        async def counting_receive() -> Message:
            nonlocal received, cut_off, answered
            if cut_off:
                return {"type": "http.disconnect"}
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > limit:
                    cut_off = True
                    if not started:
                        answered = True
                        await _refuse(scope, limit)(scope, receive, send)
                    # The app sees the client go away; uvicorn discards the rest of the body.
                    return {"type": "http.disconnect"}
            return message

        async def guarded_send(message: Message) -> None:
            nonlocal started
            if answered:
                return
            if message["type"] == "http.response.start":
                started = True
            await send(message)

        await self.app(scope, counting_receive, guarded_send)


def _body_limit(content_type: str) -> int:
    """Most bytes a request body with this ``Content-Type`` may have."""
    media_type = content_type.split(";", 1)[0].strip().lower()
    return MAX_MULTIPART_BODY_BYTES if media_type == "multipart/form-data" else MAX_BODY_BYTES


def _is_chunk_upload(method: str, scope: Scope) -> bool:
    return method == "PUT" and _CHUNK_PATH.fullmatch(scope.get("path", "")) is not None


def _refuse(scope: Scope, limit: int) -> Response:
    logger.warning("Refused a %s %s: the body is over %d bytes", scope.get("method"), scope.get("path"), limit)
    error = ScoutError(ErrorCode.REQUEST_TOO_LARGE, f"The request was larger than this server accepts ({limit // MB} MB).")
    return error_response(error.to_info(), error.http_status)
