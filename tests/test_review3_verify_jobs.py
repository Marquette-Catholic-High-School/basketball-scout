"""Third review round, jobs area (verification): the results of a Full re-analysis are downloaded
next to the installed run and moved into place in one step, so a download cut short leaves the earlier
run (tracking, overlay and the coach's track fixes) together, and a worker whose job was taken over
during the download leaves the install to the new owner. Also checked: the install clears the old
fixes on the Modal (fresh and expired result) and local GPU paths, and a job past the wait limit that
cannot reach Modal still stops for a graceful stop or a cancel."""

from __future__ import annotations

import errno
import time
from typing import Any

import pytest

from modal_app.pipeline import runner
from scout import db, storage
from scout.errors import ErrorCode, ScoutError
from scout.jobs.queue import submit_job
from scout.processing.local import LocalProcessor
from scout.schemas import Game, GameStatus, JobKind, JobStage, JobStatus, TeamSide, TrackOverride
from tests import helpers
from tests.test_processing_mock_local import FakeRunner
from tests.test_processing_modal import EXC, fake_modal, processor  # noqa: F401 - fixtures
from tests.test_review2_jobs import listing  # noqa: F401 - fixture
from tests.test_review3_jobs import OFFLINE, OLD_FIX, _analysed, _results_on_the_volume, _resumed, _scripted
from tests.test_worker import FakeProcessor, fakes, filmed_game, make_worker, queue, updates  # noqa: F401 - fixtures

FIRST_OVERLAY = b"first run's overlay"  # what _analysed() installs
NEW_FIX = TrackOverride(track_id=3, side=TeamSide.OTHER)  # a fix for one of the NEW run's tracks


class _Killed(BaseException):
    """The worker process dies mid-download (systemd's SIGKILL 120 s into a restart): nothing handles it."""


def _tracking_of(job_id: str) -> str:
    """A run's tracking, marked with the job that produced it (as the GPU pipeline does)."""
    return helpers.tracking([]).model_copy(update={"job_id": job_id}).model_dump_json()


def _installed_tracking_job(game_id: str) -> str | None:
    return storage.read_json(storage.tracking_path(game_id)).get("job_id")


def _game_files(game_id: str) -> list[str]:
    return sorted(path.name for path in storage.game_dir(game_id).iterdir())


# --- a download cut short leaves the earlier run in place -------------------------------------


@pytest.mark.parametrize("ending", ["killed, then cancelled", "killed too often", "disk full"])
def test_a_download_cut_short_leaves_the_earlier_run_in_place(filmed_game, queue, fakes, ending):  # noqa: F811
    """fetch() wrote the new tracking straight over the installed one, then the download of the
    overlay (minutes for a 1 GB file) was cut short. When the job then ended without installing
    (cancelled before the lease ran out, attempts used up, or failed), the game kept the new run's
    tracking with the first run's overlay and track fixes, and the next Re-run analysis applied the
    first run's "track 7 is not a player" to whoever is track 7 in the new run."""
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    gpu = FakeProcessor()
    error: BaseException = OSError(errno.ENOSPC, "No space left on device") if ending == "disk full" else _Killed()

    def cut_short(handle: str, result: dict[str, Any], dest_dir) -> Any:
        storage.write_json(dest_dir / "tracking.json.gz", _tracking_of(job.id))  # the tracking comes first
        raise error

    gpu.fetch = cut_short
    if ending == "disk full":
        make_worker(gpu, queue).run_once(timeout=1)
        assert db.get_job(job.id).status == JobStatus.FAILED
    else:
        with pytest.raises(_Killed):
            make_worker(gpu, queue).run_once(timeout=1)
        if ending == "killed, then cancelled":
            db.request_cancel(job.id)  # the coach cancels before the next worker picks the job up
        else:
            db.update_job(job.id, attempts=job.max_attempts)  # the next claim is one too many
        db.update_job(job.id, lease_expires_at=time.time() - 1)
        make_worker(FakeProcessor(), queue).run_once(timeout=1)
        expected = JobStatus.CANCELLED if ending == "killed, then cancelled" else JobStatus.FAILED
        assert db.get_job(job.id).status == expected

    assert _installed_tracking_job(filmed_game.id) is None  # still the first run's
    assert db.list_track_overrides(filmed_game.id) == [OLD_FIX]  # with its fixes
    assert storage.annotated_video_path(filmed_game.id).read_bytes() == FIRST_OVERLAY  # and its overlay
    assert db.get_game(filmed_game.id).has_annotated_video is True

    rerun = submit_job(filmed_game.id, JobKind.REANALYZE, queue=queue)
    make_worker(FakeProcessor(), queue).run_once(timeout=1)
    assert db.get_job(rerun.id).status == JobStatus.SUCCEEDED
    assert (fakes.analyze[-1]["tracking"].job_id, fakes.analyze[-1]["overrides"]) == (None, [OLD_FIX])


