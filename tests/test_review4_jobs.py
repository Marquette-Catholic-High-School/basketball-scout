"""Fourth review round, jobs area.

* A cancel stops an ANALYZE only until its new results are installed: a cancel during the download
  throws the download away and the game keeps its earlier run; after the install the analysis is
  finished, the cancel only skips the report, and a job warning says so.
* A GPU poll or a results download that fails after a cancel ends the job cancelled, not failed; a
  worker whose job another worker has taken over leaves it to them.
* An ANALYZE that ends without installing removes what its download left in ``.incoming/``.
* Installing a Full re-analysis deletes the earlier run's analysis.json, in an order that leaves the
  game consistent wherever a killed worker stops.
"""

from __future__ import annotations

import errno
import shutil
import time
from pathlib import Path
from typing import Any

import pytest

from scout import config, db, storage
from scout.analysis import pipeline
from scout.errors import ErrorCode, ScoutError
from scout.jobs.queue import submit_job
from scout.processing.base import PollResult, ProcessorOutput
from scout.schemas import Game, GameCreate, GameStatus, JobKind, JobStage, JobStatus
from scout.worker import Worker
from tests.test_api_jobs import client  # noqa: F401 - fixture
from tests.test_review3_jobs import OLD_FIX, _analysed, _resumed
from tests.test_review3_verify_jobs import FIRST_OVERLAY, _installed_tracking_job, _Killed, _tracking_of
from tests.test_worker import (  # noqa: F401 - fixtures
    RUNNING,
    FakeProcessor,
    env,
    fakes,
    filmed_game,
    make_worker,
    queue,
)

# The job warnings docs/ARCHITECTURE.md ("Job lifecycle") gives for a cancel after the install.
LATE_CANCEL = "Cancelled after the new GPU results were in place: the analysis was finished."
LATE_CANCEL_NO_REPORT = (
    "Cancelled after the new GPU results were in place: the analysis was finished, the scouting report was skipped."
)
NEW_OVERLAY = b"second run's overlay"
OOM = PollResult(state="failed", error=ScoutError(ErrorCode.GPU_OOM, "Out of GPU memory at batch size 1"))
MODAL_DOWNLOAD_FAILED = "Downloading the GPU results from Modal failed."


