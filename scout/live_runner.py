"""The worker's side of a live game: one LIVE job per game (docs/LIVE.md).

The job runs for as long as the game does. Every few seconds it

1. polls the GPU calls of the parts being analysed and stores the results of those that finished,
2. sends parts that arrived to the GPU, at most ``SCOUT_LIVE_MAX_PARALLEL`` at a time,
3. when the stream is settled further than the analysis covers (or a roster, a track assignment
   or the team colours changed), joins the parts' results and rebuilds ``analysis.json``,
4. ends the game once the coach ended the stream (or no film arrived for
   ``SCOUT_LIVE_IDLE_MINUTES``) and every part is settled: the parts are joined into the film,
   the joined tracking is saved as ``tracking.json.gz`` and the scouting report is written.

Everything it needs to continue is in the database (``live_segments``: each part's status and its
GPU call), so a worker restart resumes the calls instead of paying for them again.
"""

from __future__ import annotations

import json
import logging
import shutil
from typing import TYPE_CHECKING, Any

from scout import db, live, storage
from scout.analysis import pipeline
from scout.analysis.live_merge import LiveJoin, Part
from scout.errors import ErrorCode, ScoutError
from scout.processing import get_processor
from scout.processing.base import Processor, VideoSource
from scout.processing.mock import DURATION_OPTION, ROSTER_SEED_OPTION, seed_for_job
from scout.schemas import (
    LIVE_SETTLED_STATUSES,
    Game,
    GameAnalysis,
    GameStatus,
    Job,
    JobStage,
    LiveEndReason,
    LiveInfo,
    LiveSegment,
    LiveSegmentStatus,
    LiveState,
    TrackingResult,
)

if TYPE_CHECKING:
    from scout.worker import Worker, _Run

logger = logging.getLogger(__name__)

MAX_SEGMENT_ATTEMPTS = 2  # a part whose GPU call failed with a retryable error is sent once more
# What the GPU answers for film without a game in it (too few players in view, no ball): for a whole
# film an error, for one part of a live game a break (a timeout, halftime, warm-ups).
NO_PLAY_CODES = frozenset({ErrorCode.DETECTION_FAILED, ErrorCode.BALL_NOT_DETECTED})
PROGRESS_WAITING = 5.0
PROGRESS_SPAN = 85.0
PROGRESS_REPORTING = 96.0
NO_FILM_WARNING = "The live game ended before any film arrived."
FILM_NOT_JOINED_WARNING = (
    "The film could not be put together on the server (is ffmpeg installed?). Its parts are kept in the game's folder."
)


