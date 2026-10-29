"""Background jobs for a game: start, list, cancel, retry.

``start_job`` holds the rules every entry point shares (this router, upload
``complete``, ``video-url`` and ``POST /reports``):

* ANALYZE needs film (an uploaded file or a URL), REANALYZE needs ``tracking.json.gz``,
  REPORT needs ``analysis.json`` and an Anthropic API key.
* While an analysis job (ANALYZE/REANALYZE) is active no other job starts (409), and
  only one REPORT job may be active per game.
* Analysis jobs move the game to ``queued`` and become its ``latest_job_id``.
"""

from __future__ import annotations

import logging
import threading
from typing import Any

from fastapi import APIRouter

from scout import db, storage
from scout.api.deps import CurrentGame, JobId, SettingsDep, has_analysis_file
from scout.api.errors import validate_model
from scout.config import Settings
from scout.errors import ErrorCode, ScoutError
from scout.jobs import queue as job_queue
from scout.schemas import Game, GameStatus, Job, JobCreate, JobKind, JobStage, JobStatus, ReportRequest

logger = logging.getLogger(__name__)

ANALYSIS_KINDS = frozenset({JobKind.ANALYZE, JobKind.REANALYZE})

router = APIRouter(tags=["jobs"])

# Routes run in a thread pool, so two requests (a double click, a second tab) could both
# pass the "no active job" check before either job exists. One web process serves the
# app, so a lock around check + submit is enough. A film change (uploads.py) holds it
# from its own check until the new film is in place, so no job starts on the old film;
# re-entrant because the film change then starts the analysis itself.
start_lock = threading.RLock()


# ---------------------------------------------------------------------------
# Shared rules
# ---------------------------------------------------------------------------


def start_job(game: Game, kind: JobKind, params: dict[str, Any], settings: Settings) -> Job:
    """Check the rules for ``kind``, then queue the job."""
    with start_lock:
        ensure_no_active_job(game.id, kind)
        _check_inputs_ready(game, kind, settings)
        if kind not in ANALYSIS_KINDS:
            return _submit(game.id, kind, params)
        # Mark the game queued BEFORE the job exists, so a fast worker's "processing"
        # update can never be overwritten by ours.
        db.update_game(game.id, status=GameStatus.QUEUED, error=None)
        try:
            job = _submit(game.id, kind, params)
        except Exception:
            db.update_game(game.id, status=game.status, error=game.error)
            raise
        db.update_game(game.id, latest_job_id=job.id)
        return job


def ensure_no_active_job(game_id: str, kind: JobKind) -> None:
    """409 CONFLICT while an analysis job is queued/running (this blocks every kind: a
    report should use the fresh analysis), or while a report is already being written."""
    blocking = (ANALYSIS_KINDS | {JobKind.REPORT}) if kind == JobKind.REPORT else ANALYSIS_KINDS
    active = next((job for job in db.active_jobs_for_game(game_id) if job.kind in blocking), None)
    if active is None:
        return
    if active.kind in ANALYSIS_KINDS:
        message = "This game's film is being analysed right now."
    else:
        message = "A scouting report is already being written for this game."
    raise ScoutError(
        ErrorCode.CONFLICT,
        message,
        hint="Wait for it to finish, or cancel it first.",
        detail=f"active job {active.id} ({active.kind}, {active.status})",
    )


def _resting_status(game: Game) -> GameStatus:
    """Game status when no analysis job is pending."""
    if has_analysis_file(game.id):
        return GameStatus.READY
    if storage.find_source_video(game.id) is not None or game.video_url:
        return GameStatus.UPLOADED
    return GameStatus.DRAFT


def _check_inputs_ready(game: Game, kind: JobKind, settings: Settings) -> None:
    if kind == JobKind.ANALYZE and storage.find_source_video(game.id) is None and not game.video_url:
        raise ScoutError(ErrorCode.VIDEO_MISSING)
    if kind == JobKind.REANALYZE and not storage.tracking_path(game.id).is_file():
        raise ScoutError(
            ErrorCode.ANALYSIS_NOT_READY,
            "There is no tracking data to re-analyse yet.",
            hint="Run the full film analysis first.",
        )
    if kind == JobKind.REPORT:
        if not has_analysis_file(game.id):
            raise ScoutError(
                ErrorCode.ANALYSIS_NOT_READY,
                "The scouting report needs a finished analysis.",
                hint="Wait for the film analysis to finish, then generate the report.",
            )
        if not settings.claude_configured:
            raise ScoutError(ErrorCode.REPORT_NOT_CONFIGURED)


