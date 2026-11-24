"""Live games: what the web app and the worker share (docs/LIVE.md).

A live game's film arrives in parts while the game is played. A capture client (the Mac app)
cuts the camera's stream into parts of ``segment_seconds`` and uploads each one with the normal
chunked upload; one LIVE job (``scout.live_runner``) sends every part to the GPU as it arrives,
joins the results and rebuilds the analysis, so the box score fills in during the game.

State lives in two places: ``Game.live`` (counters and the session's state) and one
``live_segments`` row per part. The web process writes the parts as they arrive and the "end the
game" request; the worker writes what it did with each part.
"""

from __future__ import annotations

import logging
import shutil
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from scout import db, storage
from scout.config import Settings
from scout.errors import ErrorCode, ScoutError
from scout.schemas import (
    LIVE_SETTLED_STATUSES,
    Game,
    LiveEndReason,
    LiveInfo,
    LiveSegment,
    LiveSegmentStatus,
    LiveState,
    UploadSession,
)

logger = logging.getLogger(__name__)

SEGMENT_JOB_SEPARATOR = "-p"
# A part that never arrived is skipped once a later part has been here this long (the client sends
# them in order, so it is not coming), or at once when the game is ending.
GAP_GRACE_S = 120.0
FILM_JOIN_TIMEOUT_S = 3600.0


# ---------------------------------------------------------------------------
# Ids
# ---------------------------------------------------------------------------


def segment_job_id(job_id: str, index: int) -> str:
    """The id a part's GPU call runs under: the live job's id plus the part (``j_ab12-p00007``)."""
    return f"{job_id}{SEGMENT_JOB_SEPARATOR}{index:05d}"


def parent_job_id(job_id: str) -> str:
    """The live job a part's GPU call belongs to; any other job id comes back unchanged."""
    return job_id.split(SEGMENT_JOB_SEPARATOR, 1)[0]


# ---------------------------------------------------------------------------
# Web process: start, new parts, end
# ---------------------------------------------------------------------------


def new_live_info(settings: Settings, segment_seconds: int | None) -> LiveInfo:
    return LiveInfo(segment_seconds=segment_seconds or settings.live_segment_seconds, started_at=db.utcnow())


def check_can_start(game: Game) -> None:
    """A live stream needs a game without film: its parts become the film."""
    if game.live is not None and not _ended_empty(game.live):
        raise ScoutError(
            ErrorCode.LIVE_ENDED if game.live.state == LiveState.ENDED else ErrorCode.CONFLICT,
            "This game's live stream has ended." if game.live.state == LiveState.ENDED else "This game is live already.",
            hint="Create a new game to analyse another live stream.",
        )
    if game.has_video or game.video_url or storage.find_source_video(game.id) is not None:
        raise ScoutError(
            ErrorCode.CONFLICT,
            "This game already has film.",
            hint="Create a new game for the live stream.",
        )


def _ended_empty(live: LiveInfo) -> bool:
    return live.state == LiveState.ENDED and live.segments_received == 0


def require_live(game: Game) -> LiveInfo:
    if game.live is None:
        raise ScoutError(ErrorCode.NOT_FOUND, "This game is not a live game.")
    return game.live


def require_capturing(game: Game) -> LiveInfo:
    """The live state, while the game still takes film."""
    live = require_live(game)
    if live.state != LiveState.CAPTURING:
        message = "This live game has ended." if live.state == LiveState.ENDED else "This live game is being finished."
        raise ScoutError(ErrorCode.LIVE_ENDED, message)
    return live


def check_room(game: Game, live: LiveInfo, duration_s: float, settings: Settings) -> None:
    """Refuse a part that would take the game past ``SCOUT_MAX_VIDEO_MINUTES``; the game then ends."""
    limit_s = settings.max_video_minutes * 60
    if live.received_s + duration_s <= limit_s:
        return
    db.update_live(game.id, state=LiveState.FINISHING, end_reason=LiveEndReason.LIMIT)
    logger.info("Live game %s reached the %g minute limit; finishing", game.id, settings.max_video_minutes)
    raise ScoutError(
        ErrorCode.LIVE_ENDED,
        f"This live game reached the longest film the server takes ({settings.max_video_minutes:g} minutes).",
        hint="Raise SCOUT_MAX_VIDEO_MINUTES in .env for longer games.",
    )


def accept_segment(upload: UploadSession, part: Path) -> Game:
    """Make a finished upload part ``upload.live_segment`` of its game's live film."""
    index = upload.live_segment
    if index is None:
        raise ValueError("not a live part upload")
    game = db.require_game(upload.game_id)
    require_capturing(game)
    existing = db.get_live_segment(game.id, index)
    if existing is not None:  # sent twice (the client retried after a lost answer): keep the first
        part.unlink(missing_ok=True)
        return game
    storage.live_dir(game.id, create=True)
    shutil.move(part, storage.live_segment_video_path(game.id, index))
    now = db.utcnow()
    duration_s = upload.live_duration_s or float(require_live(game).segment_seconds)
    db.save_live_segment(
        LiveSegment(
            game_id=game.id,
            index=index,
            duration_s=duration_s,
            size=upload.size,
            filename=upload.filename,
            uploaded_at=now,
        )
    )
    segments = db.list_live_segments(game.id)
    logger.info("Live game %s: part %d arrived (%d bytes, %.0f s)", game.id, index, upload.size, duration_s)
    return db.update_live(
        game.id,
        segments_received=len(segments),
        received_s=round(sum(s.duration_s for s in segments), 3),
        last_segment_at=now,
    )


