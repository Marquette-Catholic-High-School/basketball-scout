"""Claude scouting reports: request one (a background REPORT job), list, download Markdown."""

from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import Response

from scout import db
from scout.api.deps import CurrentGame, ReportId, SettingsDep, check_id, export_filename, text_download
from scout.api.jobs import start_job
from scout.errors import ErrorCode, ScoutError
from scout.reporting import render
from scout.schemas import Game, Job, JobKind, ReportRecord, ReportRequest, TeamSide

router = APIRouter(tags=["reports"])


@router.post("/games/{game_id}/reports", response_model=Job, status_code=202)
def request_report(body: ReportRequest, game: CurrentGame, settings: SettingsDep) -> Job:
    """Queue a report; poll ``GET /api/jobs/{id}``, then read ``GET /api/games/{id}/reports``."""
    return start_job(game, JobKind.REPORT, {"coach_focus": body.coach_focus}, settings)


@router.get("/games/{game_id}/reports", response_model=list[ReportRecord])
def list_reports(game: CurrentGame) -> list[ReportRecord]:
    return db.list_reports(game.id)


@router.get("/reports/{report_id}", response_model=ReportRecord)
def get_report(report_id: ReportId) -> ReportRecord:
    record = db.get_report(report_id)
    if record is None:
        raise ScoutError(ErrorCode.NOT_FOUND, f"Report {report_id!r} not found.")
    return record


@router.get("/games/{game_id}/export/report.md")
def report_markdown(game: CurrentGame, report_id: str | None = None, download: bool = False) -> Response:
    """The latest report (or ``report_id``) as Markdown, rendered with the current game details."""
    record = _report_for_game(game, report_id)
    markdown = render.report_to_markdown(record.report, game, model=record.model)
    filename = export_filename("scouting_report", game, TeamSide.SCOUTED, "md")
    return text_download(markdown, "text/markdown", filename, download)


def _report_for_game(game: Game, report_id: str | None) -> ReportRecord:
    if not report_id:
        latest = db.latest_report(game.id)
        if latest is None:
            raise ScoutError(
                ErrorCode.NOT_FOUND,
                "No scouting report has been written for this game yet.",
                hint="Click 'Generate report' on the game page.",
            )
        return latest
    record = db.get_report(check_id(report_id, "r_", "Report"))
    if record is None or record.game_id != game.id:
        raise ScoutError(ErrorCode.NOT_FOUND, f"Report {report_id!r} not found for this game.")
    return record
