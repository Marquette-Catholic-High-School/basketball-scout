"""Worker end to end with a fake processor; the transform and Claude modules (other
engineers' code) are replaced by small fakes."""

from __future__ import annotations

import os
import socket
import threading
import time
import types
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest

from scout import config, db, storage, worker as worker_module
from scout.analysis import pipeline, synthetic
from scout.errors import ErrorCode, ScoutError
from scout.jobs.queue import SQLiteJobQueue, submit_job
from scout.processing import mock
from scout.processing.base import PollResult, Processor, ProcessorOutput, VideoSource
from scout.processing.mock import MockProcessor, seed_for_job
from scout.reporting import claude_report
from scout.schemas import (
    CourtCalibration,
    Game,
    GameAnalysis,
    GameStatus,
    Job,
    JobKind,
    JobStage,
    JobStatus,
    PipelineInfo,
    ReportRecord,
    Roster,
    RosterPlayer,
    ScoutingReport,
    TeamSide,
    TeamSummary,
    TrackingResult,
    TrackOverride,
)
from scout.worker import Worker
from tests import helpers

RUNNING = PollResult(state="running", progress=None, message="Waiting for a GPU")
DONE = PollResult(
    state="succeeded", progress=100.0, result={"status": "ok", "tracking_path": "results/x/tracking.json.gz"}
)