class NewRun(FakeProcessor):
    """The GPU's new run: its tracking names the job that made it, and its overlay is its own."""

    def fetch(self, handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        self.fetched.append(handle)
        tracking = dest_dir / "tracking.json.gz"
        storage.write_json(tracking, _tracking_of(handle.removeprefix("fake:")))
        video = None
        if self.annotated:
            video = dest_dir / "annotated.mp4"
            video.write_bytes(NEW_OVERLAY)
        return ProcessorOutput(tracking_path=tracking, annotated_video_path=video)


def _state(game_id: str) -> dict[str, Any]:
    """What the coach's pages are built from: the game's files, track overrides and file flags."""
    paths = (storage.tracking_path(game_id), storage.annotated_video_path(game_id), storage.analysis_path(game_id))
    game = db.get_game(game_id)
    return {
        "files": {path.name: path.read_bytes() if path.exists() else None for path in paths},
        "overrides": db.list_track_overrides(game_id),
        "flags": (game.has_analysis, game.has_annotated_video),
    }


def _settings(monkeypatch, *, auto_report: bool) -> config.Settings:
    if not auto_report:
        return config.get_settings()  # SCOUT_AUTO_REPORT=false in tests
    return env(monkeypatch, SCOUT_AUTO_REPORT="true", ANTHROPIC_API_KEY="test-key-not-real")


def _cancel_after_the_install(worker: Worker, job_id: str) -> None:
    install = worker._install_outputs

    def install_then_cancel(job, output) -> None:
        install(job, output)
        db.request_cancel(job_id)

    worker._install_outputs = install_then_cancel


def _cancel_during_the_analysis(monkeypatch, job_id: str) -> None:
    analyze = pipeline.analyze_game  # the fakes' stand-in

    def cancelled_while_analysing(*args: Any, **kwargs: Any) -> Any:
        db.request_cancel(job_id)
        return analyze(*args, **kwargs)

    monkeypatch.setattr(pipeline, "analyze_game", cancelled_while_analysing)


# --- a cancel before the install keeps the earlier run; after it, the analysis is finished --------


@pytest.mark.parametrize("new_overlay", [True, False])
def test_a_cancel_during_the_download_keeps_the_earlier_run(filmed_game, queue, fakes, new_overlay):  # noqa: F811
    """It was noticed only when the analysis started, after the install: the game ended 'ready' with the
    new run's tracking and overlay, its track fixes cleared, and the earlier run's analysis (with that
    run's track ids) on the Roster page. A fix made there was applied to the new run's different tracks
    by the next Re-run analysis: wrong stats with no error."""
    game = _analysed(filmed_game)
    earlier = _state(game.id)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    gpu = NewRun(annotated=new_overlay)
    fetch = gpu.fetch

    def cancelled_while_downloading(handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        output = fetch(handle, result, dest_dir)
        db.request_cancel(job.id)  # the coach clicks Cancel while the overlay downloads
        return output

    gpu.fetch = cancelled_while_downloading
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.stage, done.error, done.warnings) == (JobStatus.CANCELLED, JobStage.DONE, None, [])
    assert _state(game.id) == earlier  # the tracking, overlay, analysis.json, track fixes and flags
    assert db.get_game(game.id).status == GameStatus.READY
    assert not storage.incoming_dir(game.id).exists()  # the download is thrown away
    assert fakes.analyze == [] and gpu.cleaned == [f"fake:{job.id}"]


@pytest.mark.parametrize("auto_report", [False, True])
@pytest.mark.parametrize("cancelled", ["after the install", "during the analysis"])
def test_a_cancel_after_the_install_finishes_the_analysis(
    filmed_game, queue, fakes, monkeypatch, cancelled, auto_report  # noqa: F811
):
    """With the new tracking in place, a stop leaves the game without an analysis of it (before this
    round: with the earlier run's analysis and its track ids). The job ended 'cancelled' when the
    analysis or the report started; without a report due, a cancel during the analysis was ignored
    without a word. Now the analysis is finished and only the report is skipped."""
    settings = _settings(monkeypatch, auto_report=auto_report)
    game = _analysed(filmed_game)
    earlier_analysis = storage.analysis_path(game.id).read_bytes()
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    worker = make_worker(NewRun(annotated=True), queue, settings)
    if cancelled == "after the install":
        _cancel_after_the_install(worker, job.id)
    else:
        _cancel_during_the_analysis(monkeypatch, job.id)
    worker.run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.stage, done.error, done.message) == (
        JobStatus.SUCCEEDED,
        JobStage.DONE,
        None,
        "Analysis complete",
    )
    assert done.warnings == [LATE_CANCEL_NO_REPORT if auto_report else LATE_CANCEL]
    assert len(fakes.analyze) == 1 and fakes.analyze[0]["tracking"].job_id == job.id  # of the new run
    assert fakes.reports == [] and db.list_reports(game.id) == []
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.READY, True, True)
    assert storage.analysis_path(game.id).read_bytes() != earlier_analysis
    assert storage.annotated_video_path(game.id).read_bytes() == NEW_OVERLAY


def test_a_cancel_the_reports_own_check_notices_is_the_same_warning(
    filmed_game, queue, fakes, monkeypatch  # noqa: F811
):
    """The coach clicked Cancel between the worker's check after the analysis and the report's own check:
    the job must not end 'cancelled' with the new analysis saved."""
    settings = _settings(monkeypatch, auto_report=True)
    game = _analysed(filmed_game)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    worker = make_worker(NewRun(), queue, settings)
    report = worker._report_as_warning

    def cancelled_as_the_report_starts(run, analysis, progress) -> None:
        db.request_cancel(job.id)
        report(run, analysis, progress)

    worker._report_as_warning = cancelled_as_the_report_starts
    worker.run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.warnings) == (JobStatus.SUCCEEDED, None, [LATE_CANCEL_NO_REPORT])
    assert fakes.reports == [] and db.list_reports(game.id) == []
    assert db.get_game(game.id).status == GameStatus.READY


