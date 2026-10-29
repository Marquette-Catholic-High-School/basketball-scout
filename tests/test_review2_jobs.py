"""Second review round, jobs area: the game status is settled before a job ends, cancelling a
queued job that already has a GPU call, retrying after the GPU results were saved, film upload
retries, and GPU results read back from the Modal volume after Modal's own copy expired."""

from __future__ import annotations

import gzip
import time
from concurrent.futures import CancelledError
from datetime import timedelta
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from scout import config, db, storage
from scout.errors import ErrorCode, ScoutError
from scout.jobs.queue import submit_job
from scout.processing.base import PollResult
from scout.schemas import GameStatus, Job, JobKind, JobStage, JobStatus
from tests import helpers
from tests.test_api_jobs import client, post_job  # noqa: F401 - fixtures
from tests.test_api_support import make_app
from tests.test_processing_modal import EXC, HANDLE, fake_modal, film, processor  # noqa: F401 - fixtures
from tests.test_worker import (  # noqa: F401 - fixtures
    DONE,
    RUNNING,
    FakeProcessor,
    fakes,
    filmed_game,
    make_worker,
    queue,
)

FINAL = (JobStatus.SUCCEEDED, JobStatus.FAILED, JobStatus.CANCELLED)

# --- worker: the game is settled before the job ends ---------------------------------------


@pytest.fixture
def game_when_job_ended(monkeypatch) -> dict[JobStatus, GameStatus]:
    """{final job status: the game's status at the moment the worker writes it}."""
    seen: dict[JobStatus, GameStatus] = {}
    real = db.update_job

    def spy(job_id: str, **fields) -> Job:
        if fields.get("status") in FINAL:
            seen[fields["status"]] = db.get_game(db.get_job(job_id).game_id).status
        return real(job_id, **fields)

    monkeypatch.setattr(db, "update_job", spy)
    return seen


@pytest.mark.parametrize(
    ("outcome", "game_status"),
    [
        (JobStatus.SUCCEEDED, GameStatus.READY),
        (JobStatus.FAILED, GameStatus.FAILED),
        (JobStatus.CANCELLED, GameStatus.UPLOADED),
    ],
)
def test_the_game_status_is_final_when_the_job_ends(
    filmed_game, queue, fakes, game_when_job_ended, outcome, game_status  # noqa: F811
):
    """The game page reloads the game when its job poll sees the job finish; a game that is still
    'processing' at that moment stays on screen without an active job until a manual reload."""
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    oom = PollResult(state="failed", error=ScoutError(ErrorCode.GPU_OOM))
    polls = {JobStatus.SUCCEEDED: [RUNNING, DONE], JobStatus.FAILED: [RUNNING, oom], JobStatus.CANCELLED: [RUNNING]}
    cancel = (lambda n: db.request_cancel(job.id)) if outcome == JobStatus.CANCELLED else None
    make_worker(FakeProcessor(polls[outcome], on_poll=cancel), queue).run_once(timeout=1)

    assert db.get_job(job.id).status == outcome
    assert game_when_job_ended == {outcome: game_status}


# --- cancelling a queued job that already has a GPU call ------------------------------------


def _orphaned_queued_job(game_id: str) -> Job:
    """A queued row with a GPU call, as the old Redis reaper (db.requeue_expired_jobs) left them."""
    job = submit_job(game_id, JobKind.ANALYZE)
    db.update_job(job.id, external_id="fake:orphan", processor="fake", stage=JobStage.GPU_PROCESSING)
    db.update_game(game_id, status=GameStatus.PROCESSING, latest_job_id=job.id)
    return job


def test_nothing_turns_a_running_job_back_into_a_queued_row():
    """db.requeue_expired_jobs did, for a Redis reaper that no longer calls it: the job's GPU call
    kept running, and a cancel then finished the queued row without stopping it."""
    assert not hasattr(db, "requeue_expired_jobs")