class FakeProcessor(Processor):
    """Scripted processor: ``polls`` are returned in order (the last one repeats)."""

    name = "fake"
    poll_interval = 0.0

    def __init__(self, polls: list[PollResult] | None = None, *, on_poll=None, annotated: bool = False) -> None:
        self.polls = list(polls or [DONE])
        self.on_poll = on_poll  # called with the poll number (1-based) before answering
        self.annotated = annotated
        self.ready_checks = 0
        self.submitted: list[dict[str, Any]] = []
        self.polled: list[str] = []
        self.fetched: list[str] = []
        self.cancelled: list[str] = []
        self.cleaned: list[str] = []
        self._lock = threading.Lock()  # several job threads share one processor in run_forever

    def check_ready(self) -> None:
        self.ready_checks += 1

    def submit(self, *, job_id: str, video: VideoSource, options: dict[str, Any]) -> str:
        self.submitted.append({"job_id": job_id, "video": video, "options": options})
        return f"fake:{job_id}"

    def poll(self, handle: str) -> PollResult:
        with self._lock:
            self.polled.append(handle)
            number = len(self.polled)
        if self.on_poll:
            self.on_poll(number)
        with self._lock:
            return self.polls.pop(0) if len(self.polls) > 1 else self.polls[0]

    def fetch(self, handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        self.fetched.append(handle)
        tracking = dest_dir / "tracking.json.gz"
        storage.write_json(tracking, helpers.tracking([]).model_dump_json())
        video = None
        if self.annotated:
            video = dest_dir / "annotated.mp4"
            video.write_bytes(b"annotated")
        return ProcessorOutput(tracking_path=tracking, annotated_video_path=video)

    def cancel(self, handle: str) -> None:
        self.cancelled.append(handle)

    def cleanup(self, handle: str, result: dict[str, Any] | None) -> None:
        self.cleaned.append(handle)


def make_analysis(game_id: str) -> GameAnalysis:
    return GameAnalysis(
        game_id=game_id,
        generated_at=datetime.now(UTC),
        video=helpers.video_info(),
        pipeline=PipelineInfo(name="test"),
        teams=[
            TeamSummary(side=TeamSide.SCOUTED, name="Opponent HS"),
            TeamSummary(side=TeamSide.OTHER, name="Rival HS"),
        ],
    )


def tiny_synthetic_game(**_kwargs: Any) -> tuple[TrackingResult, synthetic.SyntheticTruth]:
    """Stand-in for synthetic.generate_synthetic_game (another engineer's module)."""
    return helpers.tracking([]), synthetic.SyntheticTruth()


def make_report(game_id: str) -> ReportRecord:
    sections = {name: [] for name in ScoutingReport.model_fields if name not in {"headline", "executive_summary"}}
    report = ScoutingReport(headline="Stop #3", executive_summary="Fast team.", **sections)
    return ReportRecord(game_id=game_id, model="claude-test", report=report, markdown="# Stop #3")


@pytest.fixture
def fakes(monkeypatch):
    """Replace pipeline.* and claude_report.generate_report; record what they were given."""
    calls = types.SimpleNamespace(analyze=[], reports=[], report_error=None, analyze_error=None)

    def load_tracking(path: Path) -> TrackingResult:
        return TrackingResult.model_validate(storage.read_json(path))

    def analyze_game(tracking, game, rosters, overrides=None, **_kw):
        calls.analyze.append({"tracking": tracking, "game": game, "rosters": rosters, "overrides": overrides})
        if calls.analyze_error:
            raise calls.analyze_error
        return make_analysis(game.id)

    def save_analysis(analysis: GameAnalysis, path: Path) -> None:
        storage.write_text_atomic(path, analysis.model_dump_json())

    def load_analysis(path: Path) -> GameAnalysis:
        return GameAnalysis.model_validate_json(path.read_text())

    def generate_report(analysis, game, rosters, *, coach_focus=None, settings=None, client=None):
        calls.reports.append({"game": game, "coach_focus": coach_focus, "settings": settings})
        if calls.report_error:
            raise calls.report_error
        return make_report(game.id)

    monkeypatch.setattr(pipeline, "load_tracking", load_tracking)
    monkeypatch.setattr(pipeline, "analyze_game", analyze_game)
    monkeypatch.setattr(pipeline, "save_analysis", save_analysis)
    monkeypatch.setattr(pipeline, "load_analysis", load_analysis)
    monkeypatch.setattr(claude_report, "generate_report", generate_report)
    return calls


@pytest.fixture
def updates(monkeypatch):
    """Every db.update_job call the worker makes, in order (fields only)."""
    recorded: list[dict[str, Any]] = []
    real = db.update_job

    def spy(job_id: str, **fields: Any) -> Job:
        recorded.append(fields)
        return real(job_id, **fields)

    monkeypatch.setattr(db, "update_job", spy)
    return recorded


@pytest.fixture
def filmed_game(game) -> Game:
    path = storage.source_video_path(game.id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x00\x00\x00\x18ftypmp42")
    return db.update_game(
        game.id, has_video=True, video_filename="vs-central.mp4", video_size=12, status=GameStatus.UPLOADED
    )


@pytest.fixture
def queue() -> SQLiteJobQueue:
    return SQLiteJobQueue(poll_interval=0.02)


def make_worker(processor: Processor, queue: SQLiteJobQueue, settings: config.Settings | None = None) -> Worker:
    return Worker(settings or config.get_settings(), queue=queue, processor=processor, worker_id="w-test")


def env(monkeypatch, **values: str) -> config.Settings:
    for name, value in values.items():
        monkeypatch.setenv(name, value)
    config.reset_settings()
    return config.get_settings()


def stages(recorded: list[dict[str, Any]]) -> list[JobStage]:
    return [u["stage"] for u in recorded if "stage" in u]


# --- ANALYZE ---------------------------------------------------------------------------


def test_analyze_success_runs_every_stage_in_order(filmed_game, queue, fakes, updates):
    processor = FakeProcessor(
        [
            PollResult(state="running", progress=10.0, message="Detecting players"),
            PollResult(state="running", progress=50.0, message="Reading jersey numbers"),
            DONE,
        ],
        annotated=True,
    )
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    assert make_worker(processor, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.stage, done.progress) == (JobStatus.SUCCEEDED, JobStage.DONE, 100.0)
    assert done.message == "Analysis complete"
    assert (done.external_id, done.processor, done.error) == (f"fake:{job.id}", "fake", None)
    assert done.finished_at is not None
    assert stages(updates) == [
        JobStage.PREPARING,
        JobStage.UPLOADING,
        JobStage.GPU_PROCESSING,
        JobStage.DOWNLOADING,
        JobStage.ANALYZING,
        JobStage.DONE,
    ]
    progress = [u["progress"] for u in updates if "progress" in u]
    assert progress == sorted(progress)
    assert {13.5, 47.5} <= set(progress)  # 5 + 0.85 x pct
    messages = [u.get("message") for u in updates]
    assert "Detecting players" in messages and "Reading jersey numbers" in messages

    # The handle is saved right after submit, before any polling.
    handle_saved = next(i for i, u in enumerate(updates) if "external_id" in u)
    first_gpu_stage = next(i for i, u in enumerate(updates) if u.get("stage") == JobStage.GPU_PROCESSING)
    assert handle_saved < first_gpu_stage

    sent = processor.submitted[0]
    assert sent["video"].kind == "file" and sent["video"].filename == "vs-central.mp4"
    assert sent["video"].path == storage.source_video_path(filmed_game.id)
    assert sent["options"] == {
        "analysis_fps": 15.0,
        "analysis_max_side": 1280,
        "render_video": True,
        "render_height": 720,
        "max_duration_s": 9000.0,
        "court_length_ft": 84.0,
        "court_width_ft": 50.0,
        "calibration": None,
        "detector_weights": None,
        "court_keypoint_weights": None,
        "scouted_color_hint": "dark",
    }
    assert processor.ready_checks == 1
    assert processor.fetched == [f"fake:{job.id}"]
    assert processor.cleaned == [f"fake:{job.id}"] and processor.cancelled == []

    game = db.get_game(filmed_game.id)
    assert (game.status, game.has_analysis, game.has_annotated_video) == (GameStatus.READY, True, True)
    assert game.error is None
    assert storage.tracking_path(game.id).exists() and storage.analysis_path(game.id).exists()
    assert set(fakes.analyze[0]["rosters"]) == {TeamSide.SCOUTED, TeamSide.OTHER}
    assert fakes.analyze[0]["overrides"] == []
    assert fakes.reports == []  # SCOUT_AUTO_REPORT=false in tests


def test_analyze_sends_calibration_and_url_films(game, queue, fakes):
    calibration = CourtCalibration(
        points=[], matrix=helpers.IDENTITY, reprojection_error_ft=0.4, video_width=1920, video_height=1080
    )
    db.update_game(game.id, video_url="https://films.example.org/games/vs-central.mp4", calibration=calibration)
    processor = FakeProcessor()
    submit_job(game.id, JobKind.ANALYZE, queue=queue)
    make_worker(processor, queue).run_once(timeout=1)
    sent = processor.submitted[0]
    assert (sent["video"].kind, sent["video"].url, sent["video"].filename) == (
        "url",
        "https://films.example.org/games/vs-central.mp4",
        "vs-central.mp4",
    )
    assert sent["options"]["calibration"] == {"matrix": helpers.IDENTITY, "video_width": 1920, "video_height": 1080}


def test_resume_with_existing_external_id_never_resubmits(filmed_game, queue, fakes, updates):
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    db.update_job(
        job.id, external_id="fake:earlier-call", processor="fake", stage=JobStage.GPU_PROCESSING, progress=40.0
    )
    updates.clear()
    processor = FakeProcessor()
    make_worker(processor, queue).run_once(timeout=1)

    assert processor.submitted == [] and processor.ready_checks == 0
    assert processor.polled == ["fake:earlier-call"] and processor.fetched == ["fake:earlier-call"]
    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert JobStage.UPLOADING not in stages(updates)
    gpu_stage = next(u for u in updates if u.get("stage") == JobStage.GPU_PROCESSING)
    assert gpu_stage["progress"] == 40.0  # progress does not jump back on resume


def test_resume_uses_the_processor_that_created_the_handle(filmed_game, queue, fakes, monkeypatch):
    env(monkeypatch, SCOUT_MOCK_SECONDS="0")
    monkeypatch.setattr(synthetic, "generate_synthetic_game", tiny_synthetic_game)
    monkeypatch.setattr(synthetic, "synthetic_rosters", lambda game_id, seed=7: {})
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    db.update_job(job.id, external_id=f"mock:{job.id}", processor="mock")
    processor = FakeProcessor()  # the worker now runs a different processor
    make_worker(processor, queue).run_once(timeout=1)
    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert processor.polled == []


def test_cancel_while_waiting_for_the_gpu(filmed_game, queue, fakes):
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    processor = FakeProcessor([RUNNING], on_poll=lambda n: n == 2 and db.request_cancel(job.id))
    make_worker(processor, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.stage, done.message) == (JobStatus.CANCELLED, JobStage.DONE, "Cancelled")
    assert processor.cancelled == [f"fake:{job.id}"]
    assert processor.cleaned == [f"fake:{job.id}"]
    assert len(processor.polled) == 2 and processor.fetched == []
    assert fakes.analyze == []
    assert db.get_game(filmed_game.id).status == GameStatus.UPLOADED  # film, but no analysis


def test_cancel_keeps_an_earlier_analysis_ready(filmed_game, queue, fakes):
    storage.write_text_atomic(storage.analysis_path(filmed_game.id), make_analysis(filmed_game.id).model_dump_json())
    db.update_game(filmed_game.id, has_analysis=True, status=GameStatus.READY)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    processor = FakeProcessor([RUNNING], on_poll=lambda n: db.request_cancel(job.id))
    make_worker(processor, queue).run_once(timeout=1)
    assert db.get_job(job.id).status == JobStatus.CANCELLED
    assert db.get_game(filmed_game.id).status == GameStatus.READY


def test_processor_failure_fails_the_job_with_its_code(filmed_game, queue, fakes):
    oom = ScoutError(ErrorCode.GPU_OOM, "Out of GPU memory at batch size 1")
    processor = FakeProcessor([RUNNING, PollResult(state="failed", error=oom)])
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    make_worker(processor, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert done.status == JobStatus.FAILED
    assert (done.error.code, done.error.retryable) == ("GPU_OOM", True)
    assert done.error.message == "Out of GPU memory at batch size 1"
    assert done.message == "GPU ran out of memory"  # the error title
    assert done.stage == JobStage.GPU_PROCESSING  # shows where it stopped
    assert processor.cancelled == []  # the GPU call is over; nothing to cancel
    assert processor.cleaned == [f"fake:{job.id}"]
    game = db.get_game(filmed_game.id)
    assert game.status == GameStatus.FAILED and game.error.code == "GPU_OOM"


def test_missing_film_fails_before_anything_is_sent(game, queue, fakes):
    processor = FakeProcessor()
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    make_worker(processor, queue).run_once(timeout=1)
    assert db.get_job(job.id).error.code == "VIDEO_MISSING"
    assert processor.submitted == []
    assert db.get_game(game.id).error.code == "VIDEO_MISSING"


def test_processor_not_ready_fails_the_job(filmed_game, queue, fakes):
    def not_ready() -> None:
        raise ScoutError(ErrorCode.MODAL_NOT_CONFIGURED)

    processor = FakeProcessor()
    processor.check_ready = not_ready
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    make_worker(processor, queue).run_once(timeout=1)
    done = db.get_job(job.id)
    assert done.error.code == "MODAL_NOT_CONFIGURED" and "modal token new" in done.error.hint
    assert processor.submitted == []


def test_giving_up_on_a_slow_gpu_cancels_the_call(filmed_game, queue, fakes, monkeypatch):
    settings = env(monkeypatch, SCOUT_MODAL_MAX_WAIT_HOURS="0.000001")
    processor = FakeProcessor([RUNNING])
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    make_worker(processor, queue, settings).run_once(timeout=1)
    done = db.get_job(job.id)
    assert done.status == JobStatus.FAILED and done.error.code == "MODAL_TIMEOUT"
    assert processor.cancelled == [f"fake:{job.id}"]


def test_report_failure_is_only_a_warning(filmed_game, queue, fakes, updates, monkeypatch):
    settings = env(monkeypatch, SCOUT_AUTO_REPORT="true", ANTHROPIC_API_KEY="test-key-not-real")
    fakes.report_error = ScoutError(ErrorCode.REPORT_RATE_LIMITED)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    make_worker(FakeProcessor(), queue, settings).run_once(timeout=1)

    done = db.get_job(job.id)
    assert done.status == JobStatus.SUCCEEDED and done.error is None
    assert done.warnings == ["Scouting report not generated: Claude rate limit reached"]
    assert JobStage.REPORTING in stages(updates)
    assert db.get_game(filmed_game.id).status == GameStatus.READY
    assert db.list_reports(filmed_game.id) == []


def test_auto_report_is_saved(filmed_game, queue, fakes, monkeypatch):
    settings = env(monkeypatch, SCOUT_AUTO_REPORT="true", ANTHROPIC_API_KEY="test-key-not-real")
    job = submit_job(filmed_game.id, JobKind.ANALYZE, {"coach_focus": "We play a 2-3 zone"}, queue=queue)
    make_worker(FakeProcessor(), queue, settings).run_once(timeout=1)
    assert db.get_job(job.id).warnings == []
    assert [r.report.headline for r in db.list_reports(filmed_game.id)] == ["Stop #3"]
    assert fakes.reports[0]["coach_focus"] == "We play a 2-3 zone"
    assert fakes.reports[0]["settings"] is settings


def test_unexpected_errors_become_internal_error(filmed_game, queue, fakes):
    fakes.analyze_error = RuntimeError("kaput")
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)
    done = db.get_job(job.id)
    assert done.status == JobStatus.FAILED and done.error.code == "INTERNAL_ERROR"
    assert "RuntimeError: kaput" in done.error.detail and len(done.error.detail) <= 2000
    assert done.stage == JobStage.ANALYZING
    assert db.get_game(filmed_game.id).status == GameStatus.FAILED


def test_worker_lost_after_too_many_attempts(filmed_game, queue, fakes):
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    # Submitted earlier by a worker that died three times; the next claim makes it attempt 4 of 3.
    db.update_job(job.id, attempts=3, external_id="fake:still-running", processor="fake")
    processor = FakeProcessor()
    make_worker(processor, queue).run_once(timeout=1)
    done = db.get_job(job.id)
    assert done.status == JobStatus.FAILED and done.error.code == "WORKER_LOST"
    assert processor.polled == []
    assert processor.cancelled == ["fake:still-running"]  # do not leave a GPU running for nobody
    assert db.get_game(filmed_game.id).status == GameStatus.FAILED


def test_a_dead_workers_job_that_was_cancelled_is_cancelled_on_reclaim(filmed_game, queue, fakes):
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    assert db.claim_job("w-dead", 60, job_id=job.id)
    db.update_job(job.id, external_id="fake:orphan", processor="fake")
    db.request_cancel(job.id)  # running -> flagged, but its worker is gone
    db.update_job(job.id, lease_expires_at=time.time() - 1)
    processor = FakeProcessor()
    make_worker(processor, queue).run_once(timeout=1)
    assert db.get_job(job.id).status == JobStatus.CANCELLED
    assert processor.cancelled == ["fake:orphan"] and processor.polled == []


def test_game_deleted_while_waiting_for_the_gpu(filmed_game, queue, fakes):
    processor = FakeProcessor([RUNNING], on_poll=lambda n: db.delete_game(filmed_game.id))
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    assert make_worker(processor, queue).run_once(timeout=1)
    assert db.get_job(job.id) is None  # cascaded with the game
    assert processor.cancelled == [f"fake:{job.id}"]


# --- graceful stop -------------------------------------------------------------------------


def test_graceful_stop_leaves_the_job_resumable(filmed_game, queue, fakes):
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    first = FakeProcessor([RUNNING])
    stopping = make_worker(first, queue)
    first.on_poll = lambda n: stopping.stop()
    stopping.run_once(timeout=1)

    paused = db.get_job(job.id)
    assert paused.status == JobStatus.RUNNING and paused.error is None
    assert paused.worker_id is None and paused.lease_expires_at <= time.time()
    assert paused.attempts == 0  # a planned hand-off does not count towards WORKER_LOST
    assert paused.external_id == f"fake:{job.id}" and paused.stage == JobStage.GPU_PROCESSING
    assert "Paused" in paused.message
    assert first.cancelled == [] and first.cleaned == []
    assert db.get_game(filmed_game.id).status == GameStatus.PROCESSING

    second = FakeProcessor()
    make_worker(second, queue).run_once(timeout=1)
    done = db.get_job(job.id)
    assert done.status == JobStatus.SUCCEEDED and done.attempts == 1
    assert second.submitted == [] and second.polled == [f"fake:{job.id}"]


def test_run_forever_runs_two_jobs_at_once_and_stops(filmed_game, queue, fakes, monkeypatch):
    settings = env(monkeypatch, SCOUT_WORKER_CONCURRENCY="2")
    together = threading.Barrier(2, timeout=5)

    def on_poll(n: int) -> None:
        if n <= 2:
            together.wait()  # only passes if both jobs are polling at the same time

    processor = FakeProcessor([RUNNING, RUNNING, DONE], on_poll=on_poll)
    runner = make_worker(processor, queue, settings)
    runner.claim_timeout = 0.05
    jobs = [submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue) for _ in range(2)]
    thread = threading.Thread(target=runner.run_forever, daemon=True)
    thread.start()
    try:
        _wait_for(lambda: all(db.get_job(j.id).status == JobStatus.SUCCEEDED for j in jobs))
        assert db.last_worker_heartbeat() is not None
    finally:
        runner.stop()
        thread.join(timeout=10)
    assert not thread.is_alive()


def test_run_forever_stop_hands_back_a_waiting_gpu_job(filmed_game, queue, fakes):
    processor = FakeProcessor([RUNNING])
    processor.poll_interval = 0.02
    runner = make_worker(processor, queue)
    runner.claim_timeout = 0.05
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    thread = threading.Thread(target=runner.run_forever, daemon=True)
    thread.start()
    try:
        _wait_for(lambda: len(processor.polled) >= 2)
    finally:
        runner.stop()
        thread.join(timeout=10)
    assert not thread.is_alive()
    paused = db.get_job(job.id)
    assert paused.status == JobStatus.RUNNING and paused.worker_id is None and paused.lease_expires_at <= time.time()
    assert processor.cancelled == []


def test_heartbeat_renews_leases_while_a_job_runs(filmed_game, queue, fakes):
    leases: list[float] = []
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)

    def on_poll(n: int) -> None:
        leases.append(db.get_job(job.id).lease_expires_at)
        time.sleep(0.15)

    processor = FakeProcessor([RUNNING, RUNNING, RUNNING, DONE], on_poll=on_poll)
    runner = make_worker(processor, queue)
    runner.lease_renew_interval = runner.heartbeat_interval = 0.02
    runner.run_once(timeout=1)
    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert leases[-1] > leases[0]
    assert db.last_worker_heartbeat() is not None