def test_a_resumed_download_installs_the_new_run_and_tidies_up(filmed_game, queue, fakes):  # noqa: F811
    """The next worker downloads the results again and installs them. What the killed download left
    behind (a half-written overlay, hidden in the game folder) is removed then; it used to stay for good."""
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    gpu = FakeProcessor()

    def killed(handle: str, result: dict[str, Any], dest_dir) -> Any:
        storage.write_json(dest_dir / "tracking.json.gz", _tracking_of(job.id))
        (dest_dir / ".annotated.mp4.k3x9.part").write_bytes(b"half an overlay")
        raise _Killed

    gpu.fetch = killed
    with pytest.raises(_Killed):
        make_worker(gpu, queue).run_once(timeout=1)
    db.update_job(job.id, lease_expires_at=time.time() - 1)
    make_worker(FakeProcessor(annotated=True), queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert db.list_track_overrides(filmed_game.id) == [] and fakes.analyze[-1]["overrides"] == []
    assert storage.annotated_video_path(filmed_game.id).read_bytes() == b"annotated"  # the new run's
    assert _game_files(filmed_game.id) == ["analysis.json", "annotated.mp4", "source.mp4", "tracking.json.gz"]


# --- a worker whose job was taken over during the download --------------------------------------


def _taken_over(game: Game, job_id: str) -> None:
    """While our machine slept through the download, w-other took the job over, installed this same
    run, finished the job, and the coach fixed one of the new run's tracks."""
    db.update_job(job_id, worker_id="w-other", status=JobStatus.SUCCEEDED, stage=JobStage.DONE, progress=100.0)
    storage.write_json(storage.tracking_path(game.id), _tracking_of(job_id))
    db.clear_track_overrides(game.id)
    db.set_track_override(game.id, NEW_FIX)
    db.update_game(game.id, status=GameStatus.READY, has_analysis=True)


def test_a_worker_whose_job_was_taken_over_leaves_the_install_alone(filmed_game, queue, fakes):  # noqa: F811
    """It used to write its download over the new owner's install and then clear the coach's fixes
    for the new run, before it noticed (at the analysis) that the job was no longer its own."""
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    gpu = FakeProcessor(annotated=True)
    fetch = gpu.fetch

    def slept_through(handle: str, result: dict[str, Any], dest_dir) -> Any:
        _taken_over(filmed_game, job.id)
        return fetch(handle, result, dest_dir)  # our download completes after all

    gpu.fetch = slept_through
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.worker_id) == (JobStatus.SUCCEEDED, "w-other")
    assert db.list_track_overrides(filmed_game.id) == [NEW_FIX]
    assert _installed_tracking_job(filmed_game.id) == job.id  # the owner's install, untouched
    assert fakes.analyze == [] and gpu.cancelled == [] and gpu.cleaned == []


def test_a_worker_whose_job_was_taken_over_does_not_fail_it_when_its_download_breaks(
    filmed_game, queue, fakes  # noqa: F811
):
    """Its download broke after the machine woke up: it marked the other worker's finished job (and
    the game) failed, and deleted the results from the GPU service."""
    _analysed(filmed_game)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    gpu = FakeProcessor()

    def slept_through(handle: str, result: dict[str, Any], dest_dir) -> Any:
        _taken_over(filmed_game, job.id)
        raise ScoutError(ErrorCode.MODAL_REMOTE_ERROR, "Downloading the GPU results from Modal failed.")

    gpu.fetch = slept_through
    make_worker(gpu, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error, done.worker_id) == (JobStatus.SUCCEEDED, None, "w-other")
    game = db.get_game(filmed_game.id)
    assert (game.status, game.error) == (GameStatus.READY, None)
    assert gpu.cancelled == [] and gpu.cleaned == []