@pytest.mark.parametrize("kind", [JobKind.REANALYZE, JobKind.REPORT])
def test_a_reanalysis_or_a_report_still_stops_for_a_cancel(filmed_game, queue, fakes, kind):  # noqa: F811
    """(Guard.) They install nothing: a cancel before their main step still ends them cancelled."""
    game = _analysed(filmed_game)
    earlier = _state(game.id)
    job = submit_job(game.id, kind, queue=queue)
    claimed = db.claim_job("w-test", 60, job_id=job.id)
    db.request_cancel(job.id)  # running: flagged for its worker
    make_worker(FakeProcessor(), queue).process_job(claimed)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.warnings) == (JobStatus.CANCELLED, None, [])
    assert fakes.analyze == [] and fakes.reports == []
    assert _state(game.id) == earlier and db.get_game(game.id).status == GameStatus.READY


def test_a_reanalysis_cancelled_during_its_analysis_finishes_it_and_skips_the_report(
    filmed_game, queue, fakes, monkeypatch  # noqa: F811
):
    """No report. Until round 6 the job then ended cancelled over the analysis it had saved; since then a
    cancel no longer stops a REANALYZE once its analysis has started (docs/ARCHITECTURE.md, "Job
    lifecycle"): it succeeds, and the job warning says the report was skipped."""
    settings = _settings(monkeypatch, auto_report=True)
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, JobKind.REANALYZE, {"report": True}, queue=queue)
    _cancel_during_the_analysis(monkeypatch, job.id)
    make_worker(FakeProcessor(), queue, settings).run_once(timeout=1)

    done = db.get_job(job.id)
    skipped = "Cancelled after the analysis had started: the analysis was finished, the scouting report was skipped."
    assert (done.status, done.warnings) == (JobStatus.SUCCEEDED, [skipped])
    assert len(fakes.analyze) == 1 and fakes.reports == []
    assert db.get_game(filmed_game.id).status == GameStatus.READY


def test_a_worker_whose_job_was_taken_over_during_the_analysis_leaves_it_to_the_new_owner(
    filmed_game, queue, fakes, monkeypatch  # noqa: F811
):
    """Our lease ran out while the machine slept through the analysis, and w-other took the job over (it
    downloads the same GPU results again). This worker went on to mark the job succeeded and delete those
    results from the GPU service, so w-other's download failed, and the job with it."""
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    analyze = pipeline.analyze_game

    def slept_through(*args: Any, **kwargs: Any) -> Any:
        db.update_job(job.id, worker_id="w-other")
        return analyze(*args, **kwargs)

    monkeypatch.setattr(pipeline, "analyze_game", slept_through)
    gpu = NewRun()
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.worker_id) == (JobStatus.RUNNING, None, "w-other")
    assert gpu.cancelled == [] and gpu.cleaned == []  # w-other still needs the GPU's files


# --- a GPU poll or download that fails after a cancel -----------------------------------------


def test_a_gpu_call_that_fails_after_a_cancel_ends_the_job_cancelled(filmed_game, queue, fakes):  # noqa: F811
    """The coach cancelled while the GPU worked, and the call failed before the worker's next look at the
    job (out of memory, or stopped on Modal): the job and the game ended 'failed', with a Retry."""
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    gpu = FakeProcessor([RUNNING, OOM], on_poll=lambda n: n == 2 and db.request_cancel(job.id))
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.stage, done.error, done.message) == (
        JobStatus.CANCELLED,
        JobStage.DONE,
        None,
        "Cancelled",
    )
    assert gpu.cancelled == [] and gpu.cleaned == [f"fake:{job.id}"]  # the call is over: nothing to stop
    game = db.get_game(filmed_game.id)
    assert (game.status, game.error) == (GameStatus.UPLOADED, None)


