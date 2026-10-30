"""Sixth review round, worker area (verification).

The round's changes, checked with the real lease, heartbeat and run loop instead of a takeover written
into the jobs table or a stop sent before the claim:

* A worker whose machine slept through a REANALYZE's analysis, the report it was writing, a REPORT's
  Claude call or the analysis of results installed before its claim, while another worker took the job
  over and finished it, steps aside when it wakes: the job stays as the new owner finished it
  (docs/ARCHITECTURE.md, "Job lifecycle": a worker whose lease lapsed "steps aside when another worker
  has taken the job over"). A REANALYZE or a REPORT was finished a second time by the stale worker.
* SIGTERM during the analysis of results installed before the claim (``run_forever``'s graceful stop):
  the analysis runs to the end, without polling the GPU call or downloading the results again, with or
  without a cancel.
* Out of attempts after the install (WORKER_LOST, or a cancel that wins over it): the game says its
  tracking is still there, so a Re-run analysis can start.
* A cancel racing the stage write that is a REANALYZE's or a REPORT's point of no return: the answer
  ("Cancelling..." or "too late to stop this job") always matches what the worker then does with the job.

The expected warnings and messages are the docs' words.
"""

from __future__ import annotations

import random
import threading
import time
from typing import Any

import pytest
from fastapi.testclient import TestClient

from scout import db, storage
from scout.analysis import pipeline
from scout.jobs.queue import SQLiteJobQueue, submit_job
from scout.main import create_app
from scout.reporting import claude_report
from scout.schemas import Job, JobKind, JobStage, JobStatus
from tests.test_review3_jobs import _analysed
from tests.test_review4_jobs import NewRun, _settings
from tests.test_review4_verify_jobs import INSTALLED_OVERLAY, _installed_then_died
from tests.test_worker import FakeProcessor, _wait_for, fakes, filmed_game, make_worker, queue  # noqa: F401 - fixtures

# docs/ARCHITECTURE.md, "Job lifecycle".
LATE_CANCEL = "Cancelled after the new GPU results were in place: the analysis was finished."
LATE_REANALYSIS = "Cancelled after the analysis had started: the analysis was finished."
LATE_REPORT = "Cancelled after Claude had started writing the report: the report was kept."
TOO_LATE_TO_STOP = "Cancel requested: too late to stop this job, so it will finish."
CANCELLING = "Cancelling..."


@pytest.fixture
def api(auth_headers):
    """The real API, without a worker."""
    with TestClient(create_app(), headers=auth_headers) as test_client:
        yield test_client


def _finish(job: Job) -> tuple[Any, ...]:
    return job.status, job.stage, job.worker_id, job.finished_at, job.message, job.warnings, job.error


# --- a lease that ran out while the machine slept ---------------------------------------------------

SLEPT_THROUGH = [
    pytest.param(JobKind.ANALYZE, {}, pipeline, "analyze_game", id="analysis-of-installed-results"),
    pytest.param(JobKind.REANALYZE, {}, pipeline, "analyze_game", id="reanalysis"),
    pytest.param(JobKind.REANALYZE, {"report": True}, claude_report, "generate_report", id="reanalysis-report"),
    pytest.param(JobKind.REPORT, {}, claude_report, "generate_report", id="report"),
]