class LiveRunner:
    """Runs one claimed LIVE job to its end (or until the worker stops: the next worker resumes it)."""

    def __init__(self, worker: Worker, run: _Run) -> None:
        self.worker = worker
        self.run_ = run
        self.job: Job = run.job
        self.game_id = run.job.game_id
        self.settings = worker.settings
        self.join = LiveJoin(filename=f"live-{self.game_id}.mp4")
        self.joined = 0  # parts of the settled prefix already in the join
        self.merged: TrackingResult | None = None
        self.analysis: GameAnalysis | None = None
        self.inputs_key: str | None = None  # what the analysis was built from besides the tracking
        self.analysis_error: ScoutError | None = None  # why the latest rebuild of the stats failed
        self._processors: dict[str, Processor] = {run.processor.name: run.processor}
        self._last_note: tuple[float, str] | None = None

    # --- the job ------------------------------------------------------------

    def run(self) -> None:
        game = db.require_game(self.game_id)
        live.require_live(game)
        self.run_.processor.check_ready()  # no GPU credentials: fail now, with the reason, not part by part
        if not storage.analysis_path(self.game_id).is_file():
            self.worker._set_game_status(self.game_id, GameStatus.PROCESSING, error=None)
        self.worker._stage(self.job.id, JobStage.GPU_PROCESSING, PROGRESS_WAITING, "Live: waiting for film")
        interval = self.run_.processor.poll_interval
        if interval is None:
            interval = self.settings.modal_poll_seconds
        while not self._tick():
            self.worker._stop.wait(interval)
        self._finish()

    def _tick(self) -> bool:
        """One round. True when the game has ended and every part is settled."""
        self.worker._check_stop()
        self.worker._check_cancel(self.job.id)  # also: the game was deleted, or another worker took the job
        game = db.require_game(self.game_id)
        info = live.require_live(game)
        segments = db.list_live_segments(self.game_id)
        for segment in segments:
            if segment.status == LiveSegmentStatus.PROCESSING:
                self._poll(segment)
        self._submit_waiting(db.list_live_segments(self.game_id))
        segments = db.list_live_segments(self.game_id)
        self._analyse_if_due(game, info, segments)
        self._sync_counts(info, segments)
        pending = [s for s in segments if s.status not in LIVE_SETTLED_STATUSES]
        if info.state != LiveState.CAPTURING and not pending:
            return True
        if info.state == LiveState.CAPTURING:
            self._end_if_idle(info)
        self._note_progress(info, segments)
        return False

    # --- parts on the GPU -----------------------------------------------------

    def _submit_waiting(self, segments: list[LiveSegment]) -> None:
        running = sum(1 for s in segments if s.status == LiveSegmentStatus.PROCESSING)
        for segment in segments:
            if running >= self.settings.live_max_parallel:
                break
            if segment.status != LiveSegmentStatus.UPLOADED:
                continue
            self.worker._check_stop()
            if self._submit(segment):
                running += 1

    def _submit(self, segment: LiveSegment) -> bool:
        path = storage.live_segment_video_path(self.game_id, segment.index)
        if not path.is_file():
            self._failed(segment, ScoutError(ErrorCode.VIDEO_MISSING, "This part of the film is no longer on the server."))
            return False
        processor = self.run_.processor
        video = VideoSource(kind="file", filename=segment.filename or path.name, path=path)
        game = db.require_game(self.game_id)
        try:
            handle = processor.submit(
                job_id=live.segment_job_id(self.job.id, segment.index), video=video, options=self._options(game, segment)
            )
        except ScoutError as exc:
            self.worker._check_stop()  # a stopping worker gives an upload up: not the part's fault
            self.worker._check_cancel(self.job.id)
            self._failed(segment.model_copy(update={"attempts": segment.attempts + 1}), exc)
            return False
        db.save_live_segment(
            segment.model_copy(
                update={
                    "status": LiveSegmentStatus.PROCESSING,
                    "external_id": handle,
                    "processor": processor.name,
                    "attempts": segment.attempts + 1,
                    "progress": 0.0,
                    "error": None,
                    "submitted_at": db.utcnow(),
                }
            )
        )
        logger.info("Job %s: part %d sent to %s as %s", self.job.id, segment.index, processor.name, handle)
        return True

    def _options(self, game: Game, segment: LiveSegment) -> dict[str, Any]:
        """The processing options of one part: the game's, without the overlay video (time on the GPU)."""
        options = self.worker._processing_options(game)
        options["render_video"] = False
        if self.run_.processor.name == "mock":  # demo: parts as long as the film, the same players in each
            options[DURATION_OPTION] = segment.duration_s
            options[ROSTER_SEED_OPTION] = seed_for_job(self.game_id)
        return options

    def _poll(self, segment: LiveSegment) -> None:
        handle = segment.external_id
        if not handle:
            db.save_live_segment(segment.model_copy(update={"status": LiveSegmentStatus.UPLOADED}))
            return
        processor = self._processor(segment.processor)
        status = processor.poll(handle)
        if status.state == "running":
            started = segment.submitted_at or db.utcnow()
            waited_s = (db.utcnow() - started).total_seconds()
            if waited_s > self.settings.live_segment_timeout_minutes * 60 and not status.unreachable:
                self._release(processor, handle, None, cancel=True)
                minutes = self.settings.live_segment_timeout_minutes
                self._failed(segment, ScoutError(ErrorCode.MODAL_TIMEOUT, f"The GPU did not finish this part within {minutes:g} minutes."))
            elif status.progress is not None and abs(status.progress - (segment.progress or 0.0)) >= 5:
                db.save_live_segment(segment.model_copy(update={"progress": round(status.progress, 1)}))
            return
        if status.state == "failed":
            self._release(processor, handle, status.result, cancel=False)
            self._failed(segment, status.error or ScoutError(ErrorCode.PIPELINE_FAILED))
            return
        try:
            self._store_results(processor, handle, status.result or {}, segment)
        except ScoutError as exc:
            self._failed(segment, exc)
        except Exception as exc:
            logger.exception("Job %s: the results of part %d could not be stored", self.job.id, segment.index)
            self._failed(segment, ScoutError(ErrorCode.TRACKING_RESULT_INVALID, detail=str(exc)))
        finally:
            self._release(processor, handle, status.result, cancel=False)

    def _store_results(self, processor: Processor, handle: str, result: dict[str, Any], segment: LiveSegment) -> None:
        incoming = storage.live_dir(self.game_id, create=True) / f".incoming-{segment.index:05d}"
        shutil.rmtree(incoming, ignore_errors=True)
        incoming.mkdir(parents=True)
        try:
            output = processor.fetch(handle, result, incoming)
            if not output.tracking_path.exists():
                raise ScoutError(ErrorCode.TRACKING_RESULT_INVALID, "The GPU results did not include a tracking file.")
            pipeline.load_tracking(output.tracking_path)  # a part that cannot be read fails here, not in every join
            target = storage.live_segment_tracking_path(self.game_id, segment.index)
            output.tracking_path.replace(target)
        finally:
            shutil.rmtree(incoming, ignore_errors=True)
        db.save_live_segment(
            segment.model_copy(
                update={"status": LiveSegmentStatus.DONE, "progress": 100.0, "error": None, "finished_at": db.utcnow()}
            )
        )
        logger.info("Job %s: part %d analysed", self.job.id, segment.index)

    def _failed(self, segment: LiveSegment, error: ScoutError) -> None:
        """Send the part once more after a retryable error; otherwise the game goes on without its stats."""
        if error.code in NO_PLAY_CODES:  # a break in the game, not a failure: no warning, no retry
            logger.info("Job %s: no play found in part %d (%s)", self.job.id, segment.index, error.code)
            db.save_live_segment(
                segment.model_copy(
                    update={
                        "status": LiveSegmentStatus.EMPTY,
                        "external_id": None,
                        "progress": None,
                        "error": error.to_info(),
                        "finished_at": db.utcnow(),
                    }
                )
            )
            return
        if error.retryable and segment.attempts < MAX_SEGMENT_ATTEMPTS:
            logger.warning("Job %s: part %d failed (%s); trying it once more", self.job.id, segment.index, error)
            db.save_live_segment(
                segment.model_copy(update={"status": LiveSegmentStatus.UPLOADED, "external_id": None, "progress": None})
            )
            return
        logger.warning("Job %s: part %d could not be analysed: %s", self.job.id, segment.index, error)
        db.save_live_segment(
            segment.model_copy(
                update={
                    "status": LiveSegmentStatus.FAILED,
                    "external_id": None,
                    "progress": None,
                    "error": error.to_info(),
                    "finished_at": db.utcnow(),
                }
            )
        )
        self.worker._add_warnings(self.run_, [f"Part {segment.index + 1} of the film could not be analysed: {error.title}"])

    def _processor(self, name: str | None) -> Processor:
        """The processor that started a part's call (SCOUT_PROCESSOR may have changed since)."""
        name = name or self.run_.processor.name
        if name not in self._processors:
            try:
                self._processors[name] = get_processor(self.settings, name=name)
            except ValueError:
                self._processors[name] = self.run_.processor
        return self._processors[name]

    def _release(self, processor: Processor, handle: str, result: dict[str, Any] | None, *, cancel: bool) -> None:
        release_call(processor, handle, result, cancel=cancel, cleanup=self.settings.modal_cleanup)

    # --- the analysis ---------------------------------------------------------

    def _analyse_if_due(self, game: Game, info: LiveInfo, segments: list[LiveSegment]) -> None:
        prefix = live.settled_prefix(segments, info, db.utcnow())
        grew = len(prefix) > self.joined
        for part in prefix[self.joined :]:
            tracking = None
            if part.analysed:
                tracking = pipeline.load_tracking(storage.live_segment_tracking_path(self.game_id, part.index))
            self.join.add(Part(part.index, part.duration_s, tracking, empty=part.empty))
        self.joined = len(prefix)
        if self.join.reference is None:
            return  # nothing analysed yet
        key = self._inputs_key(game)
        if not grew and key == self.inputs_key:
            return  # nothing new to build from (also after a rebuild that failed: the same inputs fail again)
        self.inputs_key = key
        try:
            if grew or self.merged is None:
                self.merged = self.join.result()
            self.analysis = self._analyse(game, self.merged)
        except ScoutError as exc:
            # The film keeps coming and must keep being taken: the game goes on with the stats it has, and
            # the next part (or a roster fix) is the next try. A game that ends this way fails in _finish.
            logger.warning("Job %s: the stats could not be rebuilt: %s", self.job.id, exc)
            self.analysis_error = exc
            self.worker._add_warnings(
                self.run_, [f"The stats could not be rebuilt ({exc.title}); the film is still being recorded."]
            )
            return
        self.analysis_error = None
        self.worker._update_game(self.game_id, status=GameStatus.READY, has_analysis=True, error=None)
        current = live.require_live(db.require_game(self.game_id))
        db.update_live(
            self.game_id,
            segments_analysed=self.join.analysed,
            analysed_s=round(self.join.duration_s, 3),
            analysis_version=current.analysis_version + 1,
        )
        logger.info(
            "Job %s: analysis rebuilt from %d part(s), through %.0f s of film", self.job.id, self.join.analysed, self.join.duration_s
        )

    def _sync_counts(self, info: LiveInfo, segments: list[LiveSegment]) -> None:
        """How many parts failed or had no play, as soon as it is known (also before any stats exist:
        twenty minutes of warm-ups are parts without play, not parts still being analysed)."""
        failed = sum(1 for s in segments if s.status == LiveSegmentStatus.FAILED)
        empty = sum(1 for s in segments if s.status == LiveSegmentStatus.EMPTY)
        if (failed, empty) != (info.segments_failed, info.segments_empty):
            db.update_live(self.game_id, segments_failed=failed, segments_empty=empty)

    def _analyse(self, game: Game, tracking: TrackingResult) -> GameAnalysis:
        rosters = db.get_rosters(game.id)
        if self.run_.processor.name == "mock" and not any(r.players for r in rosters.values()):
            rosters = self.worker._save_demo_rosters(game.id, tracking, rosters)
            self.inputs_key = self._inputs_key(game)  # the rosters just saved are not a change by the coach
        analysis = pipeline.analyze_game(tracking, game, rosters, db.list_track_overrides(game.id))
        pipeline.save_analysis(analysis, storage.analysis_path(game.id))
        return analysis

    def _inputs_key(self, game: Game) -> str:
        """Changes when the coach edits something the analysis depends on (rosters, track assignments,
        which team is which, the court calibration), so the stats follow within one round."""
        rosters = db.get_rosters(game.id)
        return json.dumps(
            {
                "rosters": [r.model_dump(mode="json") for r in rosters.values()],
                "overrides": [o.model_dump(mode="json") for o in db.list_track_overrides(game.id)],
                "teams": {str(k): v for k, v in game.team_id_map.items()},
                "color": game.scouted_color,
                "calibration": game.calibration.model_dump(mode="json") if game.calibration else None,
                "names": [game.scouted_team, game.other_team],
            },
            sort_keys=True,
            default=str,
        )

    # --- ending -----------------------------------------------------------------

    def _end_if_idle(self, info: LiveInfo) -> None:
        last = info.last_segment_at or info.started_at
        if last is None:
            return
        idle_s = (db.utcnow() - last).total_seconds()
        if idle_s > self.settings.live_idle_minutes * 60:
            logger.info("Job %s: no film for %.0f minutes; ending the live game", self.job.id, idle_s / 60)
            db.update_live(self.game_id, state=LiveState.FINISHING, end_reason=LiveEndReason.IDLE)

    def _note_progress(self, info: LiveInfo, segments: list[LiveSegment]) -> None:
        received = len(segments)
        done = sum(1 for s in segments if s.status in LIVE_SETTLED_STATUSES)
        if not received:
            progress, message = PROGRESS_WAITING, "Live: waiting for the first part of the film"
        else:
            progress = round(PROGRESS_WAITING + PROGRESS_SPAN * done / received, 1)
            lead = "Live" if info.state == LiveState.CAPTURING else "Finishing"
            message = f"{lead}: {done} of {received} parts analysed"
            if self.join.duration_s > 0:
                message += f", stats through {_clock(self.join.duration_s)}"
        if (progress, message) != self._last_note:
            self._last_note = (progress, message)
            db.update_job(self.job.id, progress=progress, message=message)

    def _finish(self) -> None:
        """The stream is over and every part is settled: the film, the tracking file, the report."""
        segments = db.list_live_segments(self.game_id)
        if not segments:
            live.mark_ended(self.game_id, LiveEndReason.EMPTY)
            self.worker._set_game_status(self.game_id, GameStatus.DRAFT, error=None)
            self.worker._add_warnings(self.run_, [NO_FILM_WARNING])
            return
        warnings = wrap_up(self.game_id, segments, self.merged)
        self.worker._add_warnings(self.run_, warnings)
        if self.analysis_error is not None:  # the film and the tracking file are in place: Re-run analysis can retry
            live.mark_ended(self.game_id, LiveEndReason.FINISHED)
            raise self.analysis_error
        if self.analysis is None:
            # The film is on the server, so a normal analysis of it can still be started.
            broken = [s for s in segments if s.status == LiveSegmentStatus.FAILED and s.error is not None]
            failed = next((s.error for s in broken or segments if s.error is not None), None)
            error = ScoutError.from_code(failed.code, failed.message, failed.detail) if failed else ScoutError(ErrorCode.PIPELINE_FAILED)
            raise ScoutError(
                error.code,
                "None of the film's parts could be analysed.",
                hint=error.hint,
                detail=f"{error.title}: {error.message}",
            )
        live.mark_ended(self.game_id, LiveEndReason.FINISHED)
        if self.settings.auto_report and self.settings.claude_configured:
            from scout.worker import _Cancelled  # a cancel before Claude starts only skips the report

            try:
                self.worker._report_as_warning(self.run_, self.analysis, PROGRESS_REPORTING)
            except _Cancelled:
                self.worker._check_owner(self.job.id)  # deleted with its game: nothing left to finish
                self.worker._add_warnings(self.run_, ["Cancelled after the live game ended: the scouting report was skipped."])