def test_a_download_that_fails_after_a_cancel_ends_the_job_cancelled(filmed_game, queue, fakes):  # noqa: F811
    game = _analysed(filmed_game)
    earlier = _state(game.id)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    gpu = NewRun()

    def cancelled_then_broken(handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        storage.write_json(dest_dir / "tracking.json.gz", _tracking_of(job.id))
        db.request_cancel(job.id)
        raise ScoutError(ErrorCode.MODAL_REMOTE_ERROR, MODAL_DOWNLOAD_FAILED)

    gpu.fetch = cancelled_then_broken
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error) == (JobStatus.CANCELLED, None)
    stored = db.get_game(game.id)
    assert (stored.status, stored.error) == (GameStatus.READY, None)
    assert _state(game.id) == earlier and not storage.incoming_dir(game.id).exists()


@pytest.mark.parametrize("also_cancelled", [False, True])
def test_a_worker_whose_job_was_taken_over_leaves_a_failed_gpu_call_to_the_new_owner(
    filmed_game, queue, fakes, also_cancelled  # noqa: F811
):
    """Our lease ran out while the machine slept, and w-other took the job over. When the GPU call then
    failed, this worker marked w-other's job and the game failed and deleted the call's files on the GPU
    service (with or without a cancel from the coach meanwhile: w-other settles that too)."""
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)

    def taken_over(poll: int) -> None:
        if poll == 2:
            db.update_job(job.id, worker_id="w-other")
            if also_cancelled:
                db.request_cancel(job.id)

    gpu = FakeProcessor([RUNNING, OOM], on_poll=taken_over)
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.worker_id) == (JobStatus.RUNNING, None, "w-other")
    game = db.get_game(filmed_game.id)
    assert (game.status, game.error) == (GameStatus.PROCESSING, None)
    assert gpu.cancelled == [] and gpu.cleaned == []


# --- an ANALYZE that ends without installing removes .incoming/ --------------------------------


