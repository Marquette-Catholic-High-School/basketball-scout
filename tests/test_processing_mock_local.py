"""MockProcessor (synthetic demo game) and LocalProcessor (pipeline in a local thread)."""

from __future__ import annotations

import subprocess
import sys
import threading
import time
import types
from pathlib import Path

import pytest

from modal_app.pipeline import runner
from modal_app.pipeline.errors import PipelineError
from scout import config, storage
from scout.analysis import synthetic
from scout.errors import ErrorCode, ScoutError
from scout.processing import get_processor, mock
from scout.processing.base import PollResult, VideoSource
from scout.processing.local import LocalProcessor
from scout.processing.mock import MockProcessor, seed_for_job
from scout.schemas import TrackingResult
from tests import helpers


@pytest.fixture
def film(tmp_path) -> VideoSource:
    path = tmp_path / "source.mp4"
    path.write_bytes(b"\x00\x00\x00\x18ftypmp42 not really a video")
    return VideoSource(kind="file", filename="vs-central.mp4", path=path)


def _set_env(monkeypatch, **values: str):
    for name, value in values.items():
        monkeypatch.setenv(name, value)
    config.reset_settings()
    return config.get_settings()


# ---------------------------------------------------------------------------
# MockProcessor
# ---------------------------------------------------------------------------


@pytest.fixture
def fake_generator(monkeypatch):
    """synthetic.py belongs to another engineer: stand in a tiny game and record the call."""
    calls: list[dict] = []

    def generate(**kwargs):
        calls.append(kwargs)
        game = helpers.tracking([helpers.track(1, 0, [(0, 10.0, 10.0), (3, 11.0, 10.0)], jersey="3")])
        return game, synthetic.SyntheticTruth()

    monkeypatch.setattr(synthetic, "generate_synthetic_game", generate)
    return calls


def test_mock_full_cycle_writes_synthetic_tracking(monkeypatch, tmp_path, film, fake_generator):
    settings = _set_env(monkeypatch, SCOUT_MOCK_SECONDS="0")
    monkeypatch.setattr(mock, "probe_duration", lambda path: 321.0)
    processor = get_processor(settings)
    assert isinstance(processor, MockProcessor) and processor.poll_interval == 0.5

    handle = processor.submit(job_id="j_demo", video=film, options={"analysis_fps": 15})
    assert handle == "mock:j_demo"
    status = processor.poll(handle)
    assert status.state == "succeeded" and status.result["status"] == "ok"

    output = processor.fetch(handle, status.result, tmp_path / "game")
    assert output.tracking_path == tmp_path / "game" / "tracking.json.gz"
    assert output.annotated_video_path is None
    tracking = TrackingResult.model_validate(storage.read_json(output.tracking_path))
    assert tracking.job_id == "j_demo"
    assert tracking.pipeline.options[mock.SEED_OPTION] == seed_for_job("j_demo")
    assert fake_generator == [{"seed": seed_for_job("j_demo"), "duration_s": 321.0, "filename": "vs-central.mp4"}]


def test_mock_reports_progress_while_simulating(monkeypatch, film):
    _set_env(monkeypatch, SCOUT_MOCK_SECONDS="1000")
    processor = MockProcessor()
    handle = processor.submit(job_id="j_slow", video=film, options={})
    status = processor.poll(handle)
    assert status.state == "running"
    assert 0.0 <= status.progress < 1.0
    assert "Demo mode" in status.message


def test_mock_survives_a_worker_restart(monkeypatch, tmp_path, fake_generator):
    _set_env(monkeypatch, SCOUT_MOCK_SECONDS="1000")
    fresh = MockProcessor()  # a new process: knows nothing about the submit
    status = fresh.poll("mock:j_old")
    assert status.state == "succeeded"
    fresh.fetch("mock:j_old", status.result, tmp_path)
    assert fake_generator[0]["seed"] == seed_for_job("j_old")
    assert fake_generator[0]["duration_s"] == mock.DEFAULT_DURATION_S


