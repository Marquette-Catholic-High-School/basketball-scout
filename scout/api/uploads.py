"""Film: resumable chunked uploads and video links.

Upload protocol (the browser sends a multi-GB film in pieces):

1. ``POST /api/games/{id}/uploads`` with ``{"filename", "size"}`` -> session with
   ``chunk_size``; an empty ``data/uploads/<upload_id>.part`` file is created.
2. ``PUT /api/uploads/{upload_id}/chunk?offset=N`` with raw bytes, N = bytes already
   received. A wrong offset gets 409 plus the current session so the client can resume
   from ``upload.received`` (also available from ``GET /api/uploads/{upload_id}``).
3. ``POST /api/uploads/{upload_id}/complete`` checks the size and the MP4/MOV header,
   makes the file the game's film, deletes results derived from the old film and
   (unless ``auto_start=false``) queues the analysis.
"""

from __future__ import annotations

import asyncio
import errno
import logging
import shutil
import subprocess
import unicodedata
from contextlib import suppress
from datetime import timedelta
from pathlib import Path
from typing import Annotated
from urllib.parse import ParseResult, unquote, urlparse

import anyio
from fastapi import APIRouter, Query, Request
from fastapi.responses import JSONResponse, Response
from starlette.concurrency import run_in_threadpool
from starlette.requests import ClientDisconnect

from scout import db, storage
from scout.api.deps import CurrentGame, SettingsDep, UploadId
from scout.api.errors import error_response
from scout.api.jobs import ensure_no_active_job, start_job, start_lock
from scout.api.models import FilmResult
from scout.config import Settings
from scout.errors import ErrorCode, ScoutError
from scout.schemas import Game, GameStatus, JobKind, UploadInit, UploadSession, VideoUrlRequest

logger = logging.getLogger(__name__)

# Bytes 4-8 of an MP4/MOV file are the type of its first box.
CONTAINER_BOXES = (b"ftyp", b"moov", b"mdat", b"wide", b"free", b"skip")
DISK_HEADROOM_BYTES = 1024**3  # keep 1 GB free for the database, results and logs
FFPROBE_TIMEOUT_S = 60
# uvicorn has no request-body timeout, so a connection that died silently (school Wi-Fi
# dropped) would hold the upload's lock, and hang every resume, until a restart.
CHUNK_IDLE_TIMEOUT_S = 120.0
# An unfinished upload of the same game with no data for this long was given up (the
# browser only remembers its latest upload per game); its .part file is deleted.
ABANDONED_UPLOAD_S = 3600.0
MAX_FILENAME_CHARS = 255  # as UploadInit and VideoUrlRequest allow
MAX_EXTENSION_CHARS = 10  # ".mp4", ".webm", ".m2ts"

router = APIRouter(tags=["uploads"])

# One lock per upload so a retried chunk cannot interleave with one still in flight.
_upload_locks: dict[str, asyncio.Lock] = {}


def _lock(upload_id: str) -> asyncio.Lock:
    return _upload_locks.setdefault(upload_id, asyncio.Lock())


# ---------------------------------------------------------------------------
# Chunked uploads
# ---------------------------------------------------------------------------


@router.post("/games/{game_id}/uploads", response_model=UploadSession, status_code=201)
def create_upload(body: UploadInit, game: CurrentGame, settings: SettingsDep) -> UploadSession:
    filename = _clean_filename(body.filename)
    if Path(filename).suffix.lower() not in storage.VIDEO_EXTENSIONS:
        raise ScoutError(ErrorCode.VIDEO_INVALID, f"{filename!r} is not an MP4, MOV or M4V file.")
    if body.size > settings.max_upload_bytes:
        raise ScoutError(
            ErrorCode.UPLOAD_TOO_LARGE,
            f"This file is {_human_size(body.size)}; the limit is {_human_size(settings.max_upload_bytes)}.",
        )
    ensure_no_active_job(game.id, JobKind.ANALYZE)
    _discard_unfinished_uploads(game.id, idle_s=ABANDONED_UPLOAD_S)  # before the free-space check
    upload = UploadSession(game_id=game.id, filename=filename, size=body.size, chunk_size=settings.upload_chunk_bytes)
    part = storage.upload_part_path(upload.id)
    part.parent.mkdir(parents=True, exist_ok=True)
    _check_free_space(part.parent, body.size)
    part.write_bytes(b"")
    logger.info("Upload %s started for game %s: %s (%d bytes)", upload.id, game.id, filename, body.size)
    return db.save_upload(upload)