@pytest.mark.parametrize(("kind", "params", "owner", "step"), SLEPT_THROUGH)
def test_a_worker_whose_lease_ran_out_during_the_main_step_leaves_the_job_to_its_new_owner(
    filmed_game, queue, fakes, monkeypatch, kind, params, owner, step  # noqa: F811
):
    """The sleeper's heartbeat stops renewing its lease once it is in the main step; when the lease has run
    out, the next worker claims the job and finishes it. The sleeper then wakes and must not touch it."""
    settings = _settings(monkeypatch, auto_report=True).model_copy(update={"job_lease_seconds": 1})
    short_leases = SQLiteJobQueue(settings, poll_interval=0.02)  # claims (and heartbeats) lease for 1 s
    game = _analysed(filmed_game)
    if kind == JobKind.ANALYZE:
        job = _installed_then_died(game, queue, JobStage.ANALYZING)
    else:
        job = submit_job(game.id, kind, params, queue=queue)
    sleeper = make_worker(NewRun(annotated=True), short_leases, settings)
    sleeper.worker_id = "w-asleep"
    sleeper.lease_renew_interval = sleeper.heartbeat_interval = 0.05
    successor = make_worker(NewRun(annotated=True), short_leases, settings)
    successor.worker_id = "w-next"
    asleep, wake = threading.Event(), threading.Event()
    real = getattr(owner, step)  # the fakes' stand-in

    def machine_sleeps_once(*args: Any, **kwargs: Any) -> Any:
        if not asleep.is_set():  # the sleeper's call; the successor's runs straight through
            sleeper._renew_leases = lambda: None  # type: ignore[method-assign]
            asleep.set()
            assert wake.wait(10)
        return real(*args, **kwargs)

    monkeypatch.setattr(owner, step, machine_sleeps_once)
    sleeping = threading.Thread(target=sleeper.run_once, kwargs={"timeout": 1}, daemon=True)
    sleeping.start()
    try:
        assert asleep.wait(5)
        _wait_for(lambda: db.get_job(job.id).lease_expires_at < time.time())
        assert successor.run_once(timeout=2)
        by_successor = db.get_job(job.id)
    finally:
        wake.set()
        sleeping.join(timeout=10)
    assert not sleeping.is_alive()

    assert (by_successor.status, by_successor.worker_id, by_successor.error) == (JobStatus.SUCCEEDED, "w-next", None)
    assert _finish(db.get_job(job.id)) == _finish(by_successor)  # not finished a second time by the sleeper
    assert sleeper.processor.cancelled == sleeper.processor.cleaned == []  # the GPU call left to the new owner
    if kind == JobKind.ANALYZE:  # both went straight on from the installed results
        assert sleeper.processor.polled == sleeper.processor.fetched == successor.processor.fetched == []
        assert storage.annotated_video_path(game.id).read_bytes() == INSTALLED_OVERLAY


# --- SIGTERM during the analysis of installed results ----------------------------------------------


@pytest.mark.parametrize("cancel", [False, True], ids=["no-cancel", "cancelled"])
@pytest.mark.parametrize("stage", [JobStage.ANALYZING, JobStage.REPORTING])
def test_sigterm_during_the_analysis_of_installed_results_runs_it_to_the_end(
    filmed_game, queue, fakes, monkeypatch, stage, cancel  # noqa: F811
):
    """``systemctl restart`` while the next worker analyses the results its predecessor installed: the stages
    after the GPU run to the end on a graceful stop, and nothing is polled or downloaded again."""
    game = _analysed(filmed_game)
    job = _installed_then_died(game, queue, stage)
    answer = db.request_cancel(job.id).message if cancel else None
    gpu = NewRun(annotated=True)  # a new download would bring NEW_OVERLAY
    worker = make_worker(gpu, queue)
    worker.claim_timeout = 0.05
    analyze = pipeline.analyze_game

    def sigterm_then_analyze(*args: Any, **kwargs: Any) -> Any:
        worker.stop()
        return analyze(*args, **kwargs)

    monkeypatch.setattr(pipeline, "analyze_game", sigterm_then_analyze)
    running = threading.Thread(target=worker.run_forever, daemon=True)
    running.start()
    running.join(timeout=10)
    assert not running.is_alive()

    done = db.get_job(job.id)
    assert (done.status, done.stage, done.error) == (JobStatus.SUCCEEDED, JobStage.DONE, None)
    assert (answer, done.warnings) == ((TOO_LATE_TO_STOP, [LATE_CANCEL]) if cancel else (None, []))
    assert gpu.submitted == gpu.polled == gpu.fetched == gpu.cancelled == []
    assert storage.annotated_video_path(game.id).read_bytes() == INSTALLED_OVERLAY
    assert db.get_game(game.id).has_analysis is True


# --- out of attempts after the install ---------------------------------------------------------------


