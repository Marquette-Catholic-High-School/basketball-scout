"""Tracked players and the coach's manual fixes ("track 12 is #23 Smith", "ignore track 40").

Overrides take effect the next time the analysis runs (``REANALYZE``).
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Path
from fastapi.responses import Response

from scout import db
from scout.api.deps import CurrentGame, has_analysis_file, require_analysis
from scout.api.models import TrackOverrideBody, TrackState
from scout.errors import ErrorCode, ScoutError
from scout.schemas import TeamSide, TrackOverride

router = APIRouter(tags=["tracks"])

TrackId = Annotated[int, Path(ge=0)]


@router.get("/games/{game_id}/tracks", response_model=TrackState)
def get_tracks(game: CurrentGame) -> TrackState:
    assignments = require_analysis(game.id).track_assignments if has_analysis_file(game.id) else []
    return TrackState(assignments=assignments, overrides=db.list_track_overrides(game.id))


@router.put("/games/{game_id}/tracks/{track_id}", response_model=TrackOverride)
def set_track_override(body: TrackOverrideBody, game: CurrentGame, track_id: TrackId) -> TrackOverride:
    if body.player_id is not None:
        _check_player_exists(game.id, body.player_id, body.side)
    override = TrackOverride(track_id=track_id, player_id=body.player_id, side=body.side, ignore=body.ignore)
    return db.set_track_override(game.id, override)


@router.delete("/games/{game_id}/tracks/{track_id}", status_code=204)
def delete_track_override(game: CurrentGame, track_id: TrackId) -> Response:
    if not db.delete_track_override(game.id, track_id):
        raise ScoutError(ErrorCode.NOT_FOUND, f"Track {track_id} has no manual assignment.")
    return Response(status_code=204)


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
