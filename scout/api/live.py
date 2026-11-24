"""Live games: start a live stream, receive its parts, end it (docs/LIVE.md).

A capture client (the Mac app) cuts the camera's stream into parts and sends each one:

1. ``POST /api/games/{id}/live`` once: the game becomes a live game and its LIVE job is queued.
2. For every part, ``POST /api/games/{id}/live/segments`` with its index, length and size ->
   an upload session; then the normal ``PUT /api/uploads/{upload_id}/chunk`` and
   ``POST /api/uploads/{upload_id}/complete``.
3. ``POST /api/games/{id}/live/finish`` when the stream is over.

Every step can be repeated: a second start answers with the running session, a part that is
already here answers with a completed upload, and a half-sent part resumes where it stopped.
"""

from __future__ import annotations

import logging
from pathlib import Path

from fastapi import APIRouter, Response

from scout import db, live, storage
from scout.api.deps import CurrentGame, SettingsDep
from scout.api.jobs import ensure_no_active_job, start_job, start_lock
from scout.api.uploads import _abort, _check_free_space, _clean_filename, _human_size
from scout.errors import ErrorCode, ScoutError
from scout.schemas import (
    Game,
    JobKind,
    LiveSegmentInit,
    LiveStart,
    LiveState,
    LiveStatus,
    UploadSession,
)

logger = logging.getLogger(__name__)

router = APIRouter(tags=["live"])


@router.post("/games/{game_id}/live", response_model=LiveStatus, status_code=201)
def start_live(game: CurrentGame, settings: SettingsDep, response: Response, body: LiveStart | None = None) -> LiveStatus:
    """Make the game a live game and queue its LIVE job. Asked again while it runs: the same session (200)."""
    with start_lock:
        game = db.require_game(game.id)
        if game.live is not None and game.live.state == LiveState.CAPTURING:
            response.status_code = 200
            return _status(game)
        live.check_can_start(game)
        ensure_no_active_job(game.id, JobKind.LIVE)
        live.discard(game.id)  # what a session that ended without film left
        info = live.new_live_info(settings, body.segment_seconds if body else None)
        game = db.update_game(game.id, live=info, has_analysis=storage.analysis_path(game.id).is_file())
        try:
            start_job(game, JobKind.LIVE, {}, settings)
        except Exception:
            db.update_game(game.id, live=None)
            raise
    logger.info("Game %s is live (parts of %d s)", game.id, info.segment_seconds)
    return _status(db.require_game(game.id))


@router.get("/games/{game_id}/live", response_model=LiveStatus)
def get_live(game: CurrentGame) -> LiveStatus:
    live.require_live(game)
    return _status(game)


@router.post("/games/{game_id}/live/segments", response_model=UploadSession, status_code=201)
def create_segment_upload(
    body: LiveSegmentInit, game: CurrentGame, settings: SettingsDep, response: Response
) -> UploadSession:
    """An upload session for one part. 200 with the existing session when the part is already
    here (``status: complete``) or half-sent (``status: open``: resume from ``received``)."""
    info = live.require_capturing(game)
    known = db.get_live_segment(game.id, body.index)
    if known is not None:
        response.status_code = 200
        return _completed_upload(game, body.index, known.filename, known.size, settings.upload_chunk_bytes)
    filename = _clean_filename(body.filename or "") or f"part-{body.index:05d}.mp4"
    if Path(filename).suffix.lower() != ".mp4":
        raise ScoutError(ErrorCode.VIDEO_INVALID, f"{filename!r} is not an MP4 file.", hint="Send the parts of a live game as MP4.")
    if body.size > settings.max_upload_bytes:
        raise ScoutError(
            ErrorCode.UPLOAD_TOO_LARGE,
            f"This part is {_human_size(body.size)}; the limit is {_human_size(settings.max_upload_bytes)}.",
        )
    live.check_room(game, info, body.duration_s, settings)
    for upload in db.list_uploads(game.id):
        if upload.live_segment != body.index or upload.status != "open":
            continue
        if upload.size == body.size and storage.upload_part_path(upload.id).is_file():
            response.status_code = 200
            return upload  # the client restarted in the middle of this part
        _abort(upload)
    upload = UploadSession(
        game_id=game.id,
        filename=filename,
        size=body.size,
        chunk_size=settings.upload_chunk_bytes,
        live_segment=body.index,
        live_duration_s=body.duration_s,
    )
    part = storage.upload_part_path(upload.id)
    part.parent.mkdir(parents=True, exist_ok=True)
    _check_free_space(part.parent, body.size)
    part.write_bytes(b"")
    return db.save_upload(upload)


@router.post("/games/{game_id}/live/finish", response_model=LiveStatus)
def finish_live(game: CurrentGame) -> LiveStatus:
    """No more film is coming. The parts already here are finished, then the game ends."""
    live.require_live(game)
    game = live.request_finish(game)
    for upload in db.list_uploads(game.id):  # a part that was still being sent can no longer join
        if upload.live_segment is not None and upload.status == "open":
            _abort(upload)
    return _status(game)


def _completed_upload(game: Game, index: int, filename: str, size: int, chunk_size: int) -> UploadSession:
    """The session a part arrived with, or a stand-in when it is gone: either way ``complete``."""
    for upload in db.list_uploads(game.id):
        if upload.live_segment == index and upload.status == "complete":
            return upload
    return UploadSession(
        game_id=game.id, filename=filename, size=size, received=size, chunk_size=chunk_size, status="complete", live_segment=index
    )


def _status(game: Game) -> LiveStatus:
    job = db.get_job(game.latest_job_id) if game.latest_job_id else None
    return LiveStatus(game=game, segments=db.list_live_segments(game.id), job=job)
