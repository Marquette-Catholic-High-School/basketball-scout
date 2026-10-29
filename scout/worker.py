"""Background worker: runs analyze / reanalyze / report jobs.

Run with ``python -m scout.worker`` (systemd: ``basketball-scout-worker.service``).

The worker claims jobs from the queue (SQLite or Redis) and runs up to
``SCOUT_WORKER_CONCURRENCY`` of them in threads. Job state lives in the ``jobs`` table
and the coach's browser polls it, so every step updates ``stage``, ``progress`` and
``message``::

    ANALYZE    preparing -> uploading_to_gpu -> gpu_processing -> downloading_results
               -> analyzing -> reporting (optional) -> done
    REANALYZE  analyzing (from the stored tracking.json.gz) -> reporting (if asked) -> done
    REPORT     reporting -> done

A restart never pays for a second GPU run: the processor handle (the Modal
FunctionCall id) is saved on the job right after submit, and a claimed job that
already has one resumes polling instead of resubmitting. On SIGTERM the worker stops
claiming, jobs waiting on the GPU leave their polling loop without failing and their
lease is expired on the spot, so the next worker picks them up at once. A worker that
dies without warning is covered by the lease: it runs out and another worker re-claims
the job (after ``max_attempts`` such losses the job fails with ``WORKER_LOST``).
"""

from __future__ import annotations

import argparse
import logging
import os
import shutil
import signal
import socket
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from types import FrameType
from typing import Any
from urllib.parse import urlparse

from scout import __version__, db, storage
from scout.analysis import pipeline, synthetic
from scout.analysis.geometry import load_court_config
from scout.config import Settings, get_settings
from scout.errors import ErrorCode, ScoutError
from scout.jobs.queue import JobQueue, get_queue
from scout.processing import get_processor
from scout.processing.base import Processor, ProcessorOutput, VideoSource
from scout.processing.mock import SEED_OPTION
from scout.reporting import claude_report
from scout.schemas import (
    Game,
    GameAnalysis,
    GameStatus,
    Job,
    JobKind,
    JobStage,
    JobStatus,
    Roster,
    TeamSide,
    TrackingResult,
)

logger = logging.getLogger(__name__)

# Overall progress (0-100) when each ANALYZE stage starts; the GPU stage fills 5..90.
PROGRESS_PREPARING = 1.0
PROGRESS_UPLOADING = 2.0
PROGRESS_GPU_START = 5.0
PROGRESS_GPU_SPAN = 85.0
PROGRESS_DOWNLOADING = 90.0
PROGRESS_ANALYZING = 93.0
PROGRESS_REPORTING = 96.0
PROGRESS_SHORT_JOB_START = 10.0  # REANALYZE / REPORT jobs have a single main stage

WORKER_HEARTBEAT_SECONDS = 30.0
REQUEUE_STALE_SECONDS = 60.0
CLAIM_TIMEOUT_SECONDS = 5.0
QUEUE_RETRY_SECONDS = 5.0
DEMO_ROSTER_SEED = 7  # generate_synthetic_game's default seed, for tracking without a recorded one

_DONE_MESSAGES = {
    JobKind.ANALYZE: "Analysis complete",
    JobKind.REANALYZE: "Analysis updated",
    JobKind.REPORT: "Scouting report ready",
}
_GAME_STATUS_KINDS = frozenset({JobKind.ANALYZE, JobKind.REANALYZE})  # REPORT jobs never change game.status


class _Cancelled(Exception):
    """The coach cancelled the job (or deleted the game) while it was running."""


class _Paused(Exception):
    """The worker is shutting down: hand the job back without failing it."""


@dataclass
class _Run:
    """State shared by the steps of one job run."""

    job: Job
    processor: Processor
    handle: str | None = None  # processor handle, saved as Job.external_id
    result: dict[str, Any] | None = None  # processor response dict once the GPU finished
    gpu_finished: bool = False  # the processor reported a final state (nothing left to cancel)
    warnings: list[str] = field(default_factory=list)


def default_worker_id() -> str:
    return f"{socket.gethostname()}:{os.getpid()}"


