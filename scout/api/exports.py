"""Downloads: FastScout paste block and custom-table CSV, timeline CSV, analysis JSON.

All of them need a finished analysis (409 ANALYSIS_NOT_READY otherwise) and accept
``?download=1`` to be saved as a file instead of shown in the browser. The FastScout
notes (warnings + hand-typed team numbers) shown next to the paste block are JSON.
"""

from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import Response

from scout.api.deps import CurrentGame, export_filename, require_analysis, slugify, text_download
from scout.api.models import FastScoutNotes
from scout.errors import ErrorCode, ScoutError
from scout.export import fastscout
from scout.schemas import TeamSide

router = APIRouter(tags=["exports"])


@router.get("/games/{game_id}/export/fastscout.txt")
def fastscout_paste_block(game: CurrentGame, side: TeamSide = TeamSide.SCOUTED, download: bool = False) -> Response:
    """Tab-separated box score to paste into the FastScout Stats Database."""
    text = fastscout.build_paste_block(require_analysis(game.id), game, side)
    return text_download(text, "text/plain", export_filename("fastscout", game, side, "txt"), download)


@router.get("/games/{game_id}/export/fastscout-notes", response_model=FastScoutNotes)
def fastscout_notes(game: CurrentGame, side: TeamSide = TeamSide.SCOUTED) -> FastScoutNotes:
    """What to check before pasting that side's block, and the team numbers typed in by hand."""
    analysis = require_analysis(game.id)
    return FastScoutNotes(
        warnings=fastscout.paste_block_warnings(analysis, game, side),
        team_numbers=fastscout.team_helper_block(analysis, side),
    )


@router.get("/games/{game_id}/export/fastscout.csv")
def fastscout_custom_table(
    game: CurrentGame, side: TeamSide = TeamSide.SCOUTED, table: str | None = None, download: bool = False
) -> Response:
    """CSV for a FastScout Web custom table (``table`` from ``/api/export/fastscout/tables``)."""
    analysis = require_analysis(game.id)
    if table:
        tables = fastscout.list_custom_tables()
        if table not in tables:
            raise ScoutError(
                ErrorCode.VALIDATION_FAILED,
                f"There is no FastScout table called {table!r}.",
                hint=f"Choose one of: {', '.join(tables)}.",
            )
    csv_text = fastscout.build_custom_table_csv(analysis, game, side, table or None)
    prefix = f"fastscout_{slugify(table, 'table')}" if table else "fastscout"
    return text_download(csv_text, "text/csv", export_filename(prefix, game, side, "csv"), download)


@router.get("/export/fastscout/tables", response_model=list[str])
def fastscout_tables() -> list[str]:
    return fastscout.list_custom_tables()


@router.get("/games/{game_id}/export/timeline.csv")
def timeline_csv(game: CurrentGame, download: bool = False) -> Response:
    csv_text = fastscout.build_timeline_csv(require_analysis(game.id))
    return text_download(csv_text, "text/csv", export_filename("timeline", game, TeamSide.SCOUTED, "csv"), download)


@router.get("/games/{game_id}/export/analysis.json")
def analysis_json(game: CurrentGame, download: bool = False) -> Response:
    text = require_analysis(game.id).model_dump_json(indent=2)
    return text_download(text, "application/json", export_filename("analysis", game, TeamSide.SCOUTED, "json"), download)