@router.get("/uploads/{upload_id}", response_model=UploadSession)
def get_upload(upload_id: UploadId) -> UploadSession:
    return _require_upload(upload_id)


@router.put("/uploads/{upload_id}/chunk", response_model=UploadSession)
async def upload_chunk(
    request: Request, upload_id: UploadId, offset: Annotated[int, Query(ge=0)]
) -> UploadSession | Response:
    """Append raw bytes at ``offset`` (which must equal ``received``)."""
    async with _lock(upload_id):
        upload = await run_in_threadpool(_require_open_upload, upload_id)
        if offset != upload.received:
            return _offset_conflict(upload, offset)
        limit = _chunk_limit(upload, offset, request.headers.get("content-length"))
        try:
            written = await _write_chunk(request, upload, offset, limit)
        except ClientDisconnect:
            logger.info("Upload %s: browser disconnected during the chunk at offset %d", upload_id, offset)
            return Response(status_code=400)
        except TimeoutError:  # before OSError: TimeoutError is one
            logger.info("Upload %s: no data for %.0f s in the chunk at offset %d", upload_id, CHUNK_IDLE_TIMEOUT_S, offset)
            error = ScoutError(
                ErrorCode.UPLOAD_INCOMPLETE,
                "The connection went quiet, so this piece of the film was dropped.",
                hint="Check the network connection; the upload resumes where it stopped.",
            )
            return error_response(error.to_info(), 409, upload=upload.model_dump(mode="json"))
        except OSError as exc:
            if exc.errno not in (errno.ENOSPC, errno.EDQUOT):
                raise
            raise ScoutError(
                ErrorCode.UPLOAD_TOO_LARGE,
                "The server ran out of disk space while saving the film.",
                hint="Delete old games to free up space (or ask the administrator to enlarge the disk), then resume.",
            ) from exc
        return await run_in_threadpool(db.save_upload, upload.model_copy(update={"received": offset + written}))


@router.post("/uploads/{upload_id}/complete", response_model=FilmResult)
async def complete_upload(upload_id: UploadId, settings: SettingsDep, auto_start: bool = True) -> FilmResult:
    async with _lock(upload_id):
        result = await run_in_threadpool(_finish_upload, upload_id, settings, auto_start)
    _upload_locks.pop(upload_id, None)
    return result


@router.delete("/uploads/{upload_id}", status_code=204)
async def delete_upload(upload_id: UploadId) -> Response:
    async with _lock(upload_id):
        await run_in_threadpool(_discard_upload, upload_id)
    _upload_locks.pop(upload_id, None)
    return Response(status_code=204)


def _require_upload(upload_id: str) -> UploadSession:
    upload = db.get_upload(upload_id)
    if upload is None:
        raise ScoutError(ErrorCode.UPLOAD_NOT_FOUND)
    return upload


def _require_open_upload(upload_id: str) -> UploadSession:
    """The session, if it still accepts chunks and its .part file is on disk."""
    upload = _require_upload(upload_id)
    if upload.status != "open":
        raise ScoutError(ErrorCode.CONFLICT, f"This upload is already {upload.status}.", hint="Start a new upload.")
    if not storage.upload_part_path(upload.id).is_file():
        _abort(upload)
        raise ScoutError(
            ErrorCode.UPLOAD_NOT_FOUND, "The partly uploaded file is no longer on the server.", hint="Start the upload again."
        )
    return upload


def _offset_conflict(upload: UploadSession, offset: int) -> JSONResponse:
    error = ScoutError(
        ErrorCode.CONFLICT,
        f"The server has {upload.received} bytes of this upload, but the chunk starts at byte {offset}.",
        hint="Resume from upload.received.",
    )
    return error_response(error.to_info(), 409, upload=upload.model_dump(mode="json"))