# ---------------------------------------------------------------------------
# Shared with the worker's failure and cancel paths
# ---------------------------------------------------------------------------


def release_call(processor: Processor, handle: str, result: dict[str, Any] | None, *, cancel: bool, cleanup: bool) -> None:
    """Stop a part's GPU call (when it may still run) and delete its remote copies. Never raises."""
    if cancel:
        try:
            processor.cancel(handle)
        except Exception as exc:
            logger.warning("Could not cancel %s: %s", handle, exc)
    if cleanup:
        try:
            processor.cleanup(handle, result)
        except Exception as exc:
            logger.warning("Could not clean up %s: %s", handle, exc)


def wrap_up(game_id: str, segments: list[LiveSegment], merged: TrackingResult | None) -> list[str]:
    """Leave the game as a normal one: ``tracking.json.gz`` from the joined parts and the film from
    the parts' videos. Returns warnings for the job. ``merged=None``: join what is on disk."""
    warnings: list[str] = []
    if merged is None:
        merged = _join_from_disk(game_id, segments)
    if merged is not None:
        storage.write_json(storage.tracking_path(game_id), merged.model_dump_json())
    film = live.join_film(game_id, segments)
    if film is None:
        if any(storage.live_segment_video_path(game_id, s.index).is_file() for s in segments):
            warnings.append(FILM_NOT_JOINED_WARNING)
        return warnings
    try:
        game = db.require_game(game_id)
        started = game.live.started_at if game.live and game.live.started_at else db.utcnow()
        name = f"live-{(game.game_date or started.date()).isoformat()}.mp4"
        db.update_game(game_id, has_video=True, video_filename=name, video_size=film.stat().st_size, video_url=None)
    except ScoutError as exc:
        if exc.code != ErrorCode.NOT_FOUND:
            raise
        return warnings
    shutil.rmtree(storage.live_dir(game_id), ignore_errors=True)  # the film and the tracking file hold it all now
    return warnings


