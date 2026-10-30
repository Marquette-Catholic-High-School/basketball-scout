"""Fourth review round, jobs area (verification).

* An ANALYZE whose worker died after installing its new results (claimed at analyzing or reporting)
  finishes the analysis despite a cancel, as one whose worker is alive does: from the installed
  results, without downloading them again, with the report skipped and the job warning saying so. It
  ended cancelled, leaving the game with the new tracking and no analysis of it, and "Analyze film"
  (a new GPU run) as the page's only way out.
* A worker whose job was taken over while Claude wrote the report, or whose analysis broke after a
  takeover, leaves the job to the new owner: it neither finishes nor fails it, and keeps the GPU
  results and the new owner's download folder.
* A cancel while Claude writes the report cannot skip it: the report is kept, and the job warning
  says the analysis was finished.
* A cancel during the download keeps the earlier run with the mock, local and Modal processors too.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from modal_app.pipeline import runner
from scout import db, storage
from scout.analysis import pipeline, synthetic
from scout.errors import ErrorCode, ScoutError
from scout.jobs.queue import submit_job
from scout.processing.base import ProcessorOutput
from scout.processing.local import LocalProcessor
from scout.processing.mock import MockProcessor
from scout.reporting import claude_report
from scout.schemas import Game, GameStatus, Job, JobKind, JobStage, JobStatus
from tests.test_processing_mock_local import FakeRunner
from tests.test_processing_modal import fake_modal, processor  # noqa: F401 - fixtures
from tests.test_review3_jobs import _analysed, _results_on_the_volume, _resumed, tiny_synthetic_game
from tests.test_review3_verify_jobs import _installed_tracking_job, _tracking_of
from tests.test_review4_jobs import LATE_CANCEL, NEW_OVERLAY, NewRun, _settings, _state
from tests.test_review4_jobs import LATE_CANCEL_NO_REPORT as LATE_CANCEL_REPORT_SKIPPED
from tests.test_worker import FakeProcessor, env, fakes, filmed_game, make_worker, queue  # noqa: F401 - fixtures

INSTALLED_OVERLAY = b"this run's overlay, installed before its worker died"
W_OTHERS_DOWNLOAD = b"w-other's download"


def _installed_then_died(game: Game, queue, stage: JobStage) -> Job:  # noqa: F811
    """A Full re-analysis whose worker installed the new run (its tracking and overlay in place, the
    earlier run's analysis and track fixes gone) and then died: at ``analyzing`` before it saved the
    new analysis, at ``reporting`` while Claude wrote the report (the new analysis saved)."""
    job = _resumed(game.id, queue, stage)
    storage.write_json(storage.tracking_path(game.id), _tracking_of(job.id))
    storage.annotated_video_path(game.id).write_bytes(INSTALLED_OVERLAY)
    db.clear_track_overrides(game.id)
    if stage == JobStage.ANALYZING:
        storage.analysis_path(game.id).unlink()
        db.update_game(game.id, status=GameStatus.PROCESSING, has_analysis=False, has_annotated_video=True)
    return job


def _cancel_when(job_id: str, real):
    """``real`` (a fetch, or one of the fakes' stand-ins), with the coach clicking Cancel just before it returns."""

    def cancelled_meanwhile(*args: Any, **kwargs: Any) -> Any:
        result = real(*args, **kwargs)
        db.request_cancel(job_id)
        return result

    return cancelled_meanwhile


# --- a cancel after the install also holds when the worker that installed died --------------------


@pytest.mark.parametrize(
    ("stage", "auto_report"),
    [(JobStage.ANALYZING, False), (JobStage.ANALYZING, True), (JobStage.REPORTING, True)],
)
def test_a_job_cancelled_after_its_worker_died_past_the_install_finishes_the_analysis(
    filmed_game, queue, fakes, monkeypatch, stage, auto_report  # noqa: F811
):
    """The job sat at 'analyzing' (or 'reporting') until its lease ran out, and the coach clicked Cancel
    meanwhile. The next worker ended it cancelled: the game kept the new run's tracking without an
    analysis of it ('uploaded', has_analysis false), so the page offered only Analyze film, a new GPU
    run. Once the results are installed, the analysis runs to the end (docs/ARCHITECTURE.md)."""
    settings = _settings(monkeypatch, auto_report=auto_report)
    game = _analysed(filmed_game)
    job = _installed_then_died(game, queue, stage)
    db.request_cancel(job.id)
    gpu = FakeProcessor(annotated=True)
    make_worker(gpu, queue, settings).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.stage, done.error, done.message) == (
        JobStatus.SUCCEEDED,
        JobStage.DONE,
        None,
        "Analysis complete",
    )
    assert done.warnings == [LATE_CANCEL_REPORT_SKIPPED if auto_report else LATE_CANCEL]
    assert gpu.polled == [] and gpu.fetched == []  # the installed results are this run's: no new download
    assert gpu.cancelled == [] and gpu.cleaned == [f"fake:{job.id}"]  # the GPU call had finished
    assert len(fakes.analyze) == 1 and fakes.analyze[0]["tracking"].job_id == job.id
    assert fakes.analyze[0]["overrides"] == [] and fakes.reports == [] and db.list_reports(game.id) == []
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.READY, True, True)
    assert storage.analysis_path(game.id).exists()
    assert storage.annotated_video_path(game.id).read_bytes() == INSTALLED_OVERLAY