def test_cancelling_a_queued_job_with_a_gpu_call_leaves_it_to_a_worker(filmed_game, queue, fakes):  # noqa: F811
    """Finished at once, nobody cancelled the GPU call or deleted the film from Modal's volume, and
    the game stayed 'processing'. Flagged like a running job, the worker that claims it does all that."""
    job = _orphaned_queued_job(filmed_game.id)
    flagged = db.request_cancel(job.id)
    assert (flagged.status, flagged.cancel_requested, flagged.message) == (JobStatus.QUEUED, True, "Cancelling...")
    assert db.get_game(filmed_game.id).status == GameStatus.PROCESSING

    gpu = FakeProcessor([RUNNING])
    assert make_worker(gpu, queue).run_once(timeout=1)
    done = db.get_job(job.id)
    assert (done.status, done.stage, done.error) == (JobStatus.CANCELLED, JobStage.DONE, None)
    assert gpu.cancelled == gpu.cleaned == ["fake:orphan"] and gpu.polled == []
    assert db.get_game(filmed_game.id).status == GameStatus.UPLOADED


def test_the_cancel_route_leaves_such_a_job_and_its_game_to_the_worker(client, filmed_game, queue, fakes):  # noqa: F811
    job = _orphaned_queued_job(filmed_game.id)
    r = client.post(f"/api/jobs/{job.id}/cancel")
    assert r.status_code == 200
    assert (r.json()["status"], r.json()["cancel_requested"]) == (JobStatus.QUEUED, True)
    assert db.get_game(filmed_game.id).status == GameStatus.PROCESSING  # not released before the GPU call stops
    assert post_job(client, filmed_game.id, "analyze").status_code == 409  # still the active analysis

    gpu = FakeProcessor()
    make_worker(gpu, queue).run_once(timeout=1)
    assert db.get_job(job.id).status == JobStatus.CANCELLED and gpu.cancelled == ["fake:orphan"]
    assert db.get_game(filmed_game.id).status == GameStatus.UPLOADED


def test_a_cancelled_job_whose_workers_kept_dying_ends_as_cancelled(filmed_game, queue, fakes):  # noqa: F811
    """The coach cancels a job whose worker died on attempt 3 of 3. The next claim is attempt 4, and
    the job used to fail with WORKER_LOST ('check journalctl, then Retry') and a failed game instead."""
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    assert db.claim_job("w-dead", 60, job_id=job.id) is not None
    db.update_job(job.id, attempts=3, external_id="fake:orphan", processor="fake", lease_expires_at=time.time() - 1)
    db.request_cancel(job.id)

    gpu = FakeProcessor()
    make_worker(gpu, queue).run_once(timeout=1)
    done = db.get_job(job.id)
    assert (done.status, done.error) == (JobStatus.CANCELLED, None)
    assert gpu.cancelled == ["fake:orphan"] and gpu.polled == []
    assert db.get_game(filmed_game.id).status == GameStatus.UPLOADED


# --- retry after the GPU results were saved ---------------------------------------------------


def _failed_analysis(game_id: str, stage: JobStage, **params) -> Job:
    job = db.create_job(game_id, JobKind.ANALYZE, params)
    error = ScoutError(ErrorCode.ANALYSIS_FAILED)
    return db.update_job(job.id, status=JobStatus.FAILED, stage=stage, error=error, finished_at=db.utcnow())


def _save_tracking(game_id: str) -> None:
    storage.write_json(storage.tracking_path(game_id), helpers.tracking([]).model_dump_json())


@pytest.mark.parametrize("stage", [JobStage.ANALYZING, JobStage.REPORTING])
def test_retry_after_the_gpu_results_were_saved_only_redoes_the_analysis(client, filmed_game, stage):  # noqa: F811
    """Re-running ANALYZE would upload a multi-GB film again and pay for another 1-3 h GPU run, only
    to get the tracking that is already on disk."""
    _save_tracking(filmed_game.id)
    old = _failed_analysis(filmed_game.id, stage, coach_focus="Who brings the ball up?", render_video=False)
    r = client.post(f"/api/jobs/{old.id}/retry")
    assert r.status_code == 200
    retried = r.json()
    assert retried["kind"] == JobKind.REANALYZE
    assert retried["params"] == {"report": False, "coach_focus": "Who brings the ball up?"}  # SCOUT_AUTO_REPORT=false
    game = db.get_game(filmed_game.id)
    assert (game.status, game.latest_job_id) == (GameStatus.QUEUED, retried["id"])