def _partial_download(job_id: str, error: BaseException):
    """A fetch() that writes part of the results, then stops with ``error``."""

    def fetch(handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        storage.write_json(dest_dir / "tracking.json.gz", _tracking_of(job_id))  # the tracking comes first
        (dest_dir / ".annotated.mp4.k3x9.part").write_bytes(b"half an overlay")
        raise error

    return fetch


@pytest.mark.parametrize(
    "error",
    [ScoutError(ErrorCode.MODAL_REMOTE_ERROR, MODAL_DOWNLOAD_FAILED), OSError(errno.ENOSPC, "No space left on device")],
    ids=["modal error", "disk full"],
)
def test_a_failed_download_removes_its_partial_files(filmed_game, queue, fakes, error):  # noqa: F811
    """They stayed in the game's hidden .incoming/ folder (half of a 1.5 GB overlay, say) until the next
    Full re-analysis or a new film."""
    game = _analysed(filmed_game)
    earlier = _state(game.id)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    gpu = FakeProcessor()
    gpu.fetch = _partial_download(job.id, error)
    make_worker(gpu, queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.FAILED
    assert not storage.incoming_dir(game.id).exists()
    assert _state(game.id) == earlier


@pytest.mark.parametrize("ending", ["cancelled", "out of attempts"])
def test_a_job_that_ends_after_a_killed_download_removes_its_partial_files(
    filmed_game, queue, fakes, ending  # noqa: F811
):
    """The worker was killed mid-download (a restart during a long overlay download); the coach then
    cancelled, or the job ran out of attempts. The next worker ended the job without installing and left
    the partial files behind for good."""
    game = _analysed(filmed_game)
    earlier = _state(game.id)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    gpu = FakeProcessor()
    gpu.fetch = _partial_download(job.id, _Killed())
    with pytest.raises(_Killed):
        make_worker(gpu, queue).run_once(timeout=1)
    assert storage.incoming_dir(game.id).exists()  # what the killed download left
    if ending == "cancelled":
        db.request_cancel(job.id)  # before the next worker picks the job up
    else:
        db.update_job(job.id, attempts=job.max_attempts)  # the next claim is one too many
    db.update_job(job.id, lease_expires_at=time.time() - 1)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)

    assert db.get_job(job.id).status == (JobStatus.CANCELLED if ending == "cancelled" else JobStatus.FAILED)
    assert not storage.incoming_dir(game.id).exists()
    assert _state(game.id) == earlier


@pytest.mark.parametrize("download", ["breaks", "completes"])
def test_a_worker_that_steps_aside_leaves_the_download_folder_to_the_new_owner(
    filmed_game, queue, fakes, download  # noqa: F811
):
    """(Guard.) w-other took the job over during our download and downloads into the same folder."""
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    gpu = NewRun()
    fetch = gpu.fetch

    def slept_through(handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        db.update_job(job.id, worker_id="w-other")
        (dest_dir / ".tracking.json.gz.w-other.part").write_bytes(b"w-other's download")
        if download == "breaks":
            raise ScoutError(ErrorCode.MODAL_REMOTE_ERROR, MODAL_DOWNLOAD_FAILED)
        return fetch(handle, result, dest_dir)

    gpu.fetch = slept_through
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.worker_id) == (JobStatus.RUNNING, "w-other")
    part = storage.incoming_dir(filmed_game.id) / ".tracking.json.gz.w-other.part"
    assert part.read_bytes() == b"w-other's download"


# --- installing a Full re-analysis deletes the earlier run's analysis ----------------------------


def _game_updates(monkeypatch) -> list[dict[str, Any]]:
    """Every db.update_game call's changes, in order."""
    seen: list[dict[str, Any]] = []
    real = db.update_game

    def spy(game_id: str, **changes: Any) -> Game:
        seen.append(changes)
        return real(game_id, **changes)

    monkeypatch.setattr(db, "update_game", spy)
    return seen


def test_a_full_reanalysis_whose_analysis_fails_leaves_no_earlier_analysis(
    client, filmed_game, queue, fakes  # noqa: F811
):
    """The earlier run's analysis.json stayed (has_analysis true) next to the new tracking when the new
    analysis failed: the failed game's Roster page listed the earlier run's track ids, and a fix made
    there was applied to the new run's different tracks by the Retry's re-analysis."""
    game = _analysed(filmed_game)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    fakes.analyze_error = ScoutError(ErrorCode.CONFIG_INVALID, "SCOUT_COURT_CONFIG is not a valid court file.")
    make_worker(NewRun(), queue).run_once(timeout=1)

    failed = db.get_job(job.id)
    assert (failed.status, failed.stage, failed.error.code) == (JobStatus.FAILED, JobStage.ANALYZING, "CONFIG_INVALID")
    stored = db.get_game(game.id)
    assert (stored.status, stored.error.code, stored.has_analysis) == (GameStatus.FAILED, "CONFIG_INVALID", False)
    assert not storage.analysis_path(game.id).exists()
    assert db.list_track_overrides(game.id) == [] and _installed_tracking_job(game.id) == job.id
    assert client.get(f"/api/games/{game.id}/tracks").json() == {"assignments": [], "overrides": []}

    fakes.analyze_error = None  # IT fixed the setting
    r = client.post(f"/api/jobs/{job.id}/retry")
    assert r.status_code == 200, r.text
    assert r.json()["kind"] == JobKind.REANALYZE
    gpu = FakeProcessor()
    make_worker(gpu, queue).run_once(timeout=1)

    assert db.get_job(r.json()["id"]).status == JobStatus.SUCCEEDED
    assert gpu.submitted == [] and gpu.polled == []  # nothing went to the GPU again
    assert fakes.analyze[-1]["tracking"].job_id == job.id and fakes.analyze[-1]["overrides"] == []
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.error) == (GameStatus.READY, True, None)