def test_a_cancel_during_the_analysis_of_installed_results_finishes_the_analysis(
    filmed_game, queue, fakes, monkeypatch  # noqa: F811
):
    """The next worker downloaded the installed run again and the coach cancelled meanwhile: throwing that
    download away left the game with the new tracking and no analysis of it, as above. Since round 6 the
    next worker downloads nothing (docs/ARCHITECTURE.md, "Job lifecycle"); a cancel during its analysis
    still finishes it."""
    game = _analysed(filmed_game)
    job = _installed_then_died(game, queue, JobStage.ANALYZING)
    gpu = NewRun(annotated=True)  # a download would bring NEW_OVERLAY
    monkeypatch.setattr(pipeline, "analyze_game", _cancel_when(job.id, pipeline.analyze_game))
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.warnings) == (JobStatus.SUCCEEDED, None, [LATE_CANCEL])
    assert gpu.polled == gpu.fetched == [] and not storage.incoming_dir(game.id).exists()
    assert storage.annotated_video_path(game.id).read_bytes() == INSTALLED_OVERLAY
    assert fakes.analyze[0]["tracking"].job_id == job.id and _installed_tracking_job(game.id) == job.id
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.READY, True, True)


def test_a_cancel_still_wins_when_the_workers_keep_dying_after_the_install(filmed_game, queue, fakes):  # noqa: F811
    """(Guard.) Out of attempts: maybe the analysis is what kills the workers, so it is not run again;
    the cancel wins over WORKER_LOST as before, and the game settles from its files."""
    game = _analysed(filmed_game)
    job = _installed_then_died(game, queue, JobStage.ANALYZING)
    db.update_job(job.id, attempts=job.max_attempts)  # the next claim is one too many
    db.request_cancel(job.id)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error) == (JobStatus.CANCELLED, None)
    assert fakes.analyze == []
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.UPLOADED, False, True)


def test_a_cancel_at_the_claim_without_the_installed_tracking_still_ends_cancelled(
    filmed_game, queue, fakes  # noqa: F811
):
    """(Guard.) The job row says 'analyzing' but the game folder has no tracking (restored from an older
    backup): there is nothing installed to finish, so the cancel ends the job."""
    job = _resumed(filmed_game.id, queue, JobStage.ANALYZING)
    db.request_cancel(job.id)
    gpu = FakeProcessor()
    make_worker(gpu, queue).run_once(timeout=1)

    assert (db.get_job(job.id).status, fakes.analyze, gpu.fetched) == (JobStatus.CANCELLED, [], [])
    assert db.get_game(filmed_game.id).status == GameStatus.UPLOADED


