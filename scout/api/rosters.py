"""Per-game rosters for both teams: import from CSV/Excel, edit by hand, template.

Rosters drive jersey -> name matching. Whenever a roster changes, manual track
assignments that point at a player who is no longer on it are dropped so they cannot
silently attach stats to nobody. (Re-run the analysis to apply roster changes.)
"""

from __future__ import annotations

import csv
import io
import logging
from typing import Annotated, Literal

from fastapi import APIRouter, File, Form, UploadFile
from fastapi.responses import Response

from scout import db
from scout.api.deps import CurrentGame
from scout.api.errors import validate_model
from scout.api.models import GameRosters, RosterPlayerPatch, RosterReplace
from scout.errors import ErrorCode, ScoutError
from scout.roster import importer
from scout.schemas import Roster, RosterImportResult, RosterPlayer, TeamSide

logger = logging.getLogger(__name__)

MAX_ROSTER_FILE_BYTES = 2 * 1024 * 1024
TEMPLATE_HEADER = ["Jersey", "First Name", "Last Name", "Position", "Grade", "Height", "FastScout Name", "Notes"]
TEMPLATE_EXAMPLES = [
    ["3", "Jordan", "Smith", "G", "12", "6'1\"", "Jordan Smith", "Left-handed, attacks closeouts"],
    ["24", "Chris", "Johnson", "F", "11", "6'5\"", "Chris Johnson", "Strong offensive rebounder"],
]

router = APIRouter(tags=["rosters"])


@router.get("/games/{game_id}/rosters", response_model=GameRosters)
def get_rosters(game: CurrentGame) -> GameRosters:
    rosters = db.get_rosters(game.id)
    return GameRosters(scouted=rosters[TeamSide.SCOUTED], other=rosters[TeamSide.OTHER])


@router.get("/games/{game_id}/rosters/{side}", response_model=Roster)
def get_roster(game: CurrentGame, side: TeamSide) -> Roster:
    return db.get_roster(game.id, side)


@router.put("/games/{game_id}/rosters/{side}", response_model=Roster)
def replace_roster(body: RosterReplace, game: CurrentGame, side: TeamSide) -> Roster:
    """Replace the whole player list (players keep the ids they were sent with)."""
    ids = [player.id for player in body.players]
    if len(set(ids)) != len(ids):
        raise ScoutError(ErrorCode.VALIDATION_FAILED, detail="players: two players have the same id")
    roster = db.get_roster(game.id, side)
    team_name = roster.team_name if body.team_name is None else body.team_name
    return _save(roster.model_copy(update={"team_name": team_name, "players": body.players}))


@router.post("/games/{game_id}/rosters/{side}/import", response_model=RosterImportResult)
def import_roster(
    game: CurrentGame,
    side: TeamSide,
    file: Annotated[UploadFile, File(description="CSV, TSV, TXT or XLSX roster")],
    mode: Annotated[Literal["replace", "merge"], Form()] = "replace",
) -> RosterImportResult:
    """``replace``: the file becomes the roster. ``merge``: same jersey = update, new jersey = add."""
    content = file.file.read(MAX_ROSTER_FILE_BYTES + 1)
    if len(content) > MAX_ROSTER_FILE_BYTES:
        raise ScoutError(
            ErrorCode.UPLOAD_TOO_LARGE, "Roster files must be 2 MB or smaller.", hint="Save just the roster as a CSV."
        )
    filename = file.filename or "roster.csv"
    parsed = importer.parse_roster_file(filename, content)
    roster = _save(importer.merge_players(db.get_roster(game.id, side), parsed.players, mode))
    logger.info("Imported %d players from %s into game %s (%s, %s)", len(parsed.players), filename, game.id, side, mode)
    return RosterImportResult(
        roster=roster,
        imported=len(parsed.players),
        skipped_rows=parsed.skipped_rows,
        warnings=parsed.warnings,
        detected_columns=parsed.detected_columns,
    )


@router.post("/games/{game_id}/rosters/{side}/players", response_model=Roster)
def add_player(body: RosterPlayer, game: CurrentGame, side: TeamSide) -> Roster:
    roster = db.get_roster(game.id, side)
    if roster.by_id(body.id) is not None:
        raise ScoutError(ErrorCode.CONFLICT, f"Player id {body.id!r} is already on this roster.")
    return _save(roster.model_copy(update={"players": [*roster.players, body]}))


@router.patch("/games/{game_id}/rosters/{side}/players/{player_id}", response_model=Roster)
def update_player(body: RosterPlayerPatch, game: CurrentGame, side: TeamSide, player_id: str) -> Roster:
    roster = db.get_roster(game.id, side)
    player = _require_player(roster, player_id)
    updated = validate_model(RosterPlayer, {**player.model_dump(), **body.model_dump(exclude_unset=True)})
    players = [updated if p.id == player_id else p for p in roster.players]
    return _save(roster.model_copy(update={"players": players}))


@router.delete("/games/{game_id}/rosters/{side}/players/{player_id}", response_model=Roster)
def delete_player(game: CurrentGame, side: TeamSide, player_id: str) -> Roster:
    roster = db.get_roster(game.id, side)
    _require_player(roster, player_id)
    return _save(roster.model_copy(update={"players": [p for p in roster.players if p.id != player_id]}))


@router.get("/roster-template.csv")
def roster_template() -> Response:
    """A ready-to-fill roster CSV with the column names the importer recognises."""
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\r\n")
    writer.writerows([TEMPLATE_HEADER, *TEMPLATE_EXAMPLES])
    return Response(
        content=buffer.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": 'attachment; filename="roster-template.csv"'},
    )


def _require_player(roster: Roster, player_id: str) -> RosterPlayer:
    player = roster.by_id(player_id)
    if player is None:
        raise ScoutError(ErrorCode.NOT_FOUND, f"Player {player_id!r} is not on the {roster.side} roster.")
    return player


def _save(roster: Roster) -> Roster:
    saved = db.save_roster(roster)
    prune_track_overrides(roster.game_id)
    return saved


def prune_track_overrides(game_id: str) -> None:
    """Drop manual track assignments whose player is no longer on that side's roster."""
    rosters = db.get_rosters(game_id)
    for override in db.list_track_overrides(game_id):
        if override.player_id is None:
            continue
        sides = [override.side] if override.side else list(TeamSide)
        if not any(rosters[side].by_id(override.player_id) for side in sides):
            db.delete_track_override(game_id, override.track_id)
            logger.info("Removed the manual assignment of track %d (player left the roster)", override.track_id)