@pytest.mark.parametrize("cancel", [False, True], ids=["worker-lost", "cancelled"])
@pytest.mark.parametrize("stage", [JobStage.ANALYZING, JobStage.REPORTING])
def test_out_of_attempts_after_the_install_the_game_still_has_its_tracking(
    api, filmed_game, queue, fakes, stage, cancel  # noqa: F811
):
    """Its workers kept dying after the install, so the job is not run again (WORKER_LOST, or cancelled
    when the coach asked for it). The new tracking stays in the game folder, and the game says so: the page
    offers Re-run analysis, which needs no GPU run."""
    game = _analysed(filmed_game)
    job = _installed_then_died(game, queue, stage)
    db.update_job(job.id, attempts=job.max_attempts)  # the next claim is one too many
    if cancel:
        db.request_cancel(job.id)
    make_worker(NewRun(annotated=True), queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert done.status == (JobStatus.CANCELLED if cancel else JobStatus.FAILED)
    assert (done.error.code if done.error else None) == (None if cancel else "WORKER_LOST")
    body = api.get(f"/api/games/{game.id}").json()
    analysed = stage == JobStage.REPORTING  # its analysis was saved before its last worker died
    assert (body.get("has_tracking"), body["has_analysis"]) == (True, analysed)
    if cancel:
        assert body["status"] == ("ready" if analysed else "uploaded")
        assert api.post(f"/api/games/{game.id}/jobs", json={"kind": "reanalyze"}).status_code == 201
    else:
        assert body["status"] == "failed"
        retried = api.post(f"/api/jobs/{job.id}/retry")
        assert (retried.status_code, retried.json()["kind"]) == (200, "reanalyze")


# --- a cancel racing the stage write -------------------------------------------------------------------


@pytest.mark.parametrize(
    ("kind", "stage", "warning"),
    [(JobKind.REANALYZE, JobStage.ANALYZING, LATE_REANALYSIS), (JobKind.REPORT, JobStage.REPORTING, LATE_REPORT)],
)
def test_a_cancel_racing_the_stage_write_is_answered_as_the_worker_then_acts(
    filmed_game, queue, fakes, monkeypatch, kind, stage, warning  # noqa: F811
):
    """The coach's cancel lands a moment before or after the worker writes the stage that is the point of no
    return. "Cancelling..." must end the job cancelled before the analysis (or Claude) ran; "too late to
    stop this job, so it will finish" must end it succeeded, with the docs' warning."""
    game = _analysed(filmed_game)
    rng = random.Random(6)
    worker = make_worker(FakeProcessor(), queue)
    write = worker._stage
    race: dict[str, threading.Event] = {}  # this round's signals
    for name, owner in (("analyze_game", pipeline), ("generate_report", claude_report)):
        step = getattr(owner, name)  # the fakes' stand-in

        def once_answered(*args: Any, _step: Any = step, **kwargs: Any) -> Any:
            assert race["answered"].wait(5)  # the cancel lands before the job can end
            return _step(*args, **kwargs)

        monkeypatch.setattr(owner, name, once_answered)

    delays = {"writer": 0.0}  # this round's head start for the cancel

    def stage_written(job_id: str, stage_: JobStage, progress: float, message: str) -> Job:
        if stage_ == stage:
            race["writing"].set()
            time.sleep(delays["writer"])
        return write(job_id, stage_, progress, message)

    def cancel(job_id: str, delay: float, writing: threading.Event, answered: threading.Event, out: list[str]) -> None:
        assert writing.wait(5)
        time.sleep(delay)
        out.append(db.request_cancel(job_id).message)
        answered.set()

    worker._stage = stage_written  # type: ignore[method-assign]
    outcomes: list[tuple[str, JobStatus, list[str], int]] = []
    for round_ in range(20):
        job = submit_job(game.id, kind, queue=queue)
        race.update(writing=threading.Event(), answered=threading.Event())
        answers: list[str] = []
        # Either side waits a random moment, so the cancel lands just before or just after the stage write.
        delay = rng.random() * 0.002
        delays["writer"], canceller_delay = (delay, 0.0) if round_ % 2 else (0.0, delay)
        steps_before = len(fakes.analyze) + len(fakes.reports)
        canceller = threading.Thread(
            target=cancel, args=(job.id, canceller_delay, race["writing"], race["answered"], answers), daemon=True
        )
        canceller.start()
        assert worker.run_once(timeout=1)
        canceller.join(timeout=5)
        done = db.get_job(job.id)
        steps_run = len(fakes.analyze) + len(fakes.reports) - steps_before
        outcomes.append((answers[0], done.status, done.warnings, steps_run))

    for answer, status, warnings, steps_run in outcomes:
        if answer == CANCELLING:
            assert (status, warnings, steps_run) == (JobStatus.CANCELLED, [], 0)
        else:
            assert (answer, status, warnings, steps_run) == (TOO_LATE_TO_STOP, JobStatus.SUCCEEDED, [warning], 1)
