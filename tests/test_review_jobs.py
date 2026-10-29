"""Review regression tests for the jobs area: worker leases, Redis claim timing, Modal
poll error mapping, local URL films, deleted games and result downloads."""

from __future__ import annotations

import threading
import time
from pathlib import Path

import pytest

from modal_app.pipeline import video
from modal_app.pipeline.errors import PipelineError
from scout import db, storage
from scout import worker as worker_module
from scout.analysis import pipeline
from scout.errors import ErrorCode, ScoutError
from scout.jobs import redis_queue
from scout.jobs.queue import SQLiteJobQueue, submit_job
from scout.jobs.redis_queue import RedisJobQueue
from scout.processing import modal_client
from scout.processing.base import VideoSource
from scout.processing.local import LocalProcessor
from scout.schemas import GameStatus, JobKind, JobStage, JobStatus
from tests.test_processing_mock_local import _wait_until_finished
from tests.test_redis_queue import FakeRedis
from tests.test_processing_modal import EXC, HANDLE, RESULT, fake_modal, processor  # noqa: F401 - fixtures
from tests.test_worker import (  # noqa: F401 - fixtures
    DONE,
    RUNNING,
    FakeProcessor,
    env,
    fakes,
    filmed_game,
    make_analysis,
    make_worker,
    queue,
)

# --- worker: leases ------------------------------------------------------------------------


def test_lapsed_lease_is_not_run_twice_by_the_same_worker(filmed_game, fakes, monkeypatch):  # noqa: F811
    """The machine slept past the lease (laptop lid, paused VM): the worker's own claim loop
    picks the job up again while its first thread is still polling the GPU."""
    settings = env(monkeypatch, SCOUT_WORKER_CONCURRENCY="2")
    jobs = SQLiteJobQueue(poll_interval=0.02)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=jobs)

    def on_poll(n: int) -> None:
        if n == 1:
            db.update_job(job.id, lease_expires_at=time.time() - 1)  # the wall clock jumped past the lease
            deadline = time.monotonic() + 5
            while db.get_job(job.id).lease_expires_at < time.time() and time.monotonic() < deadline:
                time.sleep(0.01)  # until the claim loop has taken the job again

    gpu = FakeProcessor([RUNNING, DONE], on_poll=on_poll)
    runner_ = make_worker(gpu, jobs, settings)
    runner_.claim_timeout = 0.05
    runner_._renew_leases = lambda: None  # asleep: nothing renewed the lease
    started: list[str] = []
    real_process_job = runner_.process_job

    def counting(claimed):
        started.append(claimed.id)
        return real_process_job(claimed)

    runner_.process_job = counting
    thread = threading.Thread(target=runner_.run_forever, daemon=True)
    thread.start()
    try:
        _wait_for(lambda: db.get_job(job.id).status == JobStatus.SUCCEEDED)
        time.sleep(0.2)  # a second copy, if one started, finishes too
    finally:
        runner_.stop()
        thread.join(timeout=10)
    assert started == [job.id]
    assert len(gpu.fetched) == 1 and len(fakes.analyze) == 1
    assert db.get_job(job.id).attempts == 1  # re-taking our own job is not a lost attempt


def test_stop_hands_back_a_job_the_claim_loop_just_took_again(filmed_game, fakes):  # noqa: F811
    """On stop the job thread hands its job back (lease expired now); a claim already in
    progress can take that very job again while the thread is finishing. It must still be
    handed back, not kept with a fresh five-minute lease."""
    jobs = SQLiteJobQueue(poll_interval=0.02)
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=jobs)
    gpu = FakeProcessor([RUNNING])
    gpu.poll_interval = 0.02
    runner_ = make_worker(gpu, jobs)
    runner_.claim_timeout = 0.05
    in_claim, stopping, released, reclaimed = (threading.Event() for _ in range(4))
    real_claim, real_release = jobs.claim, runner_._release

    def claim(worker_id, timeout=5.0):
        claimed = real_claim(worker_id, timeout)
        if claimed is None and not stopping.is_set():
            in_claim.set()
            if stopping.wait(2) and released.wait(2):  # the stop arrived while this claim was running
                claimed = real_claim(worker_id, timeout)
                if claimed is not None:
                    reclaimed.set()
        return claimed

    def release(handed_back):
        real_release(handed_back)
        if threading.current_thread().name.startswith("job"):  # the job thread: still running here
            released.set()
            reclaimed.wait(2)

    def on_poll(n: int) -> None:
        if n == 2 and in_claim.wait(2):
            stopping.set()
            runner_.stop()

    jobs.claim, runner_._release, gpu.on_poll = claim, release, on_poll
    loop = threading.Thread(target=runner_.run_forever, daemon=True)
    loop.start()
    loop.join(timeout=10)
    assert not loop.is_alive() and reclaimed.is_set()  # the claim loop did take the job again
    paused = db.get_job(job.id)
    assert paused.status == JobStatus.RUNNING and paused.worker_id is None
    assert paused.lease_expires_at <= time.time() and paused.attempts == 0