# --- REANALYZE / REPORT -----------------------------------------------------------------------


def test_reanalyze_rebuilds_from_the_stored_tracking(game, queue, fakes, updates):
    storage.write_json(storage.tracking_path(game.id), helpers.tracking([]).model_dump_json())
    ann = RosterPlayer(jersey="3", first_name="Ann", last_name="Lee")
    roster = db.save_roster(Roster(game_id=game.id, side=TeamSide.SCOUTED, players=[ann]))
    db.set_track_override(game.id, TrackOverride(track_id=7, player_id=roster.players[0].id))
    processor = FakeProcessor()
    job = submit_job(game.id, JobKind.REANALYZE, {"report": True, "coach_focus": "Press them"}, queue=queue)
    make_worker(processor, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.message) == (JobStatus.SUCCEEDED, "Analysis updated")
    assert stages(updates) == [JobStage.ANALYZING, JobStage.REPORTING, JobStage.DONE]
    assert processor.submitted == processor.polled == processor.cleaned == []
    call = fakes.analyze[0]
    assert call["rosters"][TeamSide.SCOUTED].players[0].jersey == "3"
    assert [o.track_id for o in call["overrides"]] == [7]
    assert fakes.reports[0]["coach_focus"] == "Press them"
    assert len(db.list_reports(game.id)) == 1
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.READY, True, False)


