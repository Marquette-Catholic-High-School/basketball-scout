"""Error handlers: every failure leaves the server as ``{"error": ErrorInfo}``."""

from __future__ import annotations

import logging
from collections.abc import Sequence
from typing import Any, TypeVar

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException

from scout.errors import ErrorCode, ScoutError, http_status_for
from scout.schemas import ErrorInfo

logger = logging.getLogger(__name__)

M = TypeVar("M", bound=BaseModel)
_LOCATIONS = ("body", "query", "path", "header", "cookie")


def install_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(ScoutError, _scout_error)
    app.add_exception_handler(RequestValidationError, _validation_error)
    app.add_exception_handler(StarletteHTTPException, _http_error)
    app.add_exception_handler(Exception, _unexpected_error)


def error_response(info: ErrorInfo, status_code: int, headers: dict[str, str] | None = None, **extra: Any) -> JSONResponse:
    """JSON error body; ``extra`` adds sibling keys (e.g. the current upload session)."""
    return JSONResponse({"error": info.model_dump(), **extra}, status_code=status_code, headers=headers)


def describe_validation_errors(errors: Sequence[Any]) -> str:
    """Pydantic errors -> ``"scouted_team: Field required; players[0].jersey: ..."``."""
    parts = []
    for err in errors:
        if err.get("type") == "json_invalid":  # loc holds a character offset, not a field
            parts.append(f"body: not valid JSON ({err.get('ctx', {}).get('error', 'decode error')})")
            continue
        loc = [p for p in err.get("loc", ()) if p is not None]
        where = loc[0] if loc and loc[0] in _LOCATIONS else None
        field = _format_loc(loc[1:] if where else loc) or str(where or "request")
        parts.append(f"{field}: {err.get('msg', 'invalid value')}")
    return "; ".join(parts)


def validate_model(model: type[M], data: Any) -> M:
    """Validate ``data`` built inside a route; bad input becomes a 422 like request errors."""
    try:
        return model.model_validate(data)
    except ValidationError as exc:
        raise ScoutError(ErrorCode.VALIDATION_FAILED, detail=describe_validation_errors(exc.errors())) from exc


def _format_loc(parts: Sequence[Any]) -> str:
    text = ""
    for part in parts:
        if isinstance(part, int):
            text += f"[{part}]"
        else:
            text += f".{part}" if text else str(part)
    return text


async def _scout_error(_: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, ScoutError)
    return error_response(exc.to_info(), http_status_for(exc.code))


async def _validation_error(_: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, RequestValidationError)
    info = ScoutError(ErrorCode.VALIDATION_FAILED, detail=describe_validation_errors(exc.errors())).to_info()
    return error_response(info, 422)


async def _http_error(request: Request, exc: Exception) -> JSONResponse:
    """Starlette's own errors: unknown routes (404), wrong method (405), bad multipart (400)."""
    assert isinstance(exc, StarletteHTTPException)
    if exc.status_code == 404:
        error = ScoutError(ErrorCode.NOT_FOUND, f"There is nothing at {request.url.path}.")
    elif exc.status_code < 500:
        error = ScoutError(ErrorCode.VALIDATION_FAILED, str(exc.detail))
    else:
        error = ScoutError(ErrorCode.INTERNAL_ERROR, detail=str(exc.detail))
    return error_response(error.to_info(), exc.status_code, headers=exc.headers)


async def _unexpected_error(request: Request, exc: Exception) -> JSONResponse:
    """Last resort: log the traceback, never send it to the browser."""
    logger.error("Unhandled error on %s %s", request.method, request.url.path, exc_info=exc)
    return error_response(ScoutError(ErrorCode.INTERNAL_ERROR).to_info(), 500)