def _chunk_limit(upload: UploadSession, offset: int, content_length: str | None) -> int:
    """Most bytes this request may carry; fails early when Content-Length is already too big."""
    limit = min(2 * upload.chunk_size, upload.size - offset)
    if content_length is not None and content_length.isdigit() and int(content_length) > limit:
        raise _chunk_too_big(upload, offset, int(content_length))
    return limit


def _chunk_too_big(upload: UploadSession, offset: int, length: int) -> ScoutError:
    if offset + length > upload.size:
        return ScoutError(
            ErrorCode.UPLOAD_TOO_LARGE,
            f"This chunk goes past the end of the file ({upload.size} bytes were announced).",
            hint="Start the upload again.",
        )
    return ScoutError(
        ErrorCode.UPLOAD_TOO_LARGE,
        f"Chunks may be at most {2 * upload.chunk_size} bytes.",
        hint=f"Send chunks of {upload.chunk_size} bytes.",
    )


async def _write_chunk(request: Request, upload: UploadSession, offset: int, limit: int) -> int:
    """Stream the request body into the .part file at ``offset``; returns bytes written.

    On any failure the file is cut back to ``offset`` so the retry starts clean. Raises
    ``TimeoutError`` when no bytes arrive for ``CHUNK_IDLE_TIMEOUT_S``.
    """
    part = storage.upload_part_path(upload.id)
    written = 0
    pieces = request.stream()
    try:
        async with await anyio.open_file(part, "r+b") as fh:
            await fh.truncate(offset)
            await fh.seek(offset)
            while True:
                with anyio.fail_after(CHUNK_IDLE_TIMEOUT_S):
                    piece = await anext(pieces, None)
                if piece is None:
                    break
                written += len(piece)
                if written > limit:
                    raise _chunk_too_big(upload, offset, written)
                await fh.write(piece)
    except BaseException:
        _truncate(part, offset)
        raise
    return written


def _truncate(path: Path, size: int) -> None:
    with suppress(FileNotFoundError), path.open("r+b") as fh:
        fh.truncate(size)


def _finish_upload(upload_id: str, settings: Settings, auto_start: bool) -> FilmResult:
    upload = _require_upload(upload_id)
    game = db.require_game(upload.game_id)
    if upload.status == "complete":  # a retried "complete": answer like the first time
        return FilmResult(game=game, job=db.get_job(game.latest_job_id) if game.latest_job_id else None)
    upload = _require_open_upload(upload_id)
    if upload.received != upload.size:
        raise ScoutError(ErrorCode.UPLOAD_INCOMPLETE, f"Only {upload.received} of {upload.size} bytes have arrived.")
    ensure_no_active_job(game.id, JobKind.ANALYZE)  # fail fast, before the slow checks
    part = storage.upload_part_path(upload.id)
    _check_container(part, upload)
    _check_duration(part, upload, settings)

    with start_lock:  # no job may start on the old film between this check and the swap
        ensure_no_active_job(game.id, JobKind.ANALYZE)
        storage.game_dir(game.id, create=True)
        _discard_old_film(game.id)
        shutil.move(part, storage.source_video_path(game.id, Path(upload.filename).suffix))
        db.save_upload(upload.model_copy(update={"status": "complete"}))
        _discard_unfinished_uploads(game.id)  # the film was just replaced: other attempts are moot
        logger.info("Upload %s complete: game %s now has %s", upload.id, game.id, upload.filename)
        game = db.update_game(
            game.id,
            has_video=True,
            video_filename=upload.filename,
            video_size=upload.size,
            video_url=None,
            status=GameStatus.UPLOADED,
            has_analysis=False,
            has_annotated_video=False,
            error=None,
            team_id_map={},  # team ids are colour clusters of the OLD film: ask the coach again
            calibration=None,  # clicked on the OLD film's frame: the GPU would apply it to the new one
        )
        return _maybe_start_analysis(game, settings, auto_start)


def _check_container(part: Path, upload: UploadSession) -> None:
    with part.open("rb") as fh:
        head = fh.read(12)
    if head[4:8] not in CONTAINER_BOXES:
        _abort(upload)
        raise ScoutError(ErrorCode.VIDEO_INVALID, f"{upload.filename!r} is not an MP4/MOV video (its header is wrong).")