def test_reanalyze_without_tracking_data_fails(game, queue, fakes):
    job = submit_job(game.id, JobKind.REANALYZE, queue=queue)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)
    assert db.get_job(job.id).error.code == "ANALYSIS_NOT_READY"
    assert db.get_game(game.id).status == GameStatus.FAILED


def test_report_job_saves_a_report_and_leaves_the_game_alone(game, queue, fakes, updates):
    storage.write_text_atomic(storage.analysis_path(game.id), make_analysis(game.id).model_dump_json())
    db.update_game(game.id, status=GameStatus.READY, has_analysis=True)
    job = submit_job(game.id, JobKind.REPORT, {"coach_focus": "Who handles the press?"}, queue=queue)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.message) == (JobStatus.SUCCEEDED, "Scouting report ready")
    assert stages(updates) == [JobStage.REPORTING, JobStage.DONE]
    assert fakes.reports[0]["coach_focus"] == "Who handles the press?"
    assert len(db.list_reports(game.id)) == 1
    assert db.get_game(game.id).status == GameStatus.READY


def test_report_job_failure_fails_the_job_but_not_the_game(game, queue, fakes):
    storage.write_text_atomic(storage.analysis_path(game.id), make_analysis(game.id).model_dump_json())
    db.update_game(game.id, status=GameStatus.READY, has_analysis=True)
    fakes.report_error = ScoutError(ErrorCode.REPORT_AUTH_FAILED)
    job = submit_job(game.id, JobKind.REPORT, queue=queue)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)
    assert db.get_job(job.id).error.code == "REPORT_AUTH_FAILED"
    game_after = db.get_game(game.id)
    assert game_after.status == GameStatus.READY and game_after.error is None