def test_a_job_taken_over_by_another_worker_is_left_to_it(filmed_game, queue, fakes):  # noqa: F811
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)

    def on_poll(n: int) -> None:
        if n == 1:  # our lease ran out while we were stalled, and another worker resumed the job
            db.update_job(job.id, lease_expires_at=time.time() - 1)
            assert db.claim_job("w-other", 300, job_id=job.id) is not None

    gpu = FakeProcessor([RUNNING, DONE], on_poll=on_poll)
    stalled = make_worker(gpu, queue)
    stalled._renew_leases = lambda: None  # stalled: nothing renewed the lease
    stalled.run_once(timeout=1)

    current = db.get_job(job.id)
    assert (current.status, current.worker_id, current.error) == (JobStatus.RUNNING, "w-other", None)
    assert gpu.fetched == [] and gpu.cancelled == [] and gpu.cleaned == []
    assert fakes.analyze == []
    assert db.get_game(filmed_game.id).status == GameStatus.PROCESSING


def test_a_stopping_worker_does_not_hand_back_a_job_it_lost(filmed_game, queue, fakes):  # noqa: F811
    """SIGTERM reaches a stalled worker after another worker took its job over: handing the job
    'back' would wipe the new owner's lease and let a third worker start it as well."""
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)
    gpu = FakeProcessor([RUNNING])
    gpu.poll_interval = 1.0
    stale = make_worker(gpu, queue)
    stale._renew_leases = lambda: None  # stalled: nothing renewed the lease

    def take_over_then_stop() -> None:  # runs while the stale worker sleeps between polls
        db.update_job(job.id, lease_expires_at=time.time() - 1)
        assert db.claim_job("w-other", 300, job_id=job.id) is not None
        stale.stop()

    gpu.on_poll = lambda n: n == 1 and threading.Timer(0.1, take_over_then_stop).start()
    stale.run_once(timeout=1)

    current = db.get_job(job.id)
    assert (current.status, current.worker_id) == (JobStatus.RUNNING, "w-other")
    assert current.lease_expires_at > time.time() + 200 and current.attempts == 2
    assert gpu.cancelled == [] and gpu.cleaned == []


def test_a_requeued_job_keeps_running_here(filmed_game, fakes):  # noqa: F811
    """Redis requeue_stale pushes the id of a job whose lease expired back onto the queue, but the
    row stays `running` with its worker: until someone else claims the job it is still ours, so we
    do not abandon it, and the stale id is dropped once the job is done."""
    rq = RedisJobQueue(client=FakeRedis())
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=rq)

    def on_poll(n: int) -> None:
        if n == 1:
            db.update_job(job.id, lease_expires_at=time.time() - 1)
            assert rq.requeue_stale() == 1
            assert db.get_job(job.id).status == JobStatus.RUNNING

    gpu = FakeProcessor([RUNNING, DONE], on_poll=on_poll)
    asleep = make_worker(gpu, rq)
    asleep._renew_leases = lambda: None  # asleep: nothing renewed the lease
    asleep.run_once(timeout=1)
    assert db.get_job(job.id).status == JobStatus.SUCCEEDED
    assert gpu.fetched == [f"fake:{job.id}"] and len(fakes.analyze) == 1
    assert rq.claim("w-other", timeout=0.1) is None


# --- worker: deleted games -----------------------------------------------------------------


def test_files_written_after_the_game_was_deleted_are_removed(filmed_game, queue, fakes, monkeypatch):  # noqa: F811
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=queue)

    def analyze_then_deleted(tracking, game, rosters, overrides=None, **_kw):
        # The coach deletes the game while the box score is being built: the API removes
        # the folder and the row; our analysis.json (with roster names) is written after that.
        storage.remove_game_files(game.id)
        db.delete_game(game.id)
        return make_analysis(game.id)

    monkeypatch.setattr(pipeline, "analyze_game", analyze_then_deleted)
    make_worker(FakeProcessor(annotated=True), queue).run_once(timeout=1)

    assert db.get_job(job.id) is None and db.get_game(filmed_game.id) is None
    assert not storage.game_dir(filmed_game.id).exists()


# --- Redis queue -----------------------------------------------------------------------------