@pytest.mark.parametrize(
    ("stage", "tracking"),
    [
        (JobStage.UPLOADING, False),
        (JobStage.GPU_PROCESSING, True),
        (JobStage.DOWNLOADING, True),
        (JobStage.ANALYZING, False),
    ],
)
def test_retry_before_the_gpu_results_were_saved_runs_the_film_again(
    client, filmed_game, stage, tracking  # noqa: F811
):
    if tracking:  # an earlier run's tracking: not this run's result
        _save_tracking(filmed_game.id)
    old = _failed_analysis(filmed_game.id, stage, render_video=False)
    retried = client.post(f"/api/jobs/{old.id}/retry").json()
    assert (retried["kind"], retried["params"]) == (JobKind.ANALYZE, {"render_video": False})


def test_the_reanalysis_retry_writes_the_report_the_analysis_would_have(
    auth_headers, filmed_game, queue, fakes, monkeypatch  # noqa: F811
):
    _save_tracking(filmed_game.id)
    old = _failed_analysis(filmed_game.id, JobStage.ANALYZING, coach_focus="Do they press after made baskets?")
    app = make_app(monkeypatch, ANTHROPIC_API_KEY="sk-ant-test-only", SCOUT_AUTO_REPORT="true")
    with TestClient(app, headers=auth_headers) as c:
        retried = c.post(f"/api/jobs/{old.id}/retry").json()
    assert retried["kind"] == JobKind.REANALYZE and retried["params"]["report"] is True

    gpu = FakeProcessor()
    make_worker(gpu, queue, config.get_settings()).run_once(timeout=1)
    assert db.get_job(retried["id"]).status == JobStatus.SUCCEEDED
    assert gpu.submitted == [] and gpu.polled == []  # the film did not go to the GPU again
    assert [r["coach_focus"] for r in fakes.reports] == ["Do they press after made baskets?"]
    assert len(db.list_reports(filmed_game.id)) == 1
    assert db.get_game(filmed_game.id).status == GameStatus.READY


# --- film upload retries ------------------------------------------------------------------------


def flaky_uploads(volume, *errors: BaseException) -> None:
    """The fake volume's batch_upload fails with ``errors`` in turn (committing nothing), then works."""
    pending = list(errors)
    real = volume.batch_upload

    def batch_upload(force: bool = False):
        volume.upload_error = pending.pop(0) if pending else None
        return real(force)

    volume.batch_upload = batch_upload


def test_a_short_network_drop_does_not_fail_the_film_upload(fake_modal, processor, film):  # noqa: F811
    """Modal retries each part for well under a second; a few seconds without network during a
    30-60 minute upload failed the job, and the coach's Retry started the upload from zero."""
    flaky_uploads(fake_modal.volume, EXC.ConnectionError("connection reset by peer"), OSError("network is unreachable"))
    processor.upload_retry_delays_s = (10.0, 30.0)
    sleeps: list[float] = []
    processor.sleep = sleeps.append

    assert processor.submit(job_id="j_1", video=film, options={}) == HANDLE
    assert fake_modal.volume.force_flags == [True, True, True]
    assert fake_modal.volume.files == {"uploads/j_1/source.mp4": b"film bytes"}
    assert len(fake_modal.spawned) == 1
    assert sum(sleeps) == 40.0 and max(sleeps) <= 1.0  # 10 s, then 30 s, watching for a cancel every second


def test_the_upload_gives_up_after_three_attempts(fake_modal, processor, film):  # noqa: F811
    fake_modal.volume.upload_error = EXC.VolumeUploadTimeoutError("upload timed out")
    with pytest.raises(ScoutError) as exc:
        processor.submit(job_id="j_1", video=film, options={})
    assert exc.value.code == ErrorCode.MODAL_UPLOAD_FAILED and "timed out" in exc.value.message
    assert len(fake_modal.volume.force_flags) == 3
    assert fake_modal.volume.files == {} and fake_modal.spawned == []