def test_a_full_reanalysis_shows_no_analysis_until_its_own_is_saved(
    filmed_game, queue, fakes, monkeypatch  # noqa: F811
):
    """The end state is a guard; on the way, has_analysis goes false with the overlay flag (one update,
    at the install) and the new tracking never has the earlier analysis next to it."""
    game = _analysed(filmed_game)
    earlier_analysis = storage.analysis_path(game.id).read_bytes()
    updates = _game_updates(monkeypatch)
    earlier_analysis_on_disk: list[bool] = []
    analyze = pipeline.analyze_game

    def analyse(tracking, game_, *args: Any, **kwargs: Any) -> Any:
        earlier_analysis_on_disk.append(storage.analysis_path(game_.id).exists())
        return analyze(tracking, game_, *args, **kwargs)

    monkeypatch.setattr(pipeline, "analyze_game", analyse)
    job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
    make_worker(NewRun(annotated=True), queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert {"has_annotated_video": True, "has_tracking": True, "has_analysis": False} in updates
    assert earlier_analysis_on_disk == [False]
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.READY, True, True)
    assert storage.analysis_path(game.id).read_bytes() != earlier_analysis
    assert fakes.analyze[0]["tracking"].job_id == job.id and fakes.analyze[0]["overrides"] == []


def test_a_first_analysis_installs_as_before(filmed_game, queue, fakes, monkeypatch):  # noqa: F811
    """(Guard.) Nothing to replace: the install only sets the overlay and tracking flags (has_tracking since
    round 6)."""
    updates = _game_updates(monkeypatch)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    make_worker(NewRun(annotated=True), queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert {"has_annotated_video": True, "has_tracking": True} in updates
    assert all(changes.get("has_analysis") is not False for changes in updates)
    stored = db.get_game(filmed_game.id)
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.READY, True, True)


@pytest.mark.parametrize("stage", [JobStage.ANALYZING, JobStage.REPORTING])
def test_a_job_resumed_after_its_install_keeps_the_new_runs_analysis(filmed_game, queue, fakes, stage):  # noqa: F811
    """(Guard.) Its worker died after installing this run and saving its analysis (killed while Claude
    wrote the report, say): the analysis on disk is this run's. Installing the same run again must not
    delete it, also when the analysis then fails."""
    game = _analysed(filmed_game)  # the tracking and analysis.json on disk are this run's by now
    db.clear_track_overrides(game.id)
    saved = storage.analysis_path(game.id).read_bytes()
    job = _resumed(game.id, queue, stage)
    fakes.analyze_error = ScoutError(ErrorCode.ANALYSIS_FAILED)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.FAILED
    assert storage.analysis_path(game.id).read_bytes() == saved
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis) == (GameStatus.FAILED, True)


def test_a_job_cancelled_on_its_next_claim_leaves_the_flags_as_the_files_say(filmed_game, queue, fakes):  # noqa: F811
    """Its worker died after saving the new analysis but before it marked the game ready (has_analysis
    still false from the install), and the coach then cancelled: the game came back 'ready' with
    has_analysis false, so its pages hid the analysis that was there. (Since the verification of this
    round such a job finishes its analysis despite the cancel; the cancel still ends it when its
    workers keep dying, as here.)"""
    game = _analysed(filmed_game)  # this run's tracking and analysis, saved by the worker that died
    db.update_game(game.id, status=GameStatus.PROCESSING, has_analysis=False)
    job = _resumed(game.id, queue, JobStage.ANALYZING)
    db.update_job(job.id, attempts=job.max_attempts)  # the next claim is one too many
    db.request_cancel(job.id)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.CANCELLED
    stored = db.get_game(game.id)
    assert (stored.status, stored.has_analysis, stored.has_annotated_video) == (GameStatus.READY, True, True)


# --- a worker killed anywhere in the install -------------------------------------------------------


class _KillSwitch:
    """Kills a worker (raises _Killed) in place of the ``at``-th file or database write of its
    _install_outputs, wherever in the install that falls."""

    WRITES = (
        (shutil, "move"),
        (shutil, "rmtree"),
        (Path, "unlink"),
        (db, "clear_track_overrides"),
        (db, "update_game"),
    )

    def __init__(self, monkeypatch) -> None:
        self.at = 0
        self.done: list[str] = []
        self._installing = False
        for owner, name in self.WRITES:
            monkeypatch.setattr(owner, name, self._wrap(name, getattr(owner, name)))

    def _wrap(self, name: str, real):
        def write(*args: Any, **kwargs: Any) -> Any:
            if self._installing:
                if len(self.done) == self.at:
                    raise _Killed
                self.done.append(name)
            return real(*args, **kwargs)

        return write

    def arm(self, worker: Worker, at: int) -> None:
        self.at, self.done = at, []
        install = worker._install_outputs

        def install_until_killed(job, output) -> None:
            self._installing = True
            try:
                install(job, output)
            finally:
                self._installing = False

        worker._install_outputs = install_until_killed