class _Clock:
    """Stands in for the ``time`` module inside redis_queue: BLMOVE 'blocks' instantly."""

    def __init__(self) -> None:
        self.now = 1000.0

    def monotonic(self) -> float:
        return self.now

    def time(self) -> float:
        return time.time()


@pytest.mark.parametrize("claim_timeout", [worker_module.CLAIM_TIMEOUT_SECONDS, 60.0])
def test_redis_claim_blocks_less_than_the_socket_read_timeout(settings, monkeypatch, claim_timeout):
    """redis-py >= 6 reads with a 5 s socket timeout by default; an idle BLMOVE of the
    worker's 5 s claim then times out client-side and looks like 'Redis is down'."""
    rq = RedisJobQueue(settings)  # the real redis-py client the worker uses (nothing connects here)
    clock = _Clock()
    blocks: list[float] = []

    def blmove(source, destination, timeout, *where):
        blocks.append(timeout)
        clock.now += timeout
        return None

    monkeypatch.setattr(redis_queue, "time", clock)
    monkeypatch.setattr(rq.client, "hset", lambda *args: 1)
    monkeypatch.setattr(rq.client, "blmove", blmove)
    assert rq.claim("w1", timeout=claim_timeout) is None

    read_timeout = rq.client.connection_pool.make_connection().socket_timeout
    assert blocks and sum(blocks) >= claim_timeout
    assert read_timeout is None or max(blocks) <= read_timeout - 1.0


# --- Modal client ----------------------------------------------------------------------------


@pytest.mark.parametrize("name", ["InternalError", "ResourceExhaustedError"])
def test_modal_service_errors_while_polling_keep_waiting(fake_modal, processor, name):  # noqa: F811
    """gRPC INTERNAL / RESOURCE_EXHAUSTED come from Modal's API, not from our GPU job."""
    fake_modal.outcome = getattr(EXC, name)("Modal API trouble")
    status = processor.poll(HANDLE)
    assert status.state == "running" and "Lost contact" in status.message


def test_result_download_rides_out_a_short_network_outage(fake_modal, processor, tmp_path, monkeypatch):  # noqa: F811
    """The GPU result is hours of paid work: a minute without internet must not throw it away."""
    sleeps: list[float] = []
    monkeypatch.setattr(modal_client.time, "sleep", sleeps.append)
    processor.download_retry_delay_s = 5.0
    fake_modal.volume.files["results/j_1/tracking.json.gz"] = b"gzip json"
    fake_modal.volume.read_failures = 5
    output = processor.fetch(HANDLE, {"status": "ok", "tracking_path": RESULT["tracking_path"]}, tmp_path)
    assert output.tracking_path.read_bytes() == b"gzip json"
    assert sum(sleeps) >= 60.0 and sleeps == sorted(sleeps)


# --- local processor -------------------------------------------------------------------------


@pytest.fixture
def downloads(monkeypatch):
    """video.download_video stand-in: writes a small file where the film would land."""
    calls: list[tuple[str, Path]] = []

    def download(url, dest, *, max_bytes, progress=None, **_kw):
        calls.append((url, Path(dest)))
        Path(dest).parent.mkdir(parents=True, exist_ok=True)
        Path(dest).write_bytes(b"\x00\x00\x00\x18ftypmp42 downloaded film")
        return Path(dest)

    monkeypatch.setattr(video, "download_video", download)
    return calls


def test_local_url_film_reaches_the_pipeline_as_a_local_file(monkeypatch, tmp_path, downloads):
    """SCOUT_PROCESSOR=local with a video link: LocalProcessor -> the real run_pipeline. ffprobe
    needs a file; the link used to arrive as Path("https:/...") -> "The video file was not found"."""
    probed: list[tuple[str, bool]] = []

    def probe(path):
        probed.append((str(path), Path(path).is_file()))
        raise PipelineError("VIDEO_INVALID", "stop after the probe")  # the rest of the pipeline needs a GPU

    monkeypatch.setattr(video, "probe_video", probe)
    film = VideoSource(kind="url", filename="vs-central.mp4", url="https://films.example.org/vs-central.mp4")
    local = LocalProcessor()
    status = _wait_until_finished(local, local.submit(job_id="j_url", video=film, options={"work_dir": str(tmp_path)}))

    assert [url for url, _ in downloads] == ["https://films.example.org/vs-central.mp4"]
    assert probed == [(str(downloads[0][1]), True)]
    assert status.state == "failed" and status.error.message == "stop after the probe"
    assert not downloads[0][1].exists()  # the downloaded copy does not linger on disk


