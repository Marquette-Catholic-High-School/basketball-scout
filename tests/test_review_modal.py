"""Regression tests from the review of the Modal GPU app and the OpenHoopVision pipeline.

Each test pins a defect found in review: a recovered OOM warning that turned an unrelated
crash into GPU_OOM (and reran the film), a mid-run ReID failure nobody was told about,
OCR / ReID / OOM warnings OHV prints mid-run that landed on tqdm's progress-bar line and
were dropped with it, dropped chunked downloads, a silently half-analysed film, blank
deploy settings in .env, and OpenCV's libGL.
"""

from __future__ import annotations

import gzip
import http.client
import importlib
import io
import json
import os
import shutil
from pathlib import Path
from types import SimpleNamespace

import modal
import pytest

import modal_app.app as app_module
from modal_app.pipeline import errors, ohv, runner, video
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.video import VideoProbe
from scout.schemas import TrackingResult
from tests.test_modal_pipeline import _FakeOhv, _fake_ohv_home, _FakeProcess, _FakeResponse, _serve

FIXTURE = Path(__file__).parent / "fixtures" / "ohv_game.jsonl"  # 20 analysed frames at 15 fps
_REAL_RUN_OHV = ohv.run_ohv


# ---------------------------------------------------------------------------
# Runner with fake ffprobe / transcode / OHV (real adapter, events and result writer)
# ---------------------------------------------------------------------------


@pytest.fixture
def fakes(monkeypatch):
    """The film is 1080p at 30 fps; OHV "reads" the 20-frame fixture."""
    state = SimpleNamespace(duration_s=40 / 30, frame_count=None)

    def probe(path):
        if not os.path.isfile(path):
            raise PipelineError(errors.VIDEO_INVALID, "The video file was not found.", detail=str(path))
        frames = state.frame_count or round(state.duration_s * 30)
        return VideoProbe(
            path=str(path), fps=30.0, fps_rational="30/1", width=1920, height=1080,
            duration_s=state.duration_s, frame_count=frames, codec="h264",
        )  # fmt: skip

    def transcode(src, dst, plan, *, progress=None):
        Path(dst).write_bytes(b"analysis copy")
        return Path(dst)

    def run_ohv(video_path, work_dir, **kwargs):
        work = Path(work_dir)
        work.mkdir(parents=True, exist_ok=True)
        tracks = work / "ohv_tracks.jsonl"
        shutil.copyfile(FIXTURE, tracks)
        return ohv.OhvRun(
            tracks_path=tracks, events_path=work / "ohv_events.json", output_video=None, params=ohv.OhvParams(),
            attempts=1, summary=ohv.OhvSummary(),
        )  # fmt: skip

    monkeypatch.setattr(video, "probe_video", probe)
    monkeypatch.setattr(video, "check_decodable", lambda path: None)
    monkeypatch.setattr(video, "transcode_for_analysis", transcode)
    monkeypatch.setattr(ohv, "run_ohv", run_ohv)
    monkeypatch.setattr(ohv, "gpu_name", lambda: None)
    return state


def _run(tmp_path, source, options=None, filename="vs-central.mp4"):
    scratch = tmp_path / "scratch"
    scratch.mkdir(exist_ok=True)
    opts = {"render_video": False, "work_dir": str(scratch), **(options or {})}
    out = tmp_path / "results" / "j_1"
    response = runner.run_pipeline(str(source), opts, output_dir=str(out), job_id="j_1", filename=filename)
    return response, out, scratch


def _tracking(out: Path) -> TrackingResult:
    return TrackingResult.model_validate(json.loads(gzip.decompress((out / runner.TRACKING_FILE).read_bytes())))


def test_a_partially_decoded_film_is_flagged(fakes, tmp_path):
    """OHV stops at the first undecodable frame: stats that cover 1 s of a 60 s film need a warning."""
    fakes.duration_s = 60.0  # 900 analysed frames expected, the fixture has 20
    film = tmp_path / "film.mp4"
    film.write_bytes(b"film")
    response, out, _ = _run(tmp_path, film)
    assert response["status"] == "ok", response
    warning = next(w for w in response["warnings"] if w["code"] == "FILM_PARTIALLY_ANALYSED")
    assert "0:01" in warning["message"] and "1:00" in warning["message"]
    assert "FILM_PARTIALLY_ANALYSED" in {w.code for w in _tracking(out).warnings}