# --- the report: a takeover or a cancel while Claude writes it -------------------------------------


def test_a_worker_whose_job_was_taken_over_while_claude_wrote_the_report_leaves_it_to_the_new_owner(
    filmed_game, queue, fakes, monkeypatch  # noqa: F811
):
    """Our lease ran out while the machine slept through the report, and w-other took the job over (it
    downloads the GPU results again). This worker marked w-other's job succeeded and deleted those
    results from the GPU service, so w-other's download failed: a failed game with a full analysis."""
    settings = _settings(monkeypatch, auto_report=True)
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    write = claude_report.generate_report  # the fakes' stand-in

    def slept_through(*args: Any, **kwargs: Any) -> Any:
        db.update_job(job.id, worker_id="w-other")
        return write(*args, **kwargs)

    monkeypatch.setattr(claude_report, "generate_report", slept_through)
    gpu = NewRun()
    make_worker(gpu, queue, settings).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.worker_id) == (JobStatus.RUNNING, None, "w-other")
    assert gpu.cancelled == [] and gpu.cleaned == []  # w-other still needs the GPU's files


def test_a_cancel_while_claude_writes_the_report_keeps_it_and_says_so(
    filmed_game, queue, fakes, monkeypatch  # noqa: F811
):
    """Too late to skip the report: it is kept, and the job no longer ends 'succeeded' without a word
    about the coach's cancel."""
    settings = _settings(monkeypatch, auto_report=True)
    game = _analysed(filmed_game)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    monkeypatch.setattr(claude_report, "generate_report", _cancel_when(job.id, claude_report.generate_report))
    make_worker(NewRun(), queue, settings).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.warnings) == (JobStatus.SUCCEEDED, None, [LATE_CANCEL])
    assert len(db.list_reports(game.id)) == 1
    assert db.get_game(game.id).status == GameStatus.READY


# --- a stale worker whose analysis breaks does not fail the new owner's job ------------------------


@pytest.mark.parametrize(
    "error", [ScoutError(ErrorCode.ANALYSIS_FAILED), RuntimeError("boom")], ids=["scout error", "crash"]
)
def test_a_worker_whose_job_was_taken_over_does_not_fail_it_when_its_analysis_breaks(
    filmed_game, queue, fakes, monkeypatch, error  # noqa: F811
):
    """The machine slept through the analysis, w-other took the job over and started downloading the
    results again, then this worker's analysis broke. It marked w-other's job and the game failed,
    deleted the GPU results w-other was downloading, and removed w-other's download folder."""
    game = _analysed(filmed_game)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    part = storage.incoming_dir(game.id) / ".tracking.json.gz.w-other.part"

    def slept_through_then_broke(*args: Any, **kwargs: Any) -> Any:
        db.update_job(job.id, worker_id="w-other")
        part.parent.mkdir(parents=True, exist_ok=True)
        part.write_bytes(W_OTHERS_DOWNLOAD)
        raise error

    monkeypatch.setattr(pipeline, "analyze_game", slept_through_then_broke)
    gpu = NewRun()
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.worker_id) == (JobStatus.RUNNING, None, "w-other")
    stored = db.get_game(game.id)
    assert (stored.status, stored.error) == (GameStatus.PROCESSING, None)
    assert gpu.cancelled == [] and gpu.cleaned == []
    assert part.read_bytes() == W_OTHERS_DOWNLOAD