class Worker:
    def __init__(
        self,
        settings: Settings | None = None,
        queue: JobQueue | None = None,
        processor: Processor | None = None,
        worker_id: str | None = None,
    ) -> None:
        self.settings = settings or get_settings()
        self.queue = queue or get_queue(self.settings)
        self.processor = processor or get_processor(self.settings)
        self.worker_id = worker_id or default_worker_id()
        # Intervals in seconds; instance attributes so tests can shorten them.
        self.lease_renew_interval = self.settings.job_lease_seconds / 3
        self.heartbeat_interval = WORKER_HEARTBEAT_SECONDS
        self.requeue_interval = REQUEUE_STALE_SECONDS
        self.claim_timeout = CLAIM_TIMEOUT_SECONDS
        self._stop = threading.Event()
        self._heartbeat_stop = threading.Event()
        self._heartbeat_thread: threading.Thread | None = None
        self._running: set[str] = set()  # ids of jobs this worker is running (their leases get renewed)
        self._lock = threading.Lock()

    # --- run loops ----------------------------------------------------------

    def run_forever(self) -> None:
        """Claim and run jobs until :meth:`stop` is called, then wait for running jobs to pause or finish."""
        slots = self.settings.worker_concurrency
        logger.info(
            "Worker %s started (processor=%s, queue=%s, concurrency=%d)",
            self.worker_id,
            self.processor.name,
            self.queue.name,
            slots,
        )
        self._start_heartbeat()
        try:
            with ThreadPoolExecutor(max_workers=slots, thread_name_prefix="job") as pool:
                last_requeue = float("-inf")
                while not self._stop.is_set():
                    if time.monotonic() - last_requeue >= self.requeue_interval:
                        self._requeue_stale()
                        last_requeue = time.monotonic()
                    if self._running_count() >= slots:
                        self._stop.wait(0.5)
                        continue
                    try:
                        job = self.queue.claim(self.worker_id, timeout=self.claim_timeout)
                    except Exception as exc:  # e.g. QUEUE_UNAVAILABLE while Redis restarts: wait and retry
                        logger.warning("Could not claim a job (%s); retrying in %.0fs", exc, QUEUE_RETRY_SECONDS)
                        self._stop.wait(QUEUE_RETRY_SECONDS)
                        continue
                    if job is None:
                        continue
                    if self._stop.is_set():  # the stop arrived while we waited for this job
                        self._release(job)
                        self._ack(job.id)
                        break
                    self._track(job.id)
                    pool.submit(self._run_claimed, job)
                logger.info("Worker %s stopping; %d job(s) still running", self.worker_id, self._running_count())
        finally:
            self._stop_heartbeat()
        logger.info("Worker %s stopped", self.worker_id)

    def run_once(self, timeout: float = 1.0) -> bool:
        """Claim and fully process at most one job synchronously. True if a job ran."""
        job = self.queue.claim(self.worker_id, timeout=timeout)
        if job is None:
            return False
        self._track(job.id)
        self._start_heartbeat()
        try:
            self._run_claimed(job)
        finally:
            self._stop_heartbeat()
        return True

    def stop(self) -> None:
        """Ask the worker to stop: no new claims; GPU jobs are handed back at their next poll."""
        self._stop.set()

    # --- one job ------------------------------------------------------------

    def process_job(self, job: Job) -> Job:
        """Run a claimed job to a final state and return the stored job.

        Exception: if the worker is stopping while the job waits for the GPU, the job is
        handed back instead (still ``running``, lease expired) for the next worker.
        """
        run = _Run(job=job, processor=self.processor, handle=job.external_id, warnings=list(job.warnings))
        logger.info(
            "Job %s (%s, game %s): attempt %d of %d", job.id, job.kind, job.game_id, job.attempts, job.max_attempts
        )
        steps = {
            JobKind.ANALYZE: self._run_analyze,
            JobKind.REANALYZE: self._run_reanalyze,
            JobKind.REPORT: self._run_report,
        }
        try:
            run.processor = self._processor_for(job)
            if job.attempts > job.max_attempts:
                raise ScoutError(ErrorCode.WORKER_LOST)
            if job.cancel_requested:
                raise _Cancelled
            steps[job.kind](run)
        except _Paused:
            self._release(job)
        except _Cancelled:
            self._finish_cancelled(run)
        except ScoutError as exc:
            self._finish_failed(run, exc)
        except Exception as exc:
            logger.exception("Job %s failed unexpectedly", job.id)
            self._finish_failed(run, ScoutError(ErrorCode.INTERNAL_ERROR, detail=_short_traceback(exc)))
        else:
            self._finish_succeeded(run)
        return db.get_job(job.id) or job

    def _run_analyze(self, run: _Run) -> None:
        job = run.job
        self._set_game_status(job.game_id, GameStatus.PROCESSING, error=None)
        if run.handle is None:
            handle = self._submit(run)
        else:
            handle = run.handle
            logger.info("Job %s: resuming %s call %s (not resubmitting)", job.id, run.processor.name, handle)
        run.result = self._wait_for_processor(run, handle)
        self._check_cancel(job.id)
        self._stage(job.id, JobStage.DOWNLOADING, PROGRESS_DOWNLOADING, "Downloading results from the GPU service")
        output = run.processor.fetch(handle, run.result, storage.game_dir(job.game_id, create=True))
        self._install_outputs(job.game_id, output)
        self._add_warnings(run, output.warnings)
        analysis = self._analyze(run, PROGRESS_ANALYZING)
        if self.settings.auto_report and self.settings.claude_configured:
            self._report_as_warning(run, analysis, PROGRESS_REPORTING)

    def _run_reanalyze(self, run: _Run) -> None:
        self._set_game_status(run.job.game_id, GameStatus.PROCESSING, error=None)
        analysis = self._analyze(run, PROGRESS_SHORT_JOB_START)
        if run.job.params.get("report"):
            self._report_as_warning(run, analysis, PROGRESS_REPORTING)

    def _run_report(self, run: _Run) -> None:
        self._write_report(run, None, PROGRESS_SHORT_JOB_START)

    # --- ANALYZE steps --------------------------------------------------------

    def _submit(self, run: _Run) -> str:
        """PREPARING + UPLOADING: build the request, start the GPU job, return its handle."""
        job = run.job
        self._stage(job.id, JobStage.PREPARING, PROGRESS_PREPARING, "Preparing the film")
        game = db.require_game(job.game_id)
        video = self._video_source(game)
        options = self._processing_options(game)
        self._check_cancel(job.id)
        self._check_stop()
        if video.kind == "file":
            note = "Uploading the film to the GPU service (large files take a few minutes)"
        else:
            note = "Sending the video link to the GPU service"
        self._stage(job.id, JobStage.UPLOADING, PROGRESS_UPLOADING, note)
        run.processor.check_ready()
        handle = run.processor.submit(job_id=job.id, video=video, options=options)
        run.handle = handle  # set before saving, so a failure below still cancels the call
        # Saved at once: from here on a worker restart resumes this call instead of paying for another.
        db.update_job(job.id, external_id=handle, processor=run.processor.name)
        logger.info("Job %s: submitted to %s as %s", job.id, run.processor.name, handle)
        return handle

    def _video_source(self, game: Game) -> VideoSource:
        path = storage.find_source_video(game.id)
        if path is not None:
            return VideoSource(kind="file", filename=game.video_filename or path.name, path=path)
        if game.video_url:
            name = game.video_filename or Path(urlparse(game.video_url).path).name or "film.mp4"
            return VideoSource(kind="url", filename=name, url=game.video_url)
        raise ScoutError(ErrorCode.VIDEO_MISSING)

    def _processing_options(self, game: Game) -> dict[str, Any]:
        """The ``options`` block of the processing request (docs/TRACKING_SCHEMA.md)."""
        s = self.settings
        court = load_court_config(s.court_config)
        calibration = None
        if game.calibration is not None:
            c = game.calibration
            calibration = {"matrix": c.matrix, "video_width": c.video_width, "video_height": c.video_height}
        return {
            "analysis_fps": s.analysis_fps,
            "analysis_max_side": s.analysis_max_side,
            "render_video": s.render_annotated_video,
            "render_height": s.render_height,
            "max_duration_s": s.max_video_minutes * 60,
            "court_length_ft": court.length_ft,
            "court_width_ft": court.width_ft,
            "calibration": calibration,
            "detector_weights": s.detector_weights,
            "court_keypoint_weights": s.court_keypoint_weights,
            "scouted_color_hint": game.scouted_color,
        }

    def _wait_for_processor(self, run: _Run, handle: str) -> dict[str, Any]:
        """GPU_PROCESSING: poll until the processor finishes and return its response dict."""
        job, processor = run.job, run.processor
        interval = processor.poll_interval if processor.poll_interval is not None else self.settings.modal_poll_seconds
        # Measured from the first claim, so restarts do not extend the limit.
        started = job.started_at.timestamp() if job.started_at else time.time()
        deadline = started + self.settings.modal_max_wait_hours * 3600
        progress = max(PROGRESS_GPU_START, job.progress) if job.stage == JobStage.GPU_PROCESSING else PROGRESS_GPU_START
        self._stage(job.id, JobStage.GPU_PROCESSING, progress, "Waiting for the GPU")
        while True:
            self._check_stop()
            status = processor.poll(handle)
            if status.state != "running":
                run.gpu_finished = True
                if status.state == "failed":
                    raise status.error or ScoutError(ErrorCode.PIPELINE_FAILED)
                return status.result or {}
            self._check_cancel(job.id)  # also notices a deleted game before we write to its job
            if status.progress is not None:
                pct = min(100.0, max(0.0, status.progress))
                progress = max(progress, PROGRESS_GPU_START + PROGRESS_GPU_SPAN * pct / 100)
            db.update_job(job.id, progress=round(progress, 1), message=status.message or "Processing on the GPU")
            if time.time() > deadline:
                hours = self.settings.modal_max_wait_hours
                raise ScoutError(ErrorCode.MODAL_TIMEOUT, f"The GPU did not finish within {hours:g} hours.")
            self._stop.wait(interval)

    def _install_outputs(self, game_id: str, output: ProcessorOutput) -> None:
        """Make sure the results sit where the rest of the app looks for them."""
        if not output.tracking_path.exists():  # never fall back to a tracking file from an earlier run
            raise ScoutError(ErrorCode.TRACKING_RESULT_INVALID, "The GPU results did not include a tracking file.")
        _move_into_place(output.tracking_path, storage.tracking_path(game_id))
        annotated = storage.annotated_video_path(game_id)
        if output.annotated_video_path is None:
            annotated.unlink(missing_ok=True)  # an overlay from an earlier run would not match the new tracks
        else:
            _move_into_place(output.annotated_video_path, annotated)

    # --- shared steps ---------------------------------------------------------

    def _analyze(self, run: _Run, progress: float) -> GameAnalysis:
        """ANALYZING: tracking.json.gz + rosters + track overrides -> analysis.json; the game becomes READY."""
        job = run.job
        self._check_cancel(job.id)
        tracking_file = storage.tracking_path(job.game_id)
        if not tracking_file.exists():
            raise ScoutError(
                ErrorCode.ANALYSIS_NOT_READY,
                "There is no tracking data for this game yet, so it cannot be analysed.",
                hint="Upload the film and run the full analysis first.",
            )
        self._stage(job.id, JobStage.ANALYZING, progress, "Building the timeline, plays and box score")
        tracking = pipeline.load_tracking(tracking_file)
        game = db.require_game(job.game_id)
        rosters = db.get_rosters(game.id)
        if run.processor.name == "mock" and not any(r.players for r in rosters.values()):
            rosters = self._save_demo_rosters(game.id, tracking, rosters)
        analysis = pipeline.analyze_game(tracking, game, rosters, db.list_track_overrides(game.id))
        pipeline.save_analysis(analysis, storage.analysis_path(game.id))
        self._set_game_status(
            game.id,
            GameStatus.READY,
            has_analysis=True,
            has_annotated_video=storage.annotated_video_path(game.id).exists(),
            error=None,
        )
        logger.info("Job %s: analysis saved for game %s", job.id, game.id)
        return analysis

    def _save_demo_rosters(
        self, game_id: str, tracking: TrackingResult, current: dict[TeamSide, Roster]
    ) -> dict[TeamSide, Roster]:
        """Demo mode: save rosters matching the synthetic players so names show up in the results."""
        try:
            seed = int(tracking.pipeline.options.get(SEED_OPTION, DEMO_ROSTER_SEED))
            demo = synthetic.synthetic_rosters(game_id, seed=seed)
        except Exception:  # a demo nicety must never fail the job
            logger.exception("Could not build demo rosters for game %s", game_id)
            return current
        saved = dict(current)
        for side, roster in demo.items():
            team_name = current[side].team_name or roster.team_name
            saved[side] = db.save_roster(roster.model_copy(update={"game_id": game_id, "team_name": team_name}))
        logger.info("Game %s: saved demo rosters (seed %d) for the synthetic players", game_id, seed)
        return saved

    def _report_as_warning(self, run: _Run, analysis: GameAnalysis, progress: float) -> None:
        """Optional report after an analysis: a failure becomes a job warning, never a failed job."""
        try:
            self._write_report(run, analysis, progress)
        except (_Cancelled, _Paused):
            raise
        except ScoutError as exc:
            logger.warning("Job %s: scouting report not generated: %s", run.job.id, exc)
            self._add_warnings(run, [f"Scouting report not generated: {exc.title}"])
        except Exception:
            logger.exception("Job %s: scouting report crashed", run.job.id)
            self._add_warnings(run, [f"Scouting report not generated: {ScoutError(ErrorCode.INTERNAL_ERROR).title}"])

    def _write_report(self, run: _Run, analysis: GameAnalysis | None, progress: float) -> None:
        """REPORTING: ask Claude for the scouting report and store it."""
        job = run.job
        self._check_cancel(job.id)
        if analysis is None:
            path = storage.analysis_path(job.game_id)
            if not path.exists():
                raise ScoutError(ErrorCode.ANALYSIS_NOT_READY)
            analysis = pipeline.load_analysis(path)
        self._stage(job.id, JobStage.REPORTING, progress, "Writing the scouting report with Claude")
        record = claude_report.generate_report(
            analysis,
            db.require_game(job.game_id),
            db.get_rosters(job.game_id),
            coach_focus=job.params.get("coach_focus"),
            settings=self.settings,
        )
        db.save_report(record)
        logger.info("Job %s: scouting report %s saved", job.id, record.id)

    # --- finishing ------------------------------------------------------------

    def _finish_succeeded(self, run: _Run) -> None:
        self._release_remote(run, cancel=False)
        job = run.job
        self._finish(
            job.id,
            status=JobStatus.SUCCEEDED,
            stage=JobStage.DONE,
            progress=100.0,
            message=_DONE_MESSAGES[job.kind],
            warnings=run.warnings,
            error=None,
        )
        logger.info("Job %s succeeded%s", job.id, f" with warnings: {run.warnings}" if run.warnings else "")

    def _finish_failed(self, run: _Run, error: ScoutError) -> None:
        job = run.job
        logger.warning("Job %s failed: %s%s", job.id, error, f" ({error.detail})" if error.detail else "")
        self._release_remote(run, cancel=True)
        info = error.to_info()
        self._finish(job.id, status=JobStatus.FAILED, error=info, message=error.title, warnings=run.warnings)
        if job.kind in _GAME_STATUS_KINDS:
            self._set_game_status(job.game_id, GameStatus.FAILED, error=info)

    def _finish_cancelled(self, run: _Run) -> None:
        job = run.job
        logger.info("Job %s cancelled", job.id)
        self._release_remote(run, cancel=True)
        self._finish(
            job.id, status=JobStatus.CANCELLED, stage=JobStage.DONE, message="Cancelled", warnings=run.warnings
        )
        if job.kind in _GAME_STATUS_KINDS:
            self._restore_game_status(job.game_id)

    def _release_remote(self, run: _Run, *, cancel: bool) -> None:
        """Stop a GPU call that is still running (cancel / failure) and delete remote copies."""
        if run.handle is None:
            return
        if cancel and not run.gpu_finished:
            try:
                run.processor.cancel(run.handle)
            except Exception as exc:
                logger.warning("Could not cancel %s: %s", run.handle, exc)
        if self.settings.modal_cleanup:
            try:
                run.processor.cleanup(run.handle, run.result)
            except Exception as exc:
                logger.warning("Could not clean up %s: %s", run.handle, exc)

    def _finish(self, job_id: str, **fields: Any) -> None:
        try:
            db.update_job(job_id, finished_at=db.utcnow(), **fields)
        except ScoutError as exc:
            if exc.code != ErrorCode.NOT_FOUND:
                raise
            logger.info("Job %s was deleted while it ran", job_id)

    def _release(self, job: Job) -> None:
        """Hand a job back without failing it; the next worker resumes from its ``external_id``."""
        try:
            current = db.get_job(job.id)
            if current is None:
                return
            # A planned hand-off is not a lost attempt, so it must not count towards WORKER_LOST.
            # worker_id=None also stops our heartbeat from renewing the lease we expire here.
            db.update_job(
                job.id,
                worker_id=None,
                lease_expires_at=time.time(),
                attempts=max(0, current.attempts - 1),
                message="Paused while the worker restarts; it will continue automatically",
            )
        except Exception as exc:  # the lease still runs out, so the job resumes a few minutes later
            logger.warning("Could not hand job %s back (%s); it resumes when its lease expires", job.id, exc)
            return
        logger.info("Job %s handed back for the next worker to resume", job.id)

    def _restore_game_status(self, game_id: str) -> None:
        """After a cancel: READY if an earlier analysis exists, else UPLOADED (DRAFT without any film).

        Decided from the files on disk, the same way the API settles a job cancelled while queued.
        """
        game = db.get_game(game_id)
        if game is None:
            return
        if storage.analysis_path(game_id).is_file():
            status = GameStatus.READY
        elif storage.find_source_video(game_id) is not None or game.video_url:
            status = GameStatus.UPLOADED
        else:
            status = GameStatus.DRAFT
        self._set_game_status(game_id, status)

    # --- small helpers --------------------------------------------------------

    def _processor_for(self, job: Job) -> Processor:
        """The processor that created the job's handle (SCOUT_PROCESSOR may have changed since)."""
        if not job.external_id or not job.processor or job.processor == self.processor.name:
            return self.processor
        try:
            return get_processor(self.settings, name=job.processor)
        except ValueError:
            logger.warning("Job %s names unknown processor %r; using %s", job.id, job.processor, self.processor.name)
            return self.processor

    def _stage(self, job_id: str, stage: JobStage, progress: float, message: str) -> None:
        logger.info("Job %s: %s - %s", job_id, stage.value, message)
        db.update_job(job_id, stage=stage, progress=progress, message=message)

    def _add_warnings(self, run: _Run, warnings: list[str]) -> None:
        new = [w for w in warnings if w not in run.warnings]
        if new:
            run.warnings.extend(new)
            db.update_job(run.job.id, warnings=run.warnings)

    def _check_cancel(self, job_id: str) -> None:
        current = db.get_job(job_id)
        if current is None or current.cancel_requested:
            raise _Cancelled

    def _check_stop(self) -> None:
        if self._stop.is_set():
            raise _Paused

    def _set_game_status(self, game_id: str, status: GameStatus, **changes: Any) -> None:
        try:
            db.update_game(game_id, status=status, **changes)
        except ScoutError as exc:
            if exc.code != ErrorCode.NOT_FOUND:
                raise
            logger.info("Game %s was deleted while its job ran", game_id)

    def _run_claimed(self, job: Job) -> None:
        """Job thread body: run one claimed job, then free its slot and ack it."""
        try:
            self.process_job(job)
        except Exception:  # process_job handles job errors itself; this only catches DB outages
            logger.exception("Job %s could not be finished; its lease will expire and it will be retried", job.id)
        finally:
            with self._lock:
                self._running.discard(job.id)
            self._ack(job.id)

    def _ack(self, job_id: str) -> None:
        try:
            self.queue.ack(job_id, self.worker_id)
        except Exception as exc:
            logger.warning("Could not ack job %s: %s", job_id, exc)

    def _requeue_stale(self) -> None:
        try:
            self.queue.requeue_stale()
        except Exception as exc:
            logger.warning("Could not requeue stale jobs: %s", exc)

    def _track(self, job_id: str) -> None:
        with self._lock:
            self._running.add(job_id)

    def _running_count(self) -> int:
        with self._lock:
            return len(self._running)

    # --- heartbeat --------------------------------------------------------------

    def _start_heartbeat(self) -> None:
        self._heartbeat_stop.clear()
        self._heartbeat_thread = threading.Thread(target=self._heartbeat_loop, name="worker-heartbeat", daemon=True)
        self._heartbeat_thread.start()

    def _stop_heartbeat(self) -> None:
        self._heartbeat_stop.set()
        if self._heartbeat_thread is not None:
            self._heartbeat_thread.join(timeout=10)
            self._heartbeat_thread = None

    def _heartbeat_loop(self) -> None:
        """Renew running jobs' leases every lease/3 s; tell the health check we are alive every 30 s."""
        last_renew = last_beat = float("-inf")
        tick = min(1.0, self.lease_renew_interval, self.heartbeat_interval)
        while True:
            now = time.monotonic()
            if now - last_renew >= self.lease_renew_interval:
                self._renew_leases()
                last_renew = now
            if now - last_beat >= self.heartbeat_interval:
                self._record_heartbeat()
                last_beat = now
            if self._heartbeat_stop.wait(tick):
                return

    def _renew_leases(self) -> None:
        with self._lock:
            job_ids = sorted(self._running)
        for job_id in job_ids:
            try:
                db.heartbeat_job(job_id, self.worker_id, self.settings.job_lease_seconds)
            except Exception as exc:
                logger.warning("Could not renew the lease of job %s: %s", job_id, exc)

    def _record_heartbeat(self) -> None:
        with self._lock:
            running = sorted(self._running)
        info = {
            "pid": os.getpid(),
            "host": socket.gethostname(),
            "version": __version__,
            "processor": self.processor.name,
            "queue": self.queue.name,
            "concurrency": self.settings.worker_concurrency,
            "running": running,
        }
        try:
            db.record_worker_heartbeat(self.worker_id, info)
            # The Redis queue keeps its own heartbeat so it never hands our jobs to someone else.
            self.queue.heartbeat(self.worker_id)
        except Exception as exc:
            logger.warning("Could not record the worker heartbeat: %s", exc)


