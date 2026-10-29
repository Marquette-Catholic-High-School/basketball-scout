"""Shared route dependencies: settings, id validation, loading games and analyses,
and download helpers.

Path ids must look like the ids we generate (``g_``/``j_``/``u_``/``r_`` + hex) before
they reach the database or the filesystem; anything else is a plain 404.
"""

from __future__ import annotations

import re
from datetime import date
from typing import Annotated

from fastapi import Depends, Request
from fastapi.responses import Response

from scout import db, storage
from scout.analysis import pipeline as analysis_pipeline
from scout.config import Settings
from scout.errors import ErrorCode, ScoutError
from scout.schemas import Game, GameAnalysis, TeamSide


def app_settings(request: Request) -> Settings:
    return request.app.state.settings


SettingsDep = Annotated[Settings, Depends(app_settings)]


def check_id(value: str, prefix: str, what: str, code: ErrorCode = ErrorCode.NOT_FOUND) -> str:
    """Return ``value`` if it is ``<prefix><hex>``, else raise a 404 ScoutError."""
    if not re.fullmatch(rf"{prefix}[0-9a-f]{{1,32}}", value):
        raise ScoutError(code, f"{what} {value!r} not found.")
    return value


def game_id_param(game_id: str) -> str:
    return check_id(game_id, "g_", "Game")


def job_id_param(job_id: str) -> str:
    return check_id(job_id, "j_", "Job")


def upload_id_param(upload_id: str) -> str:
    return check_id(upload_id, "u_", "Upload", ErrorCode.UPLOAD_NOT_FOUND)


def report_id_param(report_id: str) -> str:
    return check_id(report_id, "r_", "Report")


GameId = Annotated[str, Depends(game_id_param)]
JobId = Annotated[str, Depends(job_id_param)]
UploadId = Annotated[str, Depends(upload_id_param)]
ReportId = Annotated[str, Depends(report_id_param)]


def current_game(game_id: GameId) -> Game:
    return db.require_game(game_id)


CurrentGame = Annotated[Game, Depends(current_game)]


def has_analysis_file(game_id: str) -> bool:
    return storage.analysis_path(game_id).is_file()


def require_analysis(game_id: str) -> GameAnalysis:
    """The game's ``analysis.json`` or a 409 ANALYSIS_NOT_READY."""
    if not has_analysis_file(game_id):
        raise ScoutError(ErrorCode.ANALYSIS_NOT_READY)
    return analysis_pipeline.load_analysis(storage.analysis_path(game_id))


def team_name(game: Game, side: TeamSide) -> str:
    return game.scouted_team if side == TeamSide.SCOUTED else game.other_team


def slugify(text: str, fallback: str) -> str:
    """``"St. Mary's HS"`` -> ``"st-mary-s-hs"`` (safe in file names and headers)."""
    return re.sub(r"[^a-z0-9]+", "-", text.lower())[:40].strip("-") or fallback


def export_filename(prefix: str, game: Game, side: TeamSide, extension: str) -> str:
    """Download name like ``fastscout_central-hs_2026-01-09.txt``."""
    when: date | None = game.game_date or (game.created_at.date() if game.created_at else None)
    team = slugify(team_name(game, side), side.value)
    return f"{prefix}_{team}_{when.isoformat() if when else 'undated'}.{extension}"


def text_download(content: str, media_type: str, filename: str, download: bool) -> Response:
    """Text response; ``download=True`` adds ``Content-Disposition: attachment``."""
    headers = {"Content-Disposition": f'attachment; filename="{filename}"'} if download else None
    return Response(content=content, media_type=media_type, headers=headers)