def request_finish(game: Game) -> Game:
    """No more film is coming: the worker finishes the parts it has, then ends the game."""
    live = require_live(game)
    if live.state != LiveState.CAPTURING:
        return game
    logger.info("Live game %s: the coach ended the stream", game.id)
    return db.update_live(game.id, state=LiveState.FINISHING, end_reason=LiveEndReason.FINISHED)


def mark_ended(game_id: str, reason: LiveEndReason) -> None:
    """The live session is over (also for a game deleted meanwhile: nothing to mark then)."""
    try:
        game = db.get_game(game_id)
        if game is None or game.live is None or game.live.state == LiveState.ENDED:
            return
        # The reason the game stopped taking film stays (finished, idle, limit) unless it broke off.
        keep = game.live.end_reason if reason == LiveEndReason.FINISHED and game.live.end_reason else reason
        db.update_live(game_id, state=LiveState.ENDED, end_reason=keep, ended_at=db.utcnow())
    except ScoutError as exc:
        if exc.code != ErrorCode.NOT_FOUND:
            raise


def discard(game_id: str) -> None:
    """Forget a game's live parts (its film was replaced by an upload or a link)."""
    shutil.rmtree(storage.live_dir(game_id), ignore_errors=True)
    db.delete_live_segments(game_id)


# ---------------------------------------------------------------------------
# Which parts the analysis can use
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PrefixPart:
    """A part at the front of the stream that is settled: analysed, failed or never arrived."""

    index: int
    duration_s: float
    analysed: bool
    empty: bool = False  # no play was found in it (a break): no stats, and not a failure


def settled_prefix(
    segments: list[LiveSegment], live: LiveInfo, now: datetime, *, gap_grace_s: float = GAP_GRACE_S
) -> list[PrefixPart]:
    """The parts from the start of the stream up to the first one still waiting for the GPU.

    The analysis always covers the game "up to" a time, never with a part in the middle still to
    come. A part that failed is in it without stats. An index that never arrived is skipped once it
    clearly will not: a later part has been here for ``gap_grace_s``, or the game is ending.
    """
    by_index = {s.index: s for s in segments}
    if not by_index:
        return []
    prefix: list[PrefixPart] = []
    for index in range(max(by_index) + 1):
        segment = by_index.get(index)
        if segment is None:
            later = [s.uploaded_at for s in segments if s.index > index and s.uploaded_at is not None]
            waited = (now - min(later)).total_seconds() if later else 0.0
            if live.state == LiveState.CAPTURING and waited < gap_grace_s:
                break
            prefix.append(PrefixPart(index, float(live.segment_seconds), analysed=False))
        elif segment.status in LIVE_SETTLED_STATUSES:
            prefix.append(
                PrefixPart(
                    index,
                    segment.duration_s,
                    analysed=segment.status == LiveSegmentStatus.DONE,
                    empty=segment.status == LiveSegmentStatus.EMPTY,
                )
            )
        else:
            break
    return prefix


# ---------------------------------------------------------------------------
# The film
# ---------------------------------------------------------------------------


def join_film(game_id: str, segments: list[LiveSegment]) -> Path | None:
    """Join the parts into the game's film (``source.mp4``) without re-encoding.

    Returns the film's path, or None when it could not be made (no ffmpeg on this server, or
    ffmpeg failed): the parts then stay in the game's ``live/`` folder.
    """
    parts = [storage.live_segment_video_path(game_id, s.index) for s in sorted(segments, key=lambda s: s.index)]
    parts = [p for p in parts if p.is_file()]
    if not parts:
        return None
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        logger.warning("Live game %s: ffmpeg is not installed, so the film was not put together", game_id)
        return None
    live = storage.live_dir(game_id)
    listing = live / "parts.txt"
    listing.write_text("".join(f"file '{p.name}'\n" for p in parts), encoding="utf-8")
    target = storage.source_video_path(game_id)
    partial = live / "film.partial.mp4"
    command = [
        ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
        "-f", "concat", "-safe", "0", "-i", str(listing),
        "-c", "copy", "-movflags", "+faststart", str(partial),
    ]  # fmt: skip
    try:
        subprocess.run(command, capture_output=True, text=True, timeout=FILM_JOIN_TIMEOUT_S, check=True, cwd=live)
        partial.replace(target)
    except (OSError, subprocess.SubprocessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        logger.warning("Live game %s: ffmpeg could not join the film: %s", game_id, str(detail).strip()[-500:])
        partial.unlink(missing_ok=True)
        return None
    finally:
        listing.unlink(missing_ok=True)
    return target