def test_a_failure_of_our_own_job_still_fails_it(filmed_game, queue, fakes):  # noqa: F811
    """(Guard.) Nobody took it over: the job and the game fail, the download folder goes."""
    game = _analysed(filmed_game)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    fakes.analyze_error = ScoutError(ErrorCode.ANALYSIS_FAILED)
    gpu = NewRun()
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error.code, done.worker_id) == (JobStatus.FAILED, "ANALYSIS_FAILED", "w-test")
    assert db.get_game(game.id).status == GameStatus.FAILED
    assert gpu.cleaned == [f"fake:{job.id}"] and not storage.incoming_dir(game.id).exists()


# --- a cancel during the download, on every processor ---------------------------------------------


def _gpu(kind: str, job_id: str, request, monkeypatch):
    """The mock, local or Modal processor, with a finished run for ``job_id`` to download."""
    if kind == "mock":
        settings = env(monkeypatch, SCOUT_MOCK_SECONDS="0")
        monkeypatch.setattr(synthetic, "generate_synthetic_game", tiny_synthetic_game)
        monkeypatch.setattr(synthetic, "synthetic_rosters", lambda game_id, seed=7: {})
        return MockProcessor(settings), settings
    if kind == "local":
        settings = request.getfixturevalue("settings")
        pipeline_ = FakeRunner()
        pipeline_.release.set()
        monkeypatch.setattr(runner, "run_pipeline", pipeline_)
        gpu = LocalProcessor(settings)
        gpu.poll_interval = 0.0
        monkeypatch.setattr(gpu, "check_ready", lambda: None)  # no PyTorch here
        return gpu, settings
    modal = request.getfixturevalue("fake_modal")
    gpu = request.getfixturevalue("processor")
    response = _results_on_the_volume(modal, job_id)
    modal.volume.files[f"results/{job_id}/annotated.mp4"] = NEW_OVERLAY
    modal.outcome = {**response, "annotated_video_path": f"results/{job_id}/annotated.mp4"}
    gpu.poll_interval = 0.0
    return gpu, request.getfixturevalue("settings")


@pytest.mark.parametrize("kind", ["mock", "local", "modal"])
def test_a_cancel_during_the_download_keeps_the_earlier_run_on_every_processor(
    filmed_game, queue, fakes, monkeypatch, request, kind  # noqa: F811
):
    """Each processor's fetch() writes into the folder it is given (.incoming/): what it brought is
    thrown away, and the game keeps its earlier tracking, overlay, analysis and track fixes."""
    game = _analysed(filmed_game)
    earlier = _state(game.id)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    gpu, settings = _gpu(kind, job.id, request, monkeypatch)
    fetched: list[list[str]] = []
    fetch = gpu.fetch

    def downloaded(handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        output = fetch(handle, result, dest_dir)
        fetched.append(sorted(path.name for path in dest_dir.iterdir()))
        db.request_cancel(job.id)  # the coach clicks Cancel as the download ends
        return output

    monkeypatch.setattr(gpu, "fetch", downloaded)
    make_worker(gpu, queue, settings).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error) == (JobStatus.CANCELLED, None)
    assert fetched and "tracking.json.gz" in fetched[0]  # the download did happen, into .incoming/
    assert _state(game.id) == earlier and not storage.incoming_dir(game.id).exists()
    assert db.get_game(game.id).status == GameStatus.READY and fakes.analyze == []


def test_the_installed_results_are_used_without_a_cancel_too(filmed_game, queue, fakes):  # noqa: F811
    """Until round 6, without a cancel a job claimed after its install downloaded the run again. Since then
    it goes straight on to the analysis from the installed results (docs/ARCHITECTURE.md, "Job lifecycle")."""
    game = _analysed(filmed_game)
    job = _installed_then_died(game, queue, JobStage.ANALYZING)
    gpu = NewRun(annotated=True)
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.warnings) == (JobStatus.SUCCEEDED, [])
    assert gpu.polled == gpu.fetched == []
    assert storage.annotated_video_path(game.id).read_bytes() == INSTALLED_OVERLAY
    assert db.get_game(game.id).has_analysis is True