@pytest.mark.parametrize(
    ("error", "code"),
    [
        (EXC.AuthError("token expired"), ErrorCode.MODAL_AUTH_FAILED),
        (EXC.PermissionDeniedError("no access to the environment"), ErrorCode.MODAL_AUTH_FAILED),
        (FileNotFoundError("source.mp4"), ErrorCode.MODAL_UPLOAD_FAILED),  # the game was deleted meanwhile
        (CancelledError(), ErrorCode.MODAL_UPLOAD_FAILED),
    ],
)
def test_upload_errors_a_retry_cannot_fix_fail_at_once(fake_modal, processor, film, error, code):  # noqa: F811
    processor.upload_retry_delays_s = (10.0, 30.0)
    sleeps: list[float] = []
    processor.sleep = sleeps.append
    fake_modal.volume.upload_error = error
    with pytest.raises(ScoutError) as exc:
        processor.submit(job_id="j_1", video=film, options={})
    assert exc.value.code == code
    assert len(fake_modal.volume.force_flags) == 1 and sleeps == []


def test_a_cancel_while_the_upload_waits_to_retry_ends_the_job(
    filmed_game, queue, fakes, fake_modal, processor  # noqa: F811
):
    """The coach cancels after an attempt failed: no second 30-60 minute upload, and the job ends as
    cancelled, not as a failed upload."""
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    flaky_uploads(fake_modal.volume, EXC.ConnectionError("connection reset by peer"))
    processor.upload_retry_delays_s = (10.0, 30.0)
    sleeps: list[float] = []

    def sleep(seconds: float) -> None:
        sleeps.append(seconds)
        db.request_cancel(job.id)

    processor.sleep = sleep
    assert make_worker(processor, queue).run_once(timeout=1)
    done = db.get_job(job.id)
    assert (done.status, done.error) == (JobStatus.CANCELLED, None)
    assert sleeps == [1.0]  # noticed at the next check, not after the 10 s wait
    assert len(fake_modal.volume.force_flags) == 1 and fake_modal.spawned == []
    assert db.get_game(filmed_game.id).status == GameStatus.UPLOADED


def test_a_worker_stop_while_the_upload_waits_to_retry_hands_the_job_back(
    filmed_game, queue, fakes, fake_modal, processor  # noqa: F811
):
    """systemctl restart during the wait: retrying would outlast systemd's 120 s and get killed; the
    job is handed back for the next worker instead of failing."""
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    flaky_uploads(fake_modal.volume, EXC.ConnectionError("connection reset by peer"))
    processor.upload_retry_delays_s = (10.0, 30.0)
    stopping = make_worker(processor, queue)
    processor.sleep = lambda seconds: stopping.stop()
    stopping.run_once(timeout=1)

    paused = db.get_job(job.id)
    assert (paused.status, paused.worker_id, paused.error, paused.attempts) == (JobStatus.RUNNING, None, None, 0)
    assert paused.lease_expires_at <= time.time() and paused.external_id is None
    assert len(fake_modal.volume.force_flags) == 1 and fake_modal.spawned == []
    assert db.get_game(filmed_game.id).status == GameStatus.PROCESSING


# --- results read back from the volume after the Modal result expired ----------------------------


@pytest.fixture
def listing(fake_modal):  # noqa: F811
    """Volume.listdir for the fake volume, like Modal's: the files in a folder; NotFoundError if none."""
    volume = fake_modal.volume

    def listdir(path: str, *, recursive: bool = False) -> list[SimpleNamespace]:
        folder = path.strip("/") + "/"
        names = sorted(name for name in volume.files if name.startswith(folder))
        if not names:
            raise EXC.NotFoundError(f"No such file or directory: {path}")
        return [SimpleNamespace(path=name) for name in names]

    volume.listdir = listdir
    return volume