def _move_into_place(src: Path, dest: Path) -> None:
    if src.exists() and src.resolve() != dest.resolve():
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(src, dest)


def _short_traceback(exc: BaseException) -> str:
    """The last few frames: enough for IT staff to find the bug, short enough for the UI."""
    return "".join(traceback.format_exception(exc, limit=-4))[-2000:]


# --- command line -------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    settings = get_settings()
    _setup_logging(args.log_level or settings.log_level)
    if args.concurrency is not None:
        settings = settings.model_copy(update={"worker_concurrency": args.concurrency})
    settings.ensure_dirs()
    worker = Worker(settings, worker_id=args.worker_id)
    if args.once:
        if not worker.run_once(timeout=CLAIM_TIMEOUT_SECONDS):
            logger.info("No job waiting")
        return 0
    _install_signal_handlers(worker)
    worker.run_forever()
    return 0


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m scout.worker",
        description="Basketball Scout background worker: runs film analysis, re-analysis and report jobs.",
    )
    parser.add_argument("--once", action="store_true", help="process at most one job, then exit")
    parser.add_argument(
        "--concurrency", type=int, help="jobs to run at the same time, 1-16 (default: SCOUT_WORKER_CONCURRENCY)"
    )
    parser.add_argument("--worker-id", help="name used in logs and the jobs table (default: <hostname>:<pid>)")
    parser.add_argument(
        "--log-level",
        type=str.lower,
        choices=["debug", "info", "warning", "error"],
        help="log verbosity (default: SCOUT_LOG_LEVEL)",
    )
    args = parser.parse_args(argv)
    if args.concurrency is not None and not 1 <= args.concurrency <= 16:
        parser.error("--concurrency must be between 1 and 16")
    return args


def _setup_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s [%(threadName)s] %(message)s",
    )


def _install_signal_handlers(worker: Worker) -> None:
    """First SIGTERM / SIGINT: graceful stop. A second one: the default action (quit now)."""

    def handle(signum: int, _frame: FrameType | None) -> None:
        logger.info("Received %s: stopping (send it again to quit immediately)", signal.Signals(signum).name)
        worker.stop()
        signal.signal(signum, signal.SIG_DFL)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, handle)


if __name__ == "__main__":
    raise SystemExit(main())