def _filmed() -> Game:
    """A game with its film uploaded (the filmed_game fixture, once per kill point)."""
    game = db.create_game(GameCreate(scouted_team="Opponent HS", other_team="Rival HS", scouted_color="dark"))
    film = storage.source_video_path(game.id)
    film.parent.mkdir(parents=True, exist_ok=True)
    film.write_bytes(b"\x00\x00\x00\x18ftypmp42")
    return db.update_game(
        game.id, has_video=True, video_filename="vs-central.mp4", video_size=12, status=GameStatus.UPLOADED
    )


@pytest.mark.parametrize("then", ["resumed", "cancelled", "out of attempts"])
def test_a_worker_killed_anywhere_in_the_install_leaves_a_consistent_game(
    queue, fakes, monkeypatch, then  # noqa: F811
):
    """A power cut while a Full re-analysis installs, then the next worker resumes the job, or finds it
    cancelled or out of attempts (both end it without installing). Wherever the first worker stopped,
    the game must not end with the new tracking next to the earlier run's analysis, track fixes or
    overlay, nor the earlier tracking next to the new overlay, nor the earlier analysis without the
    fixes it was built with, and its flags must follow the files. The install moved the new tracking
    in before it cleared the earlier run's fixes, and the flags stayed as the killed worker left them."""
    kill = _KillSwitch(monkeypatch)
    ending = {"resumed": JobStatus.SUCCEEDED, "cancelled": JobStatus.CANCELLED, "out of attempts": JobStatus.FAILED}
    for at in range(20):
        game = _analysed(_filmed())
        earlier_analysis = storage.analysis_path(game.id).read_bytes()
        job = submit_job(game.id, JobKind.ANALYZE, queue=queue)
        first = make_worker(NewRun(annotated=True), queue)
        kill.arm(first, at)
        try:
            first.run_once(timeout=1)
        except _Killed:
            pass
        else:  # the install got through: every point in it has been tried
            assert db.get_job(job.id).status == JobStatus.SUCCEEDED
            return
        where = f"killed in place of write {at} of the install, after {kill.done}, then {then}"
        if then == "cancelled":
            db.request_cancel(job.id)
        elif then == "out of attempts":
            db.update_job(job.id, attempts=job.max_attempts)
        db.update_job(job.id, lease_expires_at=time.time() - 1)
        make_worker(NewRun(annotated=True), queue).run_once(timeout=1)

        assert db.get_job(job.id).status == ending[then], where
        state = _state(game.id)
        analysis, overlay = state["files"]["analysis.json"], state["files"]["annotated.mp4"]
        if _installed_tracking_job(game.id) == job.id:  # the new run's tracking
            next_to_it = (analysis == earlier_analysis, state["overrides"], overlay == FIRST_OVERLAY)
            assert next_to_it == (False, [], False), where
        else:
            assert overlay != NEW_OVERLAY, where
        if analysis == earlier_analysis:
            assert state["overrides"] == [OLD_FIX], where
        assert state["flags"] == (analysis is not None, overlay is not None), where
        assert not storage.incoming_dir(game.id).exists(), where
        if then == "resumed":
            assert (_installed_tracking_job(game.id), overlay) == (job.id, NEW_OVERLAY), where
            assert analysis is not None and db.get_game(game.id).status == GameStatus.READY, where
        elif then == "cancelled":
            resting = GameStatus.READY if analysis is not None else GameStatus.UPLOADED
            assert db.get_game(game.id).status == resting, where
    pytest.fail("the install never got through")