def _check_duration(part: Path, upload: UploadSession, settings: Settings) -> None:
    """Reject an over-long film before it reaches the GPU (only when ffprobe is installed)."""
    seconds = probe_duration_s(part)
    limit_s = settings.max_video_minutes * 60
    if seconds is not None and seconds > limit_s:
        _abort(upload)
        film, limit = _durations(seconds, limit_s)
        raise ScoutError(ErrorCode.VIDEO_TOO_LONG, f"This film is {film} long; the limit is {limit}.")


def _durations(*seconds: float) -> list[str]:
    """Durations in minutes, with as many decimals (up to 2) as it takes to tell them apart;
    closer than that, in minutes and seconds, down to the microsecond ffprobe reports (as the
    GPU worker words VIDEO_TOO_LONG)."""
    for digits in (0, 1, 2):
        texts = [f"{s / 60:.{digits}f} minutes" for s in seconds]
        if len(set(texts)) == len(texts):
            return texts
    for digits in range(1, 7):
        parts = [divmod(round(s, digits), 60) for s in seconds]
        texts = [f"{whole:.0f} minutes {rest:.{digits}f} seconds" for whole, rest in parts]
        if len(set(texts)) == len(texts):
            break
    return texts


def probe_duration_s(path: Path) -> float | None:
    """Film length from ffprobe, or None when ffprobe is missing or cannot tell."""
    ffprobe = shutil.which("ffprobe")
    if ffprobe is None:
        return None
    command = [ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=FFPROBE_TIMEOUT_S, check=True)
        return float(result.stdout.strip())
    except (subprocess.SubprocessError, OSError, ValueError):
        logger.warning("ffprobe could not read the length of %s; skipping the duration check", path, exc_info=True)
        return None


def _abort(upload: UploadSession) -> None:
    """Give up on an upload: delete its .part file and mark the session aborted."""
    storage.upload_part_path(upload.id).unlink(missing_ok=True)
    db.save_upload(upload.model_copy(update={"status": "aborted"}))


def _discard_upload(upload_id: str) -> None:
    _require_upload(upload_id)
    storage.upload_part_path(upload_id).unlink(missing_ok=True)
    db.delete_upload(upload_id)


def _discard_unfinished_uploads(game_id: str, idle_s: float = 0.0) -> None:
    """Abort the game's open uploads that got no data for ``idle_s`` (frees their disk space)."""
    cutoff = db.utcnow() - timedelta(seconds=idle_s)
    for upload in db.list_uploads(game_id):
        if upload.status == "open" and (upload.updated_at is None or upload.updated_at <= cutoff):
            _abort(upload)
            logger.info("Upload %s for game %s was given up; its partial file was deleted", upload.id, game_id)


def _check_free_space(directory: Path, size: int) -> None:
    free = shutil.disk_usage(directory).free
    if size + DISK_HEADROOM_BYTES > free:
        raise ScoutError(
            ErrorCode.UPLOAD_TOO_LARGE,
            f"The server has only {_human_size(free)} of free disk space; this film needs {_human_size(size)}.",
            hint="Delete old games to free up space, or ask the administrator to enlarge the disk.",
        )


def _human_size(size: int) -> str:
    return f"{size / 1024**3:.1f} GB" if size >= 1024**3 else f"{size / 1024**2:.1f} MB"


# ---------------------------------------------------------------------------
# Video links and film helpers
# ---------------------------------------------------------------------------


@router.post("/games/{game_id}/video-url", response_model=FilmResult)
def set_video_url(body: VideoUrlRequest, game: CurrentGame, settings: SettingsDep, auto_start: bool = True) -> FilmResult:
    """Use a direct MP4 link as the film; the GPU worker downloads it."""
    url, parsed = _check_video_url(body.url)
    filename = _clean_filename(body.filename or "") or _link_filename(parsed)
    with start_lock:  # as in _finish_upload: no job may start on the old film meanwhile
        ensure_no_active_job(game.id, JobKind.ANALYZE)
        _discard_old_film(game.id)
        _discard_unfinished_uploads(game.id)  # the link is the film now: free the space of half-sent files
        game = db.update_game(
            game.id,
            has_video=False,
            video_filename=filename,
            video_size=None,
            video_url=url,
            status=GameStatus.UPLOADED,
            has_analysis=False,
            has_annotated_video=False,
            error=None,
            team_id_map={},  # team ids are colour clusters of the OLD film: ask the coach again
            calibration=None,  # clicked on the OLD film's frame: the GPU would apply it to the new one
        )
        return _maybe_start_analysis(game, settings, auto_start)