def test_report_job_needs_an_analysis(game, queue, fakes):
    job = submit_job(game.id, JobKind.REPORT, queue=queue)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)
    assert db.get_job(job.id).error.code == "ANALYSIS_NOT_READY"
    assert fakes.reports == []


# --- demo mode (mock processor) ----------------------------------------------------------------


@pytest.fixture
def demo(monkeypatch):
    """MockProcessor with no simulated delay; synthetic.py (another engineer's) is faked."""
    env(monkeypatch, SCOUT_MOCK_SECONDS="0")
    seeds: list[int] = []

    def rosters(game_id: str, *, seed: int = 7) -> dict[TeamSide, Roster]:
        seeds.append(seed)
        jerseys = {TeamSide.SCOUTED: "3", TeamSide.OTHER: "10"}
        return {
            side: Roster(game_id=game_id, side=side, team_name=f"Synthetic {side}", players=[RosterPlayer(jersey=j)])
            for side, j in jerseys.items()
        }

    monkeypatch.setattr(synthetic, "generate_synthetic_game", tiny_synthetic_game)
    monkeypatch.setattr(synthetic, "synthetic_rosters", rosters)
    monkeypatch.setattr(mock, "probe_duration", lambda path: None)  # never shell out to ffprobe in tests
    return seeds