def test_local_url_download_failure_is_reported(monkeypatch, tmp_path):
    def broken(url, dest, **_kw):
        raise PipelineError("VIDEO_DOWNLOAD_FAILED", "The link opens a web page, not a video file.")

    monkeypatch.setattr(video, "download_video", broken)
    film = VideoSource(kind="url", filename="film.mp4", url="https://films.example.org/watch?v=1")
    local = LocalProcessor()
    status = _wait_until_finished(local, local.submit(job_id="j_page", video=film, options={"work_dir": str(tmp_path)}))
    assert status.state == "failed" and status.error.code == ErrorCode.VIDEO_DOWNLOAD_FAILED
    assert "web page" in status.error.message


def _wait_for(condition, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while not condition():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met in time")
        time.sleep(0.02)


# --- second review -----------------------------------------------------------------------------


def test_redis_requeued_job_cancelled_by_the_coach_still_stops_the_gpu(filmed_game, fakes):  # noqa: F811
    """Redis queue: a worker died while the GPU ran; requeue_stale (any worker's loop, every minute)
    put the job back in the queue. The coach cancels it before a worker is free. The GPU call must
    still be cancelled and the Modal volume cleared, and the game must not stay 'processing'."""
    rq = RedisJobQueue(client=FakeRedis())
    job = submit_job(filmed_game.id, JobKind.ANALYZE, queue=rq)
    assert rq.claim("w-dead", timeout=0.2).id == job.id
    db.update_job(job.id, external_id=f"fake:{job.id}", processor="fake", stage=JobStage.GPU_PROCESSING)
    db.update_game(filmed_game.id, status=GameStatus.PROCESSING)
    db.update_job(job.id, lease_expires_at=time.time() - 1)  # w-dead is gone; its lease ran out

    assert rq.requeue_stale() >= 1
    db.request_cancel(job.id)
    gpu = FakeProcessor([RUNNING])
    assert make_worker(gpu, rq).run_once(timeout=0.3)

    assert db.get_job(job.id).status == JobStatus.CANCELLED
    assert gpu.cancelled == [f"fake:{job.id}"] and gpu.cleaned == [f"fake:{job.id}"] and gpu.polled == []
    assert db.get_game(filmed_game.id).status == GameStatus.UPLOADED


@pytest.mark.parametrize("error", [EXC.ServiceError("unavailable"), EXC.AuthError("token revoked")])
def test_modal_spawn_failure_deletes_the_uploaded_film(fake_modal, processor, tmp_path, error):  # noqa: F811
    """No handle is saved when spawn fails, so the worker never runs cleanup() for that upload:
    the game film (of minors) would stay on Modal's volume for good."""
    film = tmp_path / "source.mp4"
    film.write_bytes(b"film bytes")
    fake_modal.volume.files["uploads/j_other/source.mp4"] = b"another job's film"
    fake_modal.spawn_error = error
    with pytest.raises(ScoutError):
        processor.submit(job_id="j_1", video=VideoSource(kind="file", filename="g.mp4", path=film), options={})
    assert fake_modal.volume.files == {"uploads/j_other/source.mp4": b"another job's film"}


def test_modal_outage_of_a_few_hours_does_not_throw_the_gpu_run_away(fake_modal, processor, monkeypatch):  # noqa: F811
    """The school's internet is down for two hours while the GPU works. The call keeps running on
    Modal and its result is kept for 7 days, so the job must still be waiting when the link comes
    back: failing it discards the paid run (Retry starts a new one), and with Modal unreachable
    cleanup() cannot delete the film from the volume either."""
    clock = [1000.0]
    monkeypatch.setattr(modal_client.time, "monotonic", lambda: clock[0])
    fake_modal.outcome = EXC.ConnectionError("Could not connect to the Modal server.")
    assert processor.poll(HANDLE).state == "running"
    clock[0] += 2 * 3600
    status = processor.poll(HANDLE)
    assert status.state == "running" and "Lost contact" in status.message
    fake_modal.outcome = {"status": "ok", "job_id": "j_1", "tracking_path": "results/j_1/tracking.json.gz"}
    assert processor.poll(HANDLE).state == "succeeded"


def test_modal_cleanup_removes_a_link_films_download(fake_modal, processor):  # noqa: F811
    """modal_app/app.py downloads a link film to tmp/<job_id>/ and deletes it itself, unless the
    container was killed (time limit, out of memory): cleanup() is then the only backstop."""
    fake_modal.volume.files.update({"tmp/j_1/film.mp4": b"film", "tmp/j_10/film.mp4": b"another job's film"})
    processor.cleanup(HANDLE, None)
    assert fake_modal.volume.files == {"tmp/j_10/film.mp4": b"another job's film"}