def _check_video_url(raw: str) -> tuple[str, ParseResult]:
    """The trimmed link and its parts, if it is one plain http(s) web address.

    Only its shape is checked: the server never fetches it (the GPU worker does), and
    the worker's downloader cannot send spaces, line breaks or non-ASCII characters.
    """
    url = raw.strip()
    if any(not " " < char <= "~" for char in url):
        raise ScoutError(
            ErrorCode.VALIDATION_FAILED,
            "The video link contains spaces, line breaks or other characters a web address cannot have.",
            hint="Copy the link again from the browser's address bar (it shows a space as %20), or upload the file.",
        )
    try:
        parsed = urlparse(url)
        host = parsed.hostname
        parsed.port  # noqa: B018 - raises for a port that is not a number from 0 to 65535
    except ValueError:  # e.g. an unclosed IPv6 address "http://[::1/film.mp4" or "http://host:99999/"
        parsed, host = None, None
    if parsed is None or parsed.scheme not in ("http", "https") or not host:
        raise ScoutError(
            ErrorCode.VALIDATION_FAILED,
            "The video link must be a full web address starting with http:// or https://.",
            hint="Paste a direct link to an MP4 file, or upload the file instead.",
        )
    return url, parsed


def _link_filename(parsed: ParseResult) -> str:
    """The film's name from the link (its last path segment, URL-decoded) or ``film.mp4``, cut to
    255 characters keeping its extension, like a name the coach types (a link may have 2000)."""
    name = _clean_filename(unquote(parsed.path))
    if len(name) > MAX_FILENAME_CHARS:
        extension = Path(name).suffix
        extension = extension if len(extension) <= MAX_EXTENSION_CHARS else ""  # not a real extension
        name = name[: MAX_FILENAME_CHARS - len(extension)].rstrip() + extension
    return name or "film.mp4"


def _maybe_start_analysis(game: Game, settings: Settings, auto_start: bool) -> FilmResult:
    """The response for a film change, queueing the analysis when ``auto_start``."""
    if not auto_start:
        return FilmResult(game=game, job=None)
    job = start_job(game, JobKind.ANALYZE, {}, settings)
    return FilmResult(game=db.require_game(game.id), job=job)


def _discard_old_film(game_id: str) -> None:
    """Delete the stored film and everything computed from it (new film = new tracks)."""
    for extension in storage.VIDEO_EXTENSIONS:
        storage.source_video_path(game_id, extension).unlink(missing_ok=True)
    for path in (storage.tracking_path(game_id), storage.annotated_video_path(game_id), storage.analysis_path(game_id)):
        path.unlink(missing_ok=True)
    # What a download of the old film's results that was cut short left (up to an overlay's size).
    shutil.rmtree(storage.incoming_dir(game_id), ignore_errors=True)
    db.clear_track_overrides(game_id)  # track ids from the old film mean nothing now


def _clean_filename(name: str) -> str:
    """Last path component of a browser/URL file name (``C:\\fakepath\\x.mp4`` -> ``x.mp4``).
    Control characters (a decoded ``%0A`` in a link) become spaces: the name is logged."""
    name = "".join(" " if unicodedata.category(char) == "Cc" else char for char in name)
    return name.replace("\\", "/").rsplit("/", 1)[-1].strip()


def remove_upload_parts(game_id: str) -> None:
    """Delete the .part files of a game's unfinished uploads (used when deleting a game)."""
    for upload in db.list_uploads(game_id):
        storage.upload_part_path(upload.id).unlink(missing_ok=True)
        _upload_locks.pop(upload.id, None)