def test_a_completely_analysed_film_is_not_flagged(fakes, tmp_path):
    film = tmp_path / "film.mp4"
    film.write_bytes(b"film")
    response, _, _ = _run(tmp_path, film)
    assert response["status"] == "ok", response
    assert "FILM_PARTIALLY_ANALYSED" not in {w["code"] for w in response["warnings"]}
    # audio running a minute past the end of the video: the video stream's frames count
    fakes.duration_s, fakes.frame_count = 61.0, 40
    response, _, _ = _run(tmp_path, film)
    assert "FILM_PARTIALLY_ANALYSED" not in {w["code"] for w in response["warnings"]}
    # max_frames (testing) stops OHV on purpose: no warning either
    fakes.duration_s, fakes.frame_count = 60.0, None
    response, _, _ = _run(tmp_path, film, {"max_frames": 20})
    assert "FILM_PARTIALLY_ANALYSED" not in {w["code"] for w in response["warnings"]}


# ---------------------------------------------------------------------------
# OHV failure classification
# ---------------------------------------------------------------------------

RECOVERED_OOM_THEN_DISK_FULL = (
    "warning: jersey-number OCR is unavailable: OutOfMemoryError: CUDA out of memory. Tried to allocate 64.00 MiB\n"
    "frames: 54000, processing: 4400.12s, fps: 12.27; total: 4500.00s, end-to-end fps: 12.00\n"
    "Traceback (most recent call last):\n"
    '  File "/opt/openhoopvision/render/identity.py", line 131, in rewrite_identity_overlay\n'
    "OSError: [Errno 28] No space left on device\n"
)


def test_a_recovered_oom_warning_does_not_make_a_later_crash_gpu_oom():
    failure = ohv.classify_failure(1, RECOVERED_OOM_THEN_DISK_FULL.splitlines(), 54000)
    assert failure.code == errors.PIPELINE_FAILED
    fatal = ohv.classify_failure(1, ["warning: x", "torch.OutOfMemoryError: CUDA out of memory."], 10)
    assert fatal.code == errors.GPU_OOM  # a real OOM crash still is one


def test_reid_failing_mid_run_is_reported():
    """OHV turns identity matching off for the rest of the film when a ReID batch fails."""
    line = "warning: OSNet ReID inference failed; identity matching is disabled: OutOfMemoryError: CUDA out of memory."
    summary = ohv.parse_summary([line])
    assert summary.reid_error == "OutOfMemoryError: CUDA out of memory."
    assert [w["code"] for w in ohv.summary_warnings(summary)] == ["REID_UNAVAILABLE"]


def _bar(done: int, total: int | None = 1000) -> str:
    """One tqdm redraw of OHV's progress bar (stderr): a carriage return, then the bar, no newline."""
    if total is None:  # OpenCV did not know the frame count
        return f"\rProcessing analysis.mp4: {done}frame [00:10, 11.70frame/s]"
    return f"\rProcessing analysis.mp4: {100 * done // total:3d}%|#         | {done}/{total} [00:10<01:15, 11.70frame/s]"


# What OHV's merged stdout/stderr looks like: whatever it prints mid-run lands on the bar's line.
GLUED_TO_THE_BAR = (
    "ohv-bootstrap: court 25.60 x 15.24 m\n" + _bar(0) + _bar(10)
    + "warning: jersey-number OCR is unavailable: OutOfMemoryError: CUDA out of memory.\n" + _bar(200)
    + "CUDA memory limit reached; detector batch size reduced to 8\n" + _bar(500)
    + "warning: OSNet ReID inference failed; identity matching is disabled: OutOfMemoryError: CUDA out of memory.\n"
    + _bar(1000) + "\n"
    + "team colors (BGR): [(35, 30, 120), (230, 232, 235)]; locked=True\n"
    + "frames: 1000, processing: 85.00s, fps: 11.76; total: 90.00s, end-to-end fps: 11.11\n"
)  # fmt: skip