def _submit(game_id: str, kind: JobKind, params: dict[str, Any]) -> Job:
    """``submit_job`` marks its own row failed when the queue (Redis) is down."""
    try:
        return job_queue.submit_job(game_id, kind, params)
    except ScoutError as exc:
        logger.error("Could not queue %s job for game %s: %s", kind, game_id, exc)
        raise


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post("/games/{game_id}/jobs", response_model=Job, status_code=201)
def create_job(body: JobCreate, game: CurrentGame, settings: SettingsDep) -> Job:
    params = body.params
    if body.kind == JobKind.REPORT:  # the worker hands coach_focus to Claude: same limits as POST /reports
        params = {"coach_focus": validate_model(ReportRequest, params).coach_focus}
    elif "coach_focus" in params:  # an analysis job that writes the report passes it to Claude too
        params = {**params, "coach_focus": validate_model(ReportRequest, params).coach_focus}
    return start_job(game, body.kind, params, settings)


@router.get("/games/{game_id}/jobs", response_model=list[Job])
def list_game_jobs(game: CurrentGame) -> list[Job]:
    return db.list_jobs(game_id=game.id)


@router.get("/jobs/{job_id}", response_model=Job)
def get_job(job_id: JobId) -> Job:
    return db.require_job(job_id)


@router.post("/jobs/{job_id}/cancel", response_model=Job)
def cancel_job(job_id: JobId) -> Job:
    """Queued jobs stop at once; running jobs (and queued ones that already have a GPU call)
    are flagged and the worker stops them and settles the game."""
    job = db.request_cancel(job_id)
    if job.kind in ANALYSIS_KINDS and job.status == JobStatus.CANCELLED:
        _release_game(job)
    return job


@router.post("/jobs/{job_id}/retry", response_model=Job)
def retry_job(job_id: JobId, settings: SettingsDep) -> Job:
    """New job with the same kind and params as a failed or cancelled one.

    An ANALYZE job that failed after the GPU results were saved (stage analyzing or reporting,
    tracking.json.gz on disk) is retried as a REANALYZE: the film is not sent to the GPU again.
    """
    old = db.require_job(job_id)
    if old.status not in (JobStatus.FAILED, JobStatus.CANCELLED):
        raise ScoutError(ErrorCode.CONFLICT, f"Only failed or cancelled jobs can be retried; this one is {old.status}.")
    # Decided under the lock: a film change holds it while it deletes the old tracking.json.gz.
    with start_lock:
        game = db.require_game(old.game_id)
        if _gpu_results_saved(old):
            # What the ANALYZE would still have done: the report (with the coach's focus) when enabled.
            params: dict[str, Any] = {"report": settings.auto_report and settings.claude_configured}
            if old.params.get("coach_focus"):
                params["coach_focus"] = old.params["coach_focus"]
            return start_job(game, JobKind.REANALYZE, params, settings)
        return start_job(game, old.kind, dict(old.params), settings)


def _gpu_results_saved(job: Job) -> bool:
    """A failed ANALYZE job got past the GPU: its tracking.json.gz is installed in the game folder."""
    return (
        job.kind == JobKind.ANALYZE
        and job.status == JobStatus.FAILED
        and job.stage in (JobStage.ANALYZING, JobStage.REPORTING)
        and storage.tracking_path(job.game_id).is_file()
    )


def _release_game(job: Job) -> None:
    """A queued analysis job was cancelled before a worker took it: no worker will
    update the game, so put it back to its resting status here."""
    game = db.get_game(job.game_id)
    if game and game.latest_job_id == job.id and game.status == GameStatus.QUEUED:
        db.update_game(game.id, status=_resting_status(game))