def test_mock_rejects_foreign_handles():
    with pytest.raises(ScoutError) as exc:
        MockProcessor().poll("fc-123|j_1")
    assert exc.value.code == ErrorCode.INTERNAL_ERROR


def test_seed_for_job_is_stable_across_processes():
    seeds = {seed_for_job(f"j_{n}") for n in range(20)}
    assert seed_for_job("j_abc") == seed_for_job("j_abc")
    assert len(seeds) > 15 and all(0 <= s < 100_000 for s in seeds)


def test_probe_duration(monkeypatch, tmp_path):
    clip = tmp_path / "clip.mp4"
    clip.write_bytes(b"x")
    monkeypatch.setattr(mock.shutil, "which", lambda name: None)
    assert mock.probe_duration(clip) is None

    outputs = iter(["2950.25\n", "N/A\n"])
    monkeypatch.setattr(mock.shutil, "which", lambda name: "/usr/bin/ffprobe")
    monkeypatch.setattr(
        mock.subprocess, "run", lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0, stdout=next(outputs), stderr="")
    )
    assert mock.probe_duration(clip) == pytest.approx(2950.25)
    assert mock.probe_duration(clip) is None


# ---------------------------------------------------------------------------
# LocalProcessor
# ---------------------------------------------------------------------------


_WRITE_OUTPUTS = object()


class FakeRunner:
    """Stands in for modal_app.pipeline.runner.run_pipeline (another engineer's module)."""

    def __init__(self, outcome=_WRITE_OUTPUTS):
        self.outcome = outcome  # default: write outputs and return ok; an exception: raise it; else return it
        self.started = threading.Event()
        self.release = threading.Event()
        self.calls: list[dict] = []

    def __call__(self, video_path, options, *, output_dir, job_id, progress=None, filename=None):
        call = {"video_path": video_path, "options": options, "output_dir": output_dir, "job_id": job_id}
        self.calls.append({**call, "filename": filename})
        if progress:
            progress("detect", 40.0, "Detecting players (400/1000 frames)")
        self.started.set()
        self.release.wait(timeout=5)
        if isinstance(self.outcome, BaseException):
            raise self.outcome
        if self.outcome is not _WRITE_OUTPUTS:
            return self.outcome
        out = Path(output_dir)
        storage.write_json(out / "tracking.json.gz", helpers.tracking([]).model_dump_json())
        (out / "annotated.mp4").write_bytes(b"annotated video")
        return {
            "status": "ok",
            "job_id": job_id,
            "tracking_path": str(out / "tracking.json.gz"),
            "annotated_video_path": str(out / "annotated.mp4"),
        }


def _wait_until_finished(processor: LocalProcessor, handle: str, timeout: float = 5.0) -> PollResult:
    deadline = time.monotonic() + timeout
    while True:
        status = processor.poll(handle)
        if status.state != "running" or time.monotonic() > deadline:
            return status
        time.sleep(0.01)


def test_local_full_cycle(monkeypatch, tmp_path, film, settings):
    fake = FakeRunner()
    monkeypatch.setattr(runner, "run_pipeline", fake)
    processor = get_processor(settings, name="local")
    assert isinstance(processor, LocalProcessor) and processor.poll_interval == 2
    try:
        handle = processor.submit(job_id="j_loc", video=film, options={"analysis_fps": 15})
        assert handle == "local:j_loc"
        assert fake.started.wait(timeout=5)
        running = processor.poll(handle)
        assert (running.state, running.progress) == ("running", 40.0)
        assert running.message == "Detecting players (400/1000 frames)"
    finally:
        fake.release.set()
    status = _wait_until_finished(processor, handle)
    assert status.state == "succeeded"

    run_dir = settings.data_dir / "local_runs" / "j_loc"
    assert fake.calls == [
        {
            "video_path": str(film.path),
            "options": {"analysis_fps": 15},
            "output_dir": str(run_dir),
            "job_id": "j_loc",
            "filename": "vs-central.mp4",
        }
    ]
    dest = tmp_path / "game"
    output = processor.fetch(handle, status.result, dest)
    assert output.tracking_path == dest / "tracking.json.gz"
    assert TrackingResult.model_validate(storage.read_json(output.tracking_path))
    assert output.annotated_video_path.read_bytes() == b"annotated video"
    assert not list(dest.glob(".*.part"))

    processor.cleanup(handle, status.result)
    assert not run_dir.exists()
    assert processor.poll(handle).error.code == ErrorCode.WORKER_LOST