# --- the old fixes go on every GPU path that installs a new run ----------------------------------


@pytest.mark.parametrize("returned", ["result", "expired result"])
def test_a_full_reanalysis_on_modal_clears_the_earlier_runs_fixes(
    filmed_game, queue, fakes, fake_modal, processor, listing, returned  # noqa: F811
):
    _analysed(filmed_game)
    if returned == "result":
        job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    else:  # resumed after a week off: Modal's copy of the result is gone, its files are on the volume
        job = _resumed(filmed_game.id, queue, JobStage.GPU_PROCESSING, processor="modal", hours=8 * 24)
    response = _results_on_the_volume(fake_modal, job.id)
    fake_modal.volume.files[f"results/{job.id}/annotated.mp4"] = b"second run's overlay"
    response["annotated_video_path"] = f"results/{job.id}/annotated.mp4"
    fake_modal.outcome = response if returned == "result" else EXC.OutputExpiredError("output expired")
    processor.poll_interval = 0.0
    make_worker(processor, queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert fakes.analyze[0]["overrides"] == [] and db.list_track_overrides(filmed_game.id) == []
    assert storage.annotated_video_path(filmed_game.id).read_bytes() == b"second run's overlay"
    assert db.get_game(filmed_game.id).has_annotated_video is True


def test_a_full_reanalysis_on_the_local_gpu_clears_them_too(filmed_game, queue, fakes, settings, monkeypatch):  # noqa: F811
    _analysed(filmed_game)
    pipeline = FakeRunner()
    pipeline.release.set()
    monkeypatch.setattr(runner, "run_pipeline", pipeline)
    gpu = LocalProcessor(settings)
    gpu.poll_interval = 0.0
    monkeypatch.setattr(gpu, "check_ready", lambda: None)  # no PyTorch here
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    make_worker(gpu, queue).run_once(timeout=1)

    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert fakes.analyze[0]["overrides"] == [] and db.list_track_overrides(filmed_game.id) == []
    assert storage.annotated_video_path(filmed_game.id).read_bytes() == b"annotated video"


# --- past the wait limit without Modal: a stop or a cancel still ends the wait --------------------


def test_a_graceful_stop_during_an_outage_past_the_limit_hands_the_job_back(
    filmed_game, queue, fakes, fake_modal, processor  # noqa: F811
):
    job = _resumed(filmed_game.id, queue, JobStage.GPU_PROCESSING, processor="modal", hours=9)
    _results_on_the_volume(fake_modal, job.id)
    worker = make_worker(processor, queue)
    polled = _scripted(fake_modal, processor, [OFFLINE], before=lambda n: n == 2 and worker.stop())
    worker.run_once(timeout=1)

    paused = db.get_job(job.id)
    assert (paused.status, paused.error, paused.worker_id) == (JobStatus.RUNNING, None, None)
    assert "Paused" in paused.message and len(polled) == 2
    assert fake_modal.cancelled == [] and f"results/{job.id}/tracking.json.gz" in fake_modal.volume.files


def test_a_cancel_during_an_outage_past_the_limit_cancels_the_job(
    filmed_game, queue, fakes, fake_modal, processor, updates  # noqa: F811
):
    job = _resumed(filmed_game.id, queue, JobStage.GPU_PROCESSING, processor="modal", hours=9)
    polled = _scripted(fake_modal, processor, [OFFLINE], before=lambda n: n == 3 and db.request_cancel(job.id))
    make_worker(processor, queue).run_once(timeout=1)

    done = db.get_job(job.id)
    assert (done.status, done.error) == (JobStatus.CANCELLED, None)
    assert len(polled) == 3
    assert "Lost contact with the GPU service; retrying..." in [u.get("message") for u in updates]
    assert db.get_game(filmed_game.id).status == GameStatus.UPLOADED
