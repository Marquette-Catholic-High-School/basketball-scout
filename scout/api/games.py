"""Games: create, list, edit, delete, and read the finished analysis."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter
from fastapi.responses import Response

from scout import db, storage
from scout.api.deps import CurrentGame, require_analysis
from scout.api.uploads import remove_upload_parts
from scout.errors import ErrorCode, ScoutError
from scout.schemas import Game, GameAnalysis, GameCreate, GameUpdate

logger = logging.getLogger(__name__)

# PATCH sends null to clear a field; these Game fields cannot be None.
_CLEARED_VALUES: dict[str, Any] = {"title": "", "other_team": "", "team_id_map": {}}

router = APIRouter(tags=["games"])


@router.get("/games", response_model=list[Game])
def list_games() -> list[Game]:
    return db.list_games()


@router.post("/games", response_model=Game, status_code=201)
def create_game(body: GameCreate) -> Game:
    game = db.create_game(body)
    logger.info("Game %s created: %s", game.id, game.display_title)
    return game


@router.get("/games/{game_id}", response_model=Game)
def get_game(game: CurrentGame) -> Game:
    return game


@router.patch("/games/{game_id}", response_model=Game)
def update_game(body: GameUpdate, game: CurrentGame) -> Game:
    """Change only the fields sent. (Re-run the analysis to apply a new team colour map.)"""
    changes = body.model_dump(exclude_unset=True)
    if "scouted_team" in changes and changes["scouted_team"] is None:
        raise ScoutError(ErrorCode.VALIDATION_FAILED, detail="scouted_team: The scouted team needs a name")
    for field, cleared in _CLEARED_VALUES.items():
        if field in changes and changes[field] is None:
            changes[field] = cleared
    return db.update_game(game.id, **changes)


@router.delete("/games/{game_id}", status_code=204)
def delete_game(game: CurrentGame) -> Response:
    """Cancel the game's jobs, delete its files and remove it (rosters, reports... cascade)."""
    for job in db.active_jobs_for_game(game.id):
        db.request_cancel(job.id)
    remove_upload_parts(game.id)
    storage.remove_game_files(game.id)
    db.delete_game(game.id)
    logger.info("Game %s deleted", game.id)
    return Response(status_code=204)


@router.get("/games/{game_id}/analysis", response_model=GameAnalysis)
def get_analysis(game: CurrentGame) -> Response:
    """The full analysis (timeline, box scores, plays...), serialised once without
    re-validation because a full game's timeline is large."""
    analysis = require_analysis(game.id)
    return Response(content=analysis.model_dump_json(), media_type="application/json")
