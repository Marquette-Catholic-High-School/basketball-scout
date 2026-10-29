"""Tracked players and the coach's manual fixes ("track 12 is #23 Smith", "ignore track 40").

Overrides take effect the next time the analysis runs (``REANALYZE``). While an ANALYZE
is queued or running they cannot be changed (409): its new run numbers the tracks again,
and installing it clears the overrides.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Path
from fastapi.responses import Response

from scout import db
from scout.api.deps import CurrentGame, has_analysis_file, require_analysis
from scout.api.jobs import start_lock
from scout.api.models import TrackOverrideBody, TrackState
from scout.errors import ErrorCode, ScoutError
from scout.schemas import JobKind, TeamSide, TrackOverride

router = APIRouter(tags=["tracks"])

TrackId = Annotated[int, Path(ge=0, le=2**63 - 1)]  # SQLite INTEGER range


@router.get("/games/{game_id}/tracks", response_model=TrackState)
def get_tracks(game: CurrentGame) -> TrackState:
    assignments = require_analysis(game.id).track_assignments if has_analysis_file(game.id) else []
    return TrackState(assignments=assignments, overrides=db.list_track_overrides(game.id))


@router.put("/games/{game_id}/tracks/{track_id}", response_model=TrackOverride)
def set_track_override(body: TrackOverrideBody, game: CurrentGame, track_id: TrackId) -> TrackOverride:
    with start_lock:  # no ANALYZE may be queued between this check and the write
        _ensure_no_film_analysis(game.id)
        if body.player_id is not None:
            _check_player_exists(game.id, body.player_id, body.side)
        override = TrackOverride(track_id=track_id, player_id=body.player_id, side=body.side, ignore=body.ignore)
        return db.set_track_override(game.id, override)


@router.delete("/games/{game_id}/tracks/{track_id}", status_code=204)
def delete_track_override(game: CurrentGame, track_id: TrackId) -> Response:
    with start_lock:  # as in set_track_override
        _ensure_no_film_analysis(game.id)
        if not db.delete_track_override(game.id, track_id):
            raise ScoutError(ErrorCode.NOT_FOUND, f"Track {track_id} has no manual assignment.")
    return Response(status_code=204)


def _ensure_no_film_analysis(game_id: str) -> None:
    """409 CONFLICT while an ANALYZE is queued or running: installing its new run clears the
    overrides, so a fix made now would be dropped without a word. A REANALYZE or a REPORT
    keeps the track numbers, so it does not block."""
    active = next((job for job in db.active_jobs_for_game(game_id) if job.kind == JobKind.ANALYZE), None)
    if active is None:
        return
    raise ScoutError(
        ErrorCode.CONFLICT,
        "This game's film is being analysed on the GPU. The new run numbers the players' tracks again, "
        "so a track assignment made now would be lost.",
        hint="Set the track assignments once the analysis has finished.",
        detail=f"active job {active.id} ({active.kind}, {active.status})",
    )


def _check_player_exists(game_id: str, player_id: str, side: TeamSide | None) -> None:
    """The player must be on the given side's roster (either roster when side is unknown)."""
    rosters = db.get_rosters(game_id)
    sides = [side] if side else list(TeamSide)
    if not any(rosters[s].by_id(player_id) for s in sides):
        where = f"the {side} roster" if side else "either roster"
        raise ScoutError(
            ErrorCode.VALIDATION_FAILED,
            f"Player {player_id!r} is not on {where}.",
            hint="Add the player to the roster first, or pick another player.",
        )