def test_warnings_printed_mid_run_are_not_lost_on_the_progress_bar_line(tmp_path, monkeypatch):
    """OCR / ReID failures and detector OOM recoveries all happen while tqdm's bar is up."""
    monkeypatch.setattr(ohv.subprocess, "Popen", _FakeOhv((0, GLUED_TO_THE_BAR, 1000)))
    run = ohv.run_ohv(
        tmp_path / "in.mp4", tmp_path / "work", analysis_fps=15.0, expected_frames=1000, court=ohv.CourtSpec(),
        render=True, home=_fake_ohv_home(tmp_path), poll_interval_s=0.0,
    )  # fmt: skip
    assert [w["code"] for w in run.warnings] == [ohv.OOM_RECOVERED, "OCR_UNAVAILABLE", "REID_UNAVAILABLE"]
    assert run.summary.frames == 1000 and run.summary.team_colors_bgr == [(35, 30, 120), (230, 232, 235)]
    assert not any("Processing analysis.mp4" in line for line in run.log_tail)  # the bars themselves are dropped


def test_ocr_and_reid_failures_during_the_run_reach_the_coach(fakes, tmp_path, monkeypatch):
    """Real run_ohv, adapter and result writer: the warnings end up in tracking.json.gz."""

    def popen(cmd, **kwargs):  # OHV "analyses" the fixture film, printing over its progress bar
        shutil.copyfile(FIXTURE, cmd[cmd.index("--tracks") + 1])
        return _FakeProcess(0, GLUED_TO_THE_BAR.encode())

    monkeypatch.setattr(ohv, "run_ohv", _REAL_RUN_OHV)
    monkeypatch.setattr(ohv.subprocess, "Popen", popen)
    monkeypatch.setenv("OHV_HOME", str(_fake_ohv_home(tmp_path)))
    film = tmp_path / "film.mp4"
    film.write_bytes(b"film")
    response, out, _ = _run(tmp_path, film)
    assert response["status"] == "ok", response
    expected = {"OCR_UNAVAILABLE", "REID_UNAVAILABLE", ohv.OOM_RECOVERED}
    assert expected <= {w["code"] for w in response["warnings"]}
    assert expected <= {w.code for w in _tracking(out).warnings}


def test_a_bar_without_a_frame_total_neither_floods_the_log_nor_hides_warnings():
    collector = ohv._OutputCollector(
        io.BytesIO((_bar(0, None) + _bar(15, None) + "warning: OSNet ReID is unavailable; x: y\n" + _bar(30, None)).encode())
    )
    collector.run()
    assert list(collector.lines) == ["warning: OSNet ReID is unavailable; x: y"]


def test_a_crash_after_a_glued_oom_warning_is_still_not_gpu_oom(tmp_path, monkeypatch):
    crash = GLUED_TO_THE_BAR.split("team colors")[0] + "Traceback (most recent call last):\nKeyError: 'center'\n"
    fake = _FakeOhv((1, crash, 1000), (0, "", 1000), (0, "", 1000))
    monkeypatch.setattr(ohv.subprocess, "Popen", fake)
    with pytest.raises(PipelineError) as info:
        ohv.run_ohv(
            tmp_path / "in.mp4", tmp_path / "work", analysis_fps=15.0, expected_frames=1000, court=ohv.CourtSpec(),
            render=True, home=_fake_ohv_home(tmp_path), poll_interval_s=0.0,
        )  # fmt: skip
    assert info.value.code == errors.PIPELINE_FAILED and len(fake.commands) == 1


