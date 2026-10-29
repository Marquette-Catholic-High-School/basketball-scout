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
from typing import Any

from fastapi import APIRouter

from scout import db, storage
from scout.api.deps import CurrentGame, JobId, SettingsDep, has_analysis_file
from scout.config import Settings
from scout.errors import ErrorCode, ScoutError
from scout.jobs import queue as job_queue
from scout.schemas import Game, GameStatus, Job, JobCreate, JobKind, JobStage, JobStatus

logger = logging.getLogger(__name__)

ANALYSIS_KINDS = frozenset({JobKind.ANALYZE, JobKind.REANALYZE})

router = APIRouter(tags=["jobs"])


# ---------------------------------------------------------------------------
# Shared rules
# ---------------------------------------------------------------------------


def start_job(game: Game, kind: JobKind, params: dict[str, Any], settings: Settings) -> Job:
    """Check the rules for ``kind``, then queue the job."""
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
    """``submit_job`` writes the job row before handing it to the queue. When the queue
    (Redis) is down, mark that row failed so it cannot block the next attempt."""
    try:
        return job_queue.submit_job(game_id, kind, params)
    except ScoutError as exc:
        for orphan in db.active_jobs_for_game(game_id):
            if orphan.kind == kind and orphan.status == JobStatus.QUEUED:
                db.update_job(
                    orphan.id,
                    status=JobStatus.FAILED,
                    stage=JobStage.DONE,
                    error=exc,
                    message=exc.message,
                    finished_at=db.utcnow(),
                )
        logger.error("Could not queue %s job for game %s: %s", kind, game_id, exc)
        raise


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post("/games/{game_id}/jobs", response_model=Job, status_code=201)
def create_job(body: JobCreate, game: CurrentGame, settings: SettingsDep) -> Job:
    return start_job(game, body.kind, body.params, settings)


@router.get("/games/{game_id}/jobs", response_model=list[Job])
def list_game_jobs(game: CurrentGame) -> list[Job]:
    return db.list_jobs(game_id=game.id)


@router.get("/jobs/{job_id}", response_model=Job)
def get_job(job_id: JobId) -> Job:
    return db.require_job(job_id)


@router.post("/jobs/{job_id}/cancel", response_model=Job)
def cancel_job(job_id: JobId) -> Job:
    """Queued jobs stop at once; running jobs are flagged and the worker stops them."""
    job = db.request_cancel(job_id)
    if job.kind in ANALYSIS_KINDS and job.status == JobStatus.CANCELLED:
        _release_game(job)
    return job


@router.post("/jobs/{job_id}/retry", response_model=Job)
def retry_job(job_id: JobId, settings: SettingsDep) -> Job:
    """New job with the same kind and params as a failed or cancelled one."""
    old = db.require_job(job_id)
    if old.status not in (JobStatus.FAILED, JobStatus.CANCELLED):
        raise ScoutError(ErrorCode.CONFLICT, f"Only failed or cancelled jobs can be retried; this one is {old.status}.")
    return start_job(db.require_game(old.game_id), old.kind, dict(old.params), settings)


def _release_game(job: Job) -> None:
    """A queued analysis job was cancelled before a worker took it: no worker will
    update the game, so put it back to its resting status here."""
    game = db.get_game(job.game_id)
    if game and game.latest_job_id == job.id and game.status == GameStatus.QUEUED:
        db.update_game(game.id, status=_resting_status(game))