def test_an_expired_gpu_result_is_read_back_from_the_volume(fake_modal, processor, listing, tmp_path):  # noqa: F811
    """Modal keeps a call's result for 7 days (a server switched off over a school break), but the
    files it pointed to are still on the volume, and the failed job's cleanup used to delete them."""
    listing.files.update({"results/j_1/tracking.json.gz": b"gzip json", "results/j_1/annotated.mp4": b"mp4"})
    fake_modal.outcome = EXC.OutputExpiredError("output expired")

    status = processor.poll(HANDLE)
    assert status.state == "succeeded"
    assert status.result["tracking_path"] == "results/j_1/tracking.json.gz"
    assert status.result["annotated_video_path"] == "results/j_1/annotated.mp4"
    output = processor.fetch(HANDLE, status.result, tmp_path)
    assert output.tracking_path.read_bytes() == b"gzip json" and output.annotated_video_path.read_bytes() == b"mp4"
    assert output.warnings == []


def test_an_expired_result_without_an_overlay_video(fake_modal, processor, listing, tmp_path):  # noqa: F811
    listing.files["results/j_1/tracking.json.gz"] = b"gzip json"
    fake_modal.outcome = EXC.OutputExpiredError("output expired")
    status = processor.poll(HANDLE)
    assert status.state == "succeeded" and status.result["annotated_video_path"] is None
    output = processor.fetch(HANDLE, status.result, tmp_path)
    assert output.annotated_video_path is None and output.warnings == []


@pytest.mark.parametrize(
    "files",
    [{}, {"results/j_1/annotated.mp4": b"mp4", "results/j_10/tracking.json.gz": b"another job's tracking"}],
)
def test_an_expired_result_without_its_tracking_file_still_fails(fake_modal, processor, listing, files):  # noqa: F811
    listing.files.update(files)
    fake_modal.outcome = EXC.OutputExpiredError("output expired")
    status = processor.poll(HANDLE)
    assert status.state == "failed" and status.error.code == ErrorCode.MODAL_RESULT_EXPIRED


@pytest.mark.parametrize(("failures", "state"), [(2, "succeeded"), (6, "failed")])
def test_listing_the_volume_rides_out_a_short_outage(fake_modal, processor, listing, failures, state):  # noqa: F811
    """Modal's SDK does not retry a listing; like a download, it gets a few minutes before giving up."""
    real, calls = listing.listdir, []

    def flaky(path: str, *, recursive: bool = False) -> list[SimpleNamespace]:
        calls.append(path)
        if len(calls) <= failures:
            raise EXC.ServiceError("unavailable")
        return real(path, recursive=recursive)

    listing.files["results/j_1/tracking.json.gz"] = b"gzip json"
    listing.listdir = flaky
    fake_modal.outcome = EXC.OutputExpiredError("output expired")
    status = processor.poll(HANDLE)
    assert status.state == state and len(calls) == min(failures + 1, 6)
    if state == "failed":  # the files cannot be confirmed: as before
        assert status.error.code == ErrorCode.MODAL_RESULT_EXPIRED


def test_a_job_resumed_after_its_result_expired_finishes_from_the_volume(
    filmed_game, queue, fakes, fake_modal, processor, listing  # noqa: F811
):
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    assert db.claim_job("w-before-the-break", 60, job_id=job.id) is not None
    db.update_job(
        job.id,
        external_id=f"fc-01ABC|{job.id}",
        processor="modal",
        stage=JobStage.GPU_PROCESSING,
        started_at=db.utcnow() - timedelta(days=8),
        lease_expires_at=time.time() - 1,
    )
    tracking = gzip.compress(helpers.tracking([]).model_dump_json().encode())
    listing.files.update(
        {
            f"uploads/{job.id}/source.mp4": b"film bytes",
            f"results/{job.id}/tracking.json.gz": tracking,
            f"results/{job.id}/annotated.mp4": b"mp4",
        }
    )
    fake_modal.outcome = EXC.OutputExpiredError("output expired")

    assert make_worker(processor, queue).run_once(timeout=1)
    done = db.get_job(job.id)
    assert (done.status, done.error) == (JobStatus.SUCCEEDED, None)
    game = db.get_game(filmed_game.id)
    assert (game.status, game.has_analysis, game.has_annotated_video) == (GameStatus.READY, True, True)
    assert storage.annotated_video_path(game.id).read_bytes() == b"mp4"
    assert listing.files == {}  # deleted from Modal once downloaded, as after any successful run