def test_run_ohv_does_not_rerun_the_film_for_a_non_oom_crash(tmp_path, monkeypatch):
    fake = _FakeOhv((1, RECOVERED_OOM_THEN_DISK_FULL, 54000), (0, "", 54000), (0, "", 54000))
    monkeypatch.setattr(ohv.subprocess, "Popen", fake)
    with pytest.raises(PipelineError) as info:
        ohv.run_ohv(
            tmp_path / "in.mp4", tmp_path / "work", analysis_fps=15.0, expected_frames=54000, court=ohv.CourtSpec(),
            render=True, home=_fake_ohv_home(tmp_path), poll_interval_s=0.0,
        )  # fmt: skip
    assert info.value.code == errors.PIPELINE_FAILED and len(fake.commands) == 1
    assert "No space left on device" in info.value.detail


# ---------------------------------------------------------------------------
# URL download on a flaky connection
# ---------------------------------------------------------------------------


class _DroppedChunkedResponse(io.BytesIO):
    """A chunked response (no Content-Length) whose connection drops mid-transfer."""

    def __init__(self) -> None:
        super().__init__(b"")
        self.headers = {"Content-Type": "video/mp4"}

    def read(self, *args):
        raise http.client.IncompleteRead(b"partial")


def test_download_retries_a_dropped_chunked_transfer(monkeypatch, tmp_path):
    _serve(monkeypatch, _DroppedChunkedResponse(), _FakeResponse(b"film"))
    assert video.download_video("https://example.org/f.mp4", tmp_path / "f.mp4").read_bytes() == b"film"


def test_download_explains_a_connection_that_keeps_dropping(monkeypatch, tmp_path):
    _serve(monkeypatch, *[_DroppedChunkedResponse() for _ in range(3)])
    with pytest.raises(PipelineError) as info:
        video.download_video("https://example.org/f.mp4", tmp_path / "dl" / "f.mp4")
    assert info.value.code == errors.VIDEO_DOWNLOAD_FAILED
    assert not list((tmp_path / "dl").iterdir())  # no partial file left behind


# ---------------------------------------------------------------------------
# Deploy-time settings and the image
# ---------------------------------------------------------------------------


@pytest.fixture
def reload_app(monkeypatch):
    changed: list[str] = []

    def reload(**env: str):
        for key, value in env.items():
            monkeypatch.setenv(key, value)
            changed.append(key)
        return importlib.reload(app_module)

    yield reload
    for key in changed:
        monkeypatch.delenv(key, raising=False)
    importlib.reload(app_module)


def test_blank_deploy_settings_in_env_fall_back_to_the_defaults(reload_app):
    """`dotenv run -- modal deploy` turns `SCOUT_MODAL_GPU=` lines into empty strings."""
    blank = ("GPU", "TIMEOUT_S", "MAX_CONTAINERS", "APP_NAME", "VOLUME_NAME", "PROGRESS_DICT")
    module = reload_app(**{f"SCOUT_MODAL_{name}": "" for name in blank})
    assert (module.GPU_TYPE, module.PROCESS_TIMEOUT_S, module.MAX_CONTAINERS) == ("A10G", 21600, 2)
    assert (module.APP_NAME, module.VOLUME_NAME) == ("basketball-scout", "basketball-scout-data")
    assert module.PROGRESS_DICT_NAME == "basketball-scout-progress"
    module = reload_app(SCOUT_MODAL_MAX_CONTAINERS="two", SCOUT_MODAL_GPU=" L40S ")
    assert (module.MAX_CONTAINERS, module.GPU_TYPE) == (2, "L40S")


def test_image_installs_libgl_for_opencv(monkeypatch):
    """supervision / rfdetr pull in the GUI build of OpenCV, whose cv2 needs libGL.so.1."""
    installed: list[str] = []

    def apt_install(self, *packages, **kwargs):
        installed.extend(packages)
        return self

    monkeypatch.setattr(modal.Image, "apt_install", apt_install)
    app_module.build_image()
    assert {"ffmpeg", "libgl1"} <= set(installed)
    # the OpenCV distribution OHV's requirements.lock validated, not a second cv2 build
    assert "opencv-python==5.0.0.93" in ohv.OHV_REQUIREMENTS
    assert not any(pin.startswith("opencv-python-headless") for pin in ohv.OHV_REQUIREMENTS)