def test_local_unknown_handle_means_the_run_was_interrupted():
    status = LocalProcessor().poll("local:j_gone")
    assert status.state == "failed"
    assert status.error.code == ErrorCode.WORKER_LOST
    assert "interrupted" in status.error.message


@pytest.mark.parametrize(
    ("outcome", "code"),
    [
        (
            {"status": "error", "error": {"code": "VIDEO_DECODE_FAILED", "message": "bad codec"}},
            ErrorCode.VIDEO_DECODE_FAILED,
        ),
        (PipelineError("DETECTION_FAILED", "Only 2 players found"), ErrorCode.DETECTION_FAILED),
        (RuntimeError("CUDA out of memory. Tried to allocate 2.00 GiB"), ErrorCode.GPU_OOM),
        (ValueError("unexpected"), ErrorCode.PIPELINE_FAILED),
        ("not a dict", ErrorCode.TRACKING_RESULT_INVALID),
    ],
)
def test_local_failures_map_to_error_codes(monkeypatch, film, outcome, code):
    fake = FakeRunner(outcome)
    fake.release.set()
    monkeypatch.setattr(runner, "run_pipeline", fake)
    processor = LocalProcessor()
    status = _wait_until_finished(processor, processor.submit(job_id="j_bad", video=film, options={}))
    assert status.state == "failed"
    assert status.error.code == code


def test_local_cancel_only_stops_runs_that_have_not_started(monkeypatch, film):
    fake = FakeRunner()
    monkeypatch.setattr(runner, "run_pipeline", fake)
    processor = LocalProcessor()
    try:
        first = processor.submit(job_id="j_first", video=film, options={})
        assert fake.started.wait(timeout=5)
        second = processor.submit(job_id="j_second", video=film, options={})  # waits for the single GPU slot
        processor.cancel(second)
        processor.cancel(first)  # already running: only logged
        assert processor.poll(second).error.code == ErrorCode.JOB_CANCELLED
    finally:
        fake.release.set()
    assert _wait_until_finished(processor, first).state == "succeeded"
    assert [c["job_id"] for c in fake.calls] == ["j_first"]


def test_local_url_source_and_missing_file(monkeypatch, tmp_path):
    fake = FakeRunner()
    fake.release.set()
    monkeypatch.setattr(runner, "run_pipeline", fake)
    processor = LocalProcessor()
    url = VideoSource(kind="url", filename="film.mp4", url="https://films.example.org/film.mp4")
    _wait_until_finished(processor, processor.submit(job_id="j_url", video=url, options={}))
    assert fake.calls[0]["video_path"] == "https://films.example.org/film.mp4"

    gone = VideoSource(kind="file", filename="gone.mp4", path=tmp_path / "gone.mp4")
    with pytest.raises(ScoutError) as exc:
        processor.submit(job_id="j_gone", video=gone, options={})
    assert exc.value.code == ErrorCode.VIDEO_MISSING


def test_local_fetch_without_tracking_file(tmp_path):
    with pytest.raises(ScoutError) as exc:
        LocalProcessor().fetch("local:j_empty", {"status": "ok"}, tmp_path)
    assert exc.value.code == ErrorCode.TRACKING_RESULT_INVALID


def test_local_check_ready_needs_torch(monkeypatch):
    monkeypatch.setitem(sys.modules, "torch", None)  # makes `import torch` fail
    with pytest.raises(ScoutError) as exc:
        LocalProcessor().check_ready()
    assert exc.value.code == ErrorCode.MODEL_LOAD_FAILED
    assert exc.value.hint == "Install the GPU requirements: pip install -r modal_app/requirements-gpu.txt"

    monkeypatch.setitem(sys.modules, "torch", types.ModuleType("torch"))
    LocalProcessor().check_ready()