def test_demo_mode_adds_matching_rosters(filmed_game, queue, fakes, demo):
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    make_worker(MockProcessor(), queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert demo == [seed_for_job(job.id)]  # same seed the mock used for the synthetic game
    saved = db.get_rosters(filmed_game.id)
    assert saved[TeamSide.SCOUTED].team_name == "Opponent HS"  # the coach's team names are kept
    assert [p.jersey for p in saved[TeamSide.OTHER].players] == ["10"]
    assert fakes.analyze[0]["rosters"][TeamSide.SCOUTED].players[0].jersey == "3"


def test_demo_mode_keeps_a_real_roster(filmed_game, queue, fakes, demo):
    real = RosterPlayer(jersey="22", first_name="Real")
    db.save_roster(Roster(game_id=filmed_game.id, side=TeamSide.SCOUTED, players=[real]))
    submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    make_worker(MockProcessor(), queue).run_once(timeout=1)
    assert demo == []
    assert [p.jersey for p in db.get_roster(filmed_game.id, TeamSide.SCOUTED).players] == ["22"]


# --- command line ------------------------------------------------------------------------------


def test_main_once_processes_one_job(filmed_game, fakes, demo):
    job = submit_job(filmed_game.id, JobKind.ANALYZE)
    assert worker_module.main(["--once", "--worker-id", "cli-test", "--log-level", "WARNING"]) == 0
    done = db.get_job(job.id)
    assert done.status == JobStatus.SUCCEEDED and done.worker_id == "cli-test"


def test_main_rejects_bad_concurrency(capsys):
    with pytest.raises(SystemExit) as exc:
        worker_module.main(["--concurrency", "0"])
    assert exc.value.code == 2
    assert "between 1 and 16" in capsys.readouterr().err


def test_default_worker_id():
    assert worker_module.default_worker_id() == f"{socket.gethostname()}:{os.getpid()}"


def _wait_for(condition, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while not condition():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met in time")
        time.sleep(0.02)