def _join_from_disk(game_id: str, segments: list[LiveSegment]) -> TrackingResult | None:
    parts = []
    for segment in sorted(segments, key=lambda s: s.index):
        path = storage.live_segment_tracking_path(game_id, segment.index)
        tracking = None
        if segment.status == LiveSegmentStatus.DONE and path.is_file():
            try:
                tracking = pipeline.load_tracking(path)
            except ScoutError:
                logger.warning("Live game %s: the results of part %d cannot be read", game_id, segment.index)
        parts.append(Part(segment.index, segment.duration_s, tracking, empty=segment.status == LiveSegmentStatus.EMPTY))
    join = LiveJoin(filename=f"live-{game_id}.mp4")
    for part in parts:
        join.add(part)
    try:
        return join.result()
    except ValueError:
        return None


def abandon(worker: Worker, job: Job, reason: LiveEndReason) -> None:
    """A LIVE job that ends cancelled or failed: stop its GPU calls, keep what there is, end the game.

    Best effort throughout: the job's own ending must not depend on it.
    """
    game_id = job.game_id
    try:
        if db.get_game(game_id) is None:  # deleted: the calls still have to stop
            segments: list[LiveSegment] = []
        else:
            segments = db.list_live_segments(game_id)
        for segment in segments:
            if segment.status != LiveSegmentStatus.PROCESSING:
                continue
            if segment.external_id:
                try:
                    processor = (
                        worker.processor
                        if segment.processor in (None, worker.processor.name)
                        else get_processor(worker.settings, name=segment.processor)
                    )
                    release_call(processor, segment.external_id, None, cancel=True, cleanup=worker.settings.modal_cleanup)
                except Exception as exc:
                    logger.warning("Could not stop the GPU call of part %d: %s", segment.index, exc)
            db.save_live_segment(
                segment.model_copy(update={"status": LiveSegmentStatus.UPLOADED, "external_id": None, "progress": None})
            )
        if segments:
            wrap_up(game_id, segments, None)
        live.mark_ended(game_id, reason)
    except Exception:
        logger.exception("Job %s: could not wrap up the live game %s", job.id, game_id)


def _clock(seconds: float) -> str:
    minutes, rest = divmod(int(seconds), 60)
    return f"{minutes}:{rest:02d}"


__all__ = ["LiveRunner", "abandon", "release_call", "wrap_up"]

