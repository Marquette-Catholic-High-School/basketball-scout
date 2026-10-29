"""GPU pipeline pieces without a GPU, ffmpeg or network: video helpers, the OpenHoopVision
subprocess wrapper (fake Popen), the web render, TrackingResult serialisation and the
runner end to end (OHV / ffmpeg / supplementary events mocked)."""

from __future__ import annotations

import gzip
import io
import json
import os
import shutil
import urllib.error
from pathlib import Path
from typing import Any

import pytest

from modal_app.pipeline import adapter, errors, ohv, render, result, runner, video
from modal_app.pipeline import events as extra_events
from modal_app.pipeline import possession
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.types import TrackData, TrackObs, VideoMeta
from modal_app.pipeline.video import FrameMap, VideoProbe
from scout.schemas import TrackingResult

FIXTURE = Path(__file__).parent / "fixtures" / "ohv_game.jsonl"


def _ffprobe(**video_overrides: Any) -> dict[str, Any]:
    stream = {
        "index": 0, "codec_name": "h264", "codec_type": "video", "width": 1920, "height": 1080,
        "r_frame_rate": "30000/1001", "avg_frame_rate": "30000/1001", "nb_frames": "107892", "duration": "3600.033",
        "disposition": {"attached_pic": 0},
    }  # fmt: skip
    stream.update(video_overrides)
    return {
        "streams": [stream, {"index": 1, "codec_type": "audio", "codec_name": "aac"}],
        "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "3600.05", "size": "4123456789"},
    }


def _probe(**overrides: Any) -> VideoProbe:
    values = dict(path="game.mp4", fps=30.0, fps_rational="30/1", width=1920, height=1080, duration_s=40 / 30, frame_count=40, codec="h264")
    values.update(overrides)
    return VideoProbe(**values)


# ---------------------------------------------------------------------------
# video: ffprobe parsing, validation, analysis plan
# ---------------------------------------------------------------------------


def test_parse_ffprobe_json():
    probe = video.parse_ffprobe_json(_ffprobe(), path="game.mp4")
    assert probe.fps == pytest.approx(29.97003) and probe.fps_rational == "30000/1001"
    assert (probe.width, probe.height, probe.frame_count, probe.codec) == (1920, 1080, 107892, "h264")
    assert probe.duration_s == pytest.approx(3600.05) and probe.size_bytes == 4123456789


def test_parse_ffprobe_rotation_and_fallbacks():
    rotated = video.parse_ffprobe_json(_ffprobe(side_data_list=[{"rotation": -90}]), path="phone.mov")
    assert (rotated.width, rotated.height, rotated.rotation) == (1080, 1920, 270)
    no_avg = video.parse_ffprobe_json(_ffprobe(avg_frame_rate="0/0", r_frame_rate="25/1", nb_frames=None), path="x.mp4")
    assert no_avg.fps == 25.0 and no_avg.frame_count == round(3600.05 * 25)


@pytest.mark.parametrize(
    ("data", "code"),
    [
        ({"streams": [{"codec_type": "audio"}], "format": {}}, errors.VIDEO_INVALID),
        ({"streams": [{"codec_type": "video", "disposition": {"attached_pic": 1}, "width": 300, "height": 300}]}, errors.VIDEO_INVALID),
        (_ffprobe(width=0), errors.VIDEO_DECODE_FAILED),
        (_ffprobe(avg_frame_rate="0/0", r_frame_rate="0/0"), errors.VIDEO_DECODE_FAILED),
    ],
)
def test_parse_ffprobe_rejects_unusable_files(data, code):
    with pytest.raises(PipelineError) as info:
        video.parse_ffprobe_json(data, path="x")
    assert info.value.code == code


def test_validate_probe():
    video.validate_probe(_probe(duration_s=3600.0), max_duration_s=9000)
    with pytest.raises(PipelineError) as too_long:
        video.validate_probe(_probe(duration_s=9600.0), max_duration_s=9000)
    assert too_long.value.code == errors.VIDEO_TOO_LONG and "160 minutes" in too_long.value.message
    with pytest.raises(PipelineError) as empty:
        video.validate_probe(_probe(duration_s=0.0, frame_count=0), max_duration_s=9000)
    assert empty.value.code == errors.VIDEO_DECODE_FAILED


class _Completed:
    def __init__(self, returncode: int, stdout: bytes = b"", stderr: bytes = b"") -> None:
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


def test_probe_video_errors(tmp_path, monkeypatch):
    with pytest.raises(PipelineError) as missing:
        video.probe_video(tmp_path / "nope.mp4")
    assert missing.value.code == errors.VIDEO_INVALID
    film = tmp_path / "film.mp4"
    film.write_bytes(b"not really a video")
    monkeypatch.setattr(video.subprocess, "run", lambda *a, **k: _Completed(1, stderr=b"Invalid data found when processing input"))
    with pytest.raises(PipelineError) as invalid:
        video.probe_video(film)
    assert invalid.value.code == errors.VIDEO_INVALID and "Invalid data" in invalid.value.detail
    monkeypatch.setattr(video.subprocess, "run", lambda *a, **k: _Completed(0, stdout=json.dumps(_ffprobe()).encode()))
    assert video.probe_video(film).frame_count == 107892
    monkeypatch.setattr(video.subprocess, "run", lambda *a, **k: _Completed(1, stderr=b"moov atom not found"))
    with pytest.raises(PipelineError) as corrupt:
        video.check_decodable(film)
    assert corrupt.value.code == errors.VIDEO_DECODE_FAILED

    def no_ffmpeg(*_a, **_k):
        raise FileNotFoundError("ffprobe")

    monkeypatch.setattr(video.subprocess, "run", no_ffmpeg)
    with pytest.raises(PipelineError) as not_installed:
        video.probe_video(film)
    assert not_installed.value.code == errors.PIPELINE_FAILED


def test_plan_for_1080p_30fps_film_downscales_and_halves_the_rate():
    probe = video.parse_ffprobe_json(_ffprobe(), path="game.mp4")
    plan = video.plan_analysis(probe, filename="game.mp4", analysis_fps=15, max_side=1280)
    assert plan.transcode and plan.step == 2 and plan.fps_rational == "15000/1001"
    assert (plan.width, plan.height) == (1280, 720)
    assert plan.analysed_fps == pytest.approx(14.985015)
    assert plan.meta.fps == pytest.approx(29.97003) and plan.meta.step == 2 and plan.meta.width == 1920
    assert [plan.frame_map.to_original(k) for k in (0, 1, 1000, 53946)] == [0, 2, 2000, 107892]
    assert plan.frame_map.bbox((100, 100, 200, 300)) == pytest.approx((150, 150, 300, 450))
    assert plan.expected_frames == round(3600.05 * 14.985015)


def test_plan_without_transcode_for_ready_film():
    plan = video.plan_analysis(_probe(fps=15.0, fps_rational="15/1", width=1280, height=720), filename="a.mp4", analysis_fps=15, max_side=1280)
    assert not plan.transcode and plan.step == 1 and plan.frame_map == FrameMap.identity(15.0)
    assert plan.meta.analysis_fps == 15.0


@pytest.mark.parametrize(
    ("overrides", "reason"),
    [({"codec": "hevc", "fps": 15.0, "fps_rational": "15/1", "width": 1280, "height": 720}, "codec"),
     ({"fps": 15.0, "fps_rational": "15/1", "width": 1279, "height": 720}, "odd width")],
)  # fmt: skip
def test_plan_transcodes_other_codecs_and_odd_sizes(overrides, reason):
    assert video.plan_analysis(_probe(**overrides), filename="a.mp4", analysis_fps=15, max_side=1280).transcode, reason


def test_plan_25fps_film_uses_the_server_step_formula():
    plan = video.plan_analysis(_probe(fps=25.0, fps_rational="25/1", width=1280, height=720), filename="a", analysis_fps=15, max_side=1280)
    assert plan.step == 2 and plan.analysed_fps == 12.5  # round(25 / 15) = 2, as scout.analysis.tracking_index
    assert plan.frame_map.to_original(7) == 14


def test_transcode_command():
    plan = video.plan_analysis(video.parse_ffprobe_json(_ffprobe(), path="in.mp4"), filename="in.mp4")
    cmd = video.build_transcode_command("in.mp4", "out.mp4", plan)
    assert cmd[0] == "ffmpeg" and cmd[-1] == "out.mp4"
    assert cmd[cmd.index("-vf") + 1] == "fps=15000/1001,scale=1280:720:flags=bicubic"
    assert {"-an", "-nostdin"} <= set(cmd) and cmd[cmd.index("-c:v") + 1] == "libx264"
    assert cmd[cmd.index("-progress") + 1] == "pipe:1"


def test_parse_progress_frame():
    assert video.parse_progress_frame("frame=1234\n") == 1234
    assert video.parse_progress_frame("fps=12.0") is None
    assert video.parse_progress_frame("frame=N/A") is None


class _FakeFfmpeg:
    """subprocess.Popen stand-in: prints ``-progress`` lines and an optional error."""

    def __init__(self, returncode: int = 0, frames: int = 10, error: str = "") -> None:
        self.returncode, self.frames, self.error = returncode, frames, error
        self.commands: list[list[str]] = []

    def __call__(self, cmd, stdin=None, stdout=None, stderr=None):
        self.commands.append(cmd)
        if stderr is not None and self.error:
            stderr.write(self.error.encode())
        if self.returncode == 0 and not cmd[-1].startswith("-"):
            Path(cmd[-1]).write_bytes(b"mp4")
        lines = "".join(f"frame={n}\nprogress=continue\n" for n in range(0, self.frames + 1, 5))
        proc = _FakeProcess(self.returncode, lines.encode())
        return proc


class _FakeProcess:
    def __init__(self, returncode: int, output: bytes, polls_before_exit: int = 0) -> None:
        self.stdout = io.BytesIO(output)
        self.returncode = returncode
        self._polls = polls_before_exit
        self.killed = False

    def poll(self):
        if self.killed:
            return -9
        if self._polls > 0:
            self._polls -= 1
            return None
        return self.returncode

    def wait(self, timeout=None):
        return -9 if self.killed else self.returncode

    def kill(self):
        self.killed = True


def test_run_ffmpeg_reports_progress_and_errors(monkeypatch, tmp_path):
    fake = _FakeFfmpeg(frames=20)
    monkeypatch.setattr(video.subprocess, "Popen", fake)
    seen: list[float] = []
    video.run_ffmpeg(["ffmpeg", str(tmp_path / "o.mp4")], expected_frames=20, progress=lambda f, m: seen.append(f), message="x")
    assert seen == [0.0, 0.25, 0.5, 0.75, 1.0]
    monkeypatch.setattr(video.subprocess, "Popen", _FakeFfmpeg(returncode=1, error="Error while decoding stream #0:0"))
    with pytest.raises(PipelineError) as info:
        video.run_ffmpeg(["ffmpeg", "-"], error_code=errors.VIDEO_DECODE_FAILED, error_message="bad film")
    assert info.value.code == errors.VIDEO_DECODE_FAILED and "decoding stream" in info.value.detail


# ---------------------------------------------------------------------------
# video: URL download (urlopen faked; no network)
# ---------------------------------------------------------------------------


class _FakeResponse(io.BytesIO):
    def __init__(self, body: bytes, content_type: str = "video/mp4", length: int | None = None) -> None:
        super().__init__(body)
        self.headers = {"Content-Type": content_type, "Content-Length": str(len(body) if length is None else length)}


def _serve(monkeypatch, *responses):
    queue = list(responses)

    def urlopen(request, timeout=None):
        item = queue.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    monkeypatch.setattr(video.urllib.request, "urlopen", urlopen)
    monkeypatch.setattr(video.time, "sleep", lambda s: None)


def test_download_streams_to_file_with_progress(monkeypatch, tmp_path):
    body = os.urandom(3000)
    _serve(monkeypatch, _FakeResponse(body))
    monkeypatch.setattr(video, "_DOWNLOAD_CHUNK", 1000)
    fractions: list[float] = []
    dest = video.download_video("https://example.org/game.mp4", tmp_path / "game.mp4", progress=lambda f, m: fractions.append(f))
    assert dest.read_bytes() == body and not (tmp_path / "game.mp4.part").exists()
    assert fractions == pytest.approx([1 / 3, 2 / 3, 1.0])
    # a finished download is reused (no request is made)
    _serve(monkeypatch)
    assert video.download_video("https://example.org/game.mp4", dest) == dest


@pytest.mark.parametrize(
    ("responses", "fragment"),
    [
        ([_FakeResponse(b"<html>", content_type="text/html; charset=utf-8")], "web page"),
        ([_FakeResponse(b"x" * 10, length=10**12)], "download limit"),
        ([urllib.error.HTTPError("u", 404, "Not Found", {}, None)], "HTTP 404"),
        ([urllib.error.URLError("dns")] * 3, "could not be reached"),
        ([_FakeResponse(b"")], "empty file"),
    ],
)
def test_download_failures_are_explained(monkeypatch, tmp_path, responses, fragment):
    _serve(monkeypatch, *responses)
    downloads = tmp_path / "downloads"
    with pytest.raises(PipelineError) as info:
        video.download_video("https://example.org/film.mp4", downloads / "film.mp4", max_bytes=10**9)
    assert info.value.code == errors.VIDEO_DOWNLOAD_FAILED and fragment in info.value.message
    assert not list(downloads.iterdir())  # no partial file left behind


def test_download_retries_transient_errors(monkeypatch, tmp_path):
    _serve(monkeypatch, urllib.error.HTTPError("u", 503, "busy", {}, None), _FakeResponse(b"film"))
    assert video.download_video("http://example.org/f.mp4", tmp_path / "f.mp4").read_bytes() == b"film"


def test_download_rejects_non_http_links(tmp_path):
    with pytest.raises(PipelineError) as info:
        video.download_video("ftp://example.org/f.mp4", tmp_path / "f.mp4")
    assert info.value.code == errors.VIDEO_DOWNLOAD_FAILED


# ---------------------------------------------------------------------------
# ohv: parameters, command line, subprocess handling
# ---------------------------------------------------------------------------


def test_params_scale_with_analysis_fps():
    at15 = ohv.OhvParams().scaled_for_fps(15.0)
    assert (at15.court_interval, at15.cmc_interval, at15.holder_hold_frames, at15.trail_length) == (2, 1, 6, 8)
    assert at15.track_buffer == 30  # OHV's tracker already scales this by fps / 30
    assert ohv.OhvParams().scaled_for_fps(30.0) == ohv.OhvParams()
    at60 = ohv.OhvParams().scaled_for_fps(60.0)
    assert (at60.court_interval, at60.cmc_interval, at60.holder_hold_frames) == (5, 4, 24)  # court map freshness cap
    capped = at15.capped(detector_batch_size=4, pose_batch_size=8, short_side=640)
    assert (capped.detector_batch_size, capped.pose_batch_size, capped.short_side) == (4, 8, 640)
    assert capped.capped(detector_batch_size=16, pose_batch_size=32, short_side=768) == capped  # never raised


def _weights(root: Path) -> dict[str, Path]:
    return {w.name: root / w.name for w in ohv.WEIGHTS}


def test_build_command_uses_only_real_ohv_flags_and_explicit_paths(tmp_path):
    cmd = ohv.build_command(
        python="python3", bootstrap=tmp_path / "b.py", court_file=tmp_path / "c.json", video=tmp_path / "in.mp4",
        tracks=tmp_path / "t.jsonl", events=tmp_path / "e.json", output=None,
        params=ohv.OhvParams(max_frames=50).scaled_for_fps(15.0), weights=_weights(tmp_path),
    )  # fmt: skip
    assert cmd[:3] == ["python3", str(tmp_path / "b.py"), str(tmp_path / "c.json")]
    flags = cmd[3::2]
    values = dict(zip(flags, cmd[4::2], strict=True))
    assert set(flags) <= ohv.OHV_FLAGS
    assert values["--output"] == "none" and values["--tracks"] == str(tmp_path / "t.jsonl")
    assert values["--events"] == str(tmp_path / "e.json") and values["--max-frames"] == "50"
    assert values["--court-interval"] == "2" and values["--holder-hold-frames"] == "6"
    assert values["--model"] == str(tmp_path / "rf-detr-basketball.pth")
    assert values["--court-model"] == str(tmp_path / "court_mobilenetv4_896x512.pt")


def _fake_ohv_home(tmp_path: Path) -> Path:
    home = tmp_path / "ohv_home"
    (home / "weights").mkdir(parents=True)
    (home / "main.py").write_text("# fake")
    for weight in ohv.WEIGHTS:
        (home / "weights" / weight.name).write_bytes(b"w" * 2048)
    return home


class _FakeOhv:
    """subprocess.Popen stand-in for OHV: each launch follows the next scripted outcome."""

    def __init__(self, *outcomes: tuple[int, str, int], polls_before_exit: int = 0) -> None:
        self.outcomes = list(outcomes)
        self.polls_before_exit = polls_before_exit
        self.commands: list[list[str]] = []
        self.processes: list[_FakeProcess] = []

    def __call__(self, cmd, cwd=None, env=None, stdin=None, stdout=None, stderr=None):
        self.commands.append(cmd)
        returncode, output, frames = self.outcomes.pop(0)
        tracks = Path(cmd[cmd.index("--tracks") + 1])
        tracks.write_text("".join(json.dumps({"frame": n}) + "\n" for n in range(1, frames + 1)))
        target = cmd[cmd.index("--output") + 1]
        if returncode == 0 and target != "none":
            Path(target).write_bytes(b"annotated")
        proc = _FakeProcess(returncode, output.encode(), self.polls_before_exit)
        self.processes.append(proc)
        return proc


def _run_ohv(tmp_path, monkeypatch, fake, **kwargs):
    monkeypatch.setattr(ohv.subprocess, "Popen", fake)
    defaults = dict(analysis_fps=15.0, expected_frames=100, court=ohv.CourtSpec(), render=True,
                    home=_fake_ohv_home(tmp_path), poll_interval_s=0.0)  # fmt: skip
    defaults.update(kwargs)
    return ohv.run_ohv(tmp_path / "in.mp4", tmp_path / "work", **defaults)


SUMMARY_OUTPUT = """ohv-bootstrap: court 25.60 x 15.24 m
Processing in.mp4:  50%|#####     | 50/100 [00:05<00:05, 9.8frame/s]\rProcessing in.mp4: 100%|##########| 100/100 [00:10<00:00, 9.9frame/s]
team colors (BGR): [(35, 30, 120), (230, 232, 235)]; locked=True
frames: 100, processing: 10.10s, fps: 9.90; total: 12.00s, end-to-end fps: 8.33
"""


def test_run_ohv_success(tmp_path, monkeypatch):
    fake = _FakeOhv((0, SUMMARY_OUTPUT, 100))
    run = _run_ohv(tmp_path, monkeypatch, fake)
    assert run.attempts == 1 and run.warnings == []
    assert run.summary.team_colors_bgr == [(35, 30, 120), (230, 232, 235)] and run.summary.frames == 100
    assert run.output_video == tmp_path / "work" / "ohv_annotated.mp4" and run.output_video.is_file()
    assert (tmp_path / "work" / "ohv_bootstrap.py").is_file()
    assert json.loads((tmp_path / "work" / "ohv_court.json").read_text())["length_m"] == pytest.approx(25.6032)
    assert not any("Processing in.mp4" in line for line in run.log_tail)  # tqdm bars are not logged
    cmd = fake.commands[0]
    assert cmd[cmd.index("--detector-batch-size") + 1] == "16" and cmd[cmd.index("--court-interval") + 1] == "2"


def test_run_ohv_reports_progress_from_the_growing_jsonl(tmp_path, monkeypatch):
    fake = _FakeOhv((0, "", 50), polls_before_exit=2)
    seen: list[tuple[float, str]] = []
    _run_ohv(tmp_path, monkeypatch, fake, expected_frames=100, progress=lambda f, m: seen.append((f, m)))
    assert seen and seen[0][0] == pytest.approx(0.92 * 0.5)
    assert "frame 50 of 100" in seen[0][1]


def test_run_ohv_retries_cuda_oom_with_smaller_batches(tmp_path, monkeypatch):
    oom = "Traceback (most recent call last):\ntorch.OutOfMemoryError: CUDA out of memory. Tried to allocate 2.00 GiB\n"
    fake = _FakeOhv((1, oom, 12), (0, SUMMARY_OUTPUT, 100))
    run = _run_ohv(tmp_path, monkeypatch, fake)
    assert run.attempts == 2 and len(fake.commands) == 2
    second = fake.commands[1]
    assert second[second.index("--detector-batch-size") + 1] == "4" and second[second.index("--short-side") + 1] == "640"
    assert run.params.pose_batch_size == 8
    assert run.warnings[0]["code"] == ohv.OOM_RECOVERED


def test_run_ohv_gives_up_after_the_oom_ladder(tmp_path, monkeypatch):
    oom = (1, "RuntimeError: CUDA error: out of memory\n", 0)
    fake = _FakeOhv(*[oom] * len(ohv.OOM_LADDER))
    with pytest.raises(PipelineError) as info:
        _run_ohv(tmp_path, monkeypatch, fake)
    assert info.value.code == errors.GPU_OOM and "batch size 1" in info.value.message
    assert len(fake.commands) == len(ohv.OOM_LADDER)


@pytest.mark.parametrize(
    ("returncode", "output", "frames", "code"),
    [
        (1, "Traceback\nFileNotFoundError: RTMPose checkpoint not found: /w/x.pth\n", 0, errors.MODEL_LOAD_FAILED),
        (1, "_pickle.UnpicklingError: invalid load key, 'v'.\n", 0, errors.MODEL_LOAD_FAILED),
        (1, "RuntimeError: cannot open video: /tmp/in.mp4\n", 0, errors.VIDEO_DECODE_FAILED),
        (ohv.NO_CUDA_EXIT_CODE, "ohv-bootstrap: PyTorch cannot see a CUDA GPU\n", 0, errors.PIPELINE_FAILED),
        (-9, "", 400, errors.PIPELINE_FAILED),
        (1, "Traceback\nKeyError: 'center'\n", 400, errors.PIPELINE_FAILED),
    ],
)
def test_run_ohv_classifies_failures(tmp_path, monkeypatch, returncode, output, frames, code):
    fake = _FakeOhv((returncode, output, frames))
    with pytest.raises(PipelineError) as info:
        _run_ohv(tmp_path, monkeypatch, fake)
    assert info.value.code == code and len(fake.commands) == 1
    if output:
        assert output.strip().splitlines()[-1] in info.value.detail


def test_run_ohv_kills_a_stalled_process(tmp_path, monkeypatch):
    fake = _FakeOhv((0, "", 3), polls_before_exit=10**9)
    with pytest.raises(PipelineError) as info:
        _run_ohv(tmp_path, monkeypatch, fake, stall_timeout_s=0.01, poll_interval_s=0.005)
    assert info.value.code == errors.PIPELINE_FAILED and "stopped making progress" in info.value.message
    assert fake.processes[0].killed


def test_run_ohv_requires_an_installed_checkout_with_real_weights(tmp_path, monkeypatch):
    with pytest.raises(PipelineError) as missing:
        ohv.run_ohv(tmp_path / "in.mp4", tmp_path / "w", analysis_fps=15, expected_frames=1, court=ohv.CourtSpec(), render=False, home=tmp_path / "none")
    assert missing.value.code == errors.MODEL_LOAD_FAILED
    home = _fake_ohv_home(tmp_path)
    (home / "weights" / "rf-detr-basketball.pth").write_text("version https://git-lfs.github.com/spec/v1\n")
    with pytest.raises(PipelineError) as pointer:
        ohv.run_ohv(tmp_path / "in.mp4", tmp_path / "w", analysis_fps=15, expected_frames=1, court=ohv.CourtSpec(), render=False, home=home)
    assert pointer.value.code == errors.MODEL_LOAD_FAILED and "Git LFS" in pointer.value.message


def test_parse_summary_and_warnings():
    lines = [
        "team colors (BGR): [(35, 30, 120), (230, 232, 235)]; locked=True",
        "CUDA memory limit reached; detector batch size reduced to 8",
        "frames: 54000, processing: 4400.12s, fps: 12.27; total: 4500.00s, end-to-end fps: 12.00",
        "warning: jersey-number OCR is unavailable: FileNotFoundError: SVTRv2 jersey checkpoint not found: /x",
        "warning: OSNet ReID is unavailable; identity matching is disabled: RuntimeError: bad",
    ]
    summary = ohv.parse_summary(lines)
    assert summary.team_colors_bgr == [(35, 30, 120), (230, 232, 235)]
    assert (summary.detector_batch_reductions, summary.frames, summary.processing_fps) == (1, 54000, 12.27)
    assert summary.ocr_error.startswith("FileNotFoundError") and summary.reid_error == "RuntimeError: bad"
    assert [w["code"] for w in ohv.summary_warnings(summary)] == [ohv.OOM_RECOVERED, "OCR_UNAVAILABLE", "REID_UNAVAILABLE"]


def test_line_counter_follows_appends_and_replacement(tmp_path):
    path = tmp_path / "t.jsonl"
    counter = ohv._LineCounter(path)
    assert counter.count() == 0
    path.write_text("a\nb\n")
    assert counter.count() == 2
    with open(path, "a") as fh:
        fh.write("c\npartial")
    assert counter.count() == 3
    replacement = tmp_path / "t.jsonl.tmp"
    replacement.write_text("1\n2\n3\n4\n")
    os.replace(replacement, path)  # what OHV does when it rewrites jersey numbers
    assert counter.count() == 4


def test_is_oom_text():
    assert ohv.is_oom_text("torch.OutOfMemoryError: CUDA out of memory.")
    assert ohv.is_oom_text("CUBLAS_STATUS_ALLOC_FAILED")
    assert not ohv.is_oom_text("MemoryError: out of memory")  # host RAM, not the GPU


# ---------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------


def test_render_commands():
    x264 = render.build_render_command("in.mp4", "out.mp4", target_height=720, source_height=1080, encoder=render.X264)
    assert x264[x264.index("-vf") + 1] == "scale=-2:'min(720,ih)'"
    assert x264[x264.index("-crf") + 1] == "26" and x264[x264.index("-pix_fmt") + 1] == "yuv420p"
    assert x264[x264.index("-movflags") + 1] == "+faststart" and "-an" in x264
    nvenc = render.build_render_command("in.mp4", "out.mp4", target_height=720, source_height=720, encoder=render.NVENC)
    assert "-vf" not in nvenc  # never upscale or rescale a 720p source
    assert nvenc[nvenc.index("-c:v") + 1] == "h264_nvenc"


def test_render_falls_back_to_libx264(monkeypatch, tmp_path):
    monkeypatch.setattr(render, "nvenc_available", lambda: True)
    encoders: list[str] = []

    def fake_run(cmd, **kwargs):
        encoder = cmd[cmd.index("-c:v") + 1]
        encoders.append(encoder)
        if encoder == render.NVENC:
            Path(cmd[-1]).write_bytes(b"half")
            raise PipelineError(errors.PIPELINE_FAILED, "nvenc broke", detail="No NVENC capable devices found")
        Path(cmd[-1]).write_bytes(b"web mp4")

    monkeypatch.setattr(render, "run_ffmpeg", fake_run)
    dst = tmp_path / "out" / "annotated.mp4"
    assert render.render_web_video(tmp_path / "in.mp4", dst, target_height=720, source_height=720) == render.X264
    assert encoders == [render.NVENC, render.X264]
    assert dst.read_bytes() == b"web mp4" and sorted(p.name for p in dst.parent.iterdir()) == ["annotated.mp4"]


def test_render_raises_when_every_encoder_fails(monkeypatch, tmp_path):
    monkeypatch.setattr(render, "nvenc_available", lambda: False)

    def broken(cmd, **kwargs):
        raise PipelineError(errors.PIPELINE_FAILED, "x264 broke")

    monkeypatch.setattr(render, "run_ffmpeg", broken)
    with pytest.raises(PipelineError):
        render.render_web_video(tmp_path / "in.mp4", tmp_path / "annotated.mp4")


def test_nvenc_probe_is_cached_and_safe_without_ffmpeg(monkeypatch):
    calls = []

    def no_ffmpeg(*a, **k):
        calls.append(a)
        raise FileNotFoundError("ffmpeg")

    render.nvenc_available.cache_clear()
    monkeypatch.setattr(render.subprocess, "run", no_ffmpeg)
    try:
        assert render.nvenc_available() is False and render.nvenc_available() is False
        assert len(calls) == 1
    finally:
        render.nvenc_available.cache_clear()


# ---------------------------------------------------------------------------
# result
# ---------------------------------------------------------------------------


def _meta(fps: float = 15.0) -> VideoMeta:
    return VideoMeta(path="g.mp4", filename="g.mp4", fps=fps, width=1280, height=720, frame_count=20, duration_s=1.333, analysis_fps=15.0, step=1, codec="h264")


def test_tracking_result_from_the_fixture_validates():
    adapted = adapter.adapt_ohv(FIXTURE, _meta(), FrameMap.identity(15.0))
    adapted.perception.warn("BALL_TRACKING_SPARSE", "sparse")
    data = result.build_tracking_result(
        adapted.perception, adapted.events, job_id="j_1",
        pipeline_info={"name": "openhoopvision", "version": "ec969037b2c0", "gpu": "NVIDIA A10G", "elapsed_s": 12.345,
                       "options": {"analysis_size": (1280, 720), "nan": float("nan")}},
        artifacts={"annotated_video": "results/j_1/annotated.mp4"},
    )  # fmt: skip
    parsed = TrackingResult.model_validate(json.loads(json.dumps(data, allow_nan=False)))
    assert parsed.job_id == "j_1" and parsed.pipeline.name == "openhoopvision" and parsed.pipeline.elapsed_s == 12.3
    assert parsed.pipeline.options == {"analysis_size": [1280, 720], "nan": None}
    assert {t.role for t in parsed.tracks} == {"player", "referee"}
    assert [t.color_name for t in parsed.teams] == ["dark", "light"]
    track = next(t for t in parsed.tracks if t.track_id == 5)
    assert track.team_id == 0 and track.jersey_reads[0].text == "5" and track.samples[0].court_xy == (32.81, 33.6)
    assert len(parsed.ball) == 20 and parsed.ball[0].holder_track_id == 1
    assert [e.type for e in parsed.events][:3] == ["pass", "shot", "rebound"]
    assert parsed.rims[0].side == "right" and parsed.artifacts["annotated_video"].endswith("annotated.mp4")
    assert parsed.warnings[0].code == "BALL_TRACKING_SPARSE"
    assert parsed.video.analysis_fps == 15.0 and parsed.court.length_ft == 84.0


def test_sample_stride_thins_samples_but_keeps_the_last(monkeypatch):
    adapted = adapter.adapt_ohv(FIXTURE, _meta(), FrameMap.identity(15.0))
    data = result.build_tracking_result(adapted.perception, [], job_id=None, pipeline_info={"name": "x"}, sample_stride=3)
    frames = next(t for t in data["tracks"] if t["track_id"] == 1)["samples"]
    assert [s["f"] for s in frames] == [0, 3, 6, 9, 12, 15, 18, 19]
    assert result.choose_sample_stride(adapted.perception, max_samples=1_000_000) == 1
    assert result.choose_sample_stride(adapted.perception, max_samples=50) == 3  # 106 samples


def test_events_are_sanitised():
    perception = adapter.adapt_ohv(FIXTURE, _meta(), FrameMap.identity(15.0)).perception
    events = [
        {"event_id": "a", "type": "shot", "frame": 9, "t": 0.6, "track_id": 1, "team_id": 0, "conf": 1.7, "attrs": {"shot_court_xy": (1.234567, 2.0)}},
        {"event_id": "b", "type": "dribble", "frame": 3, "t": 0.2, "attrs": {}},
        {"event_id": "c", "type": "foul", "frame": "x"},
        {"event_id": "d", "type": "free_throw", "frame": 2, "t": 0.13, "conf": None, "attrs": {"made": True}},
    ]
    data = result.build_tracking_result(perception, events, job_id=None, pipeline_info={"name": "x"})
    assert [(e["event_id"], e["conf"]) for e in data["events"]] == [("d", 0.5), ("a", 1.0)]
    assert data["events"][1]["attrs"]["shot_court_xy"] == [1.2346, 2.0]
    TrackingResult.model_validate(data)


def test_write_tracking_result_is_gzipped_json(tmp_path):
    path = tmp_path / "out" / "tracking.json.gz"
    size = result.write_tracking_result({"a": [1, 2.5]}, path)
    assert size == path.stat().st_size and json.loads(gzip.decompress(path.read_bytes())) == {"a": [1, 2.5]}
    assert not (tmp_path / "out" / "tracking.json.gz.tmp").exists()


def test_track_sample_values_are_rounded():
    perception = adapter.adapt_ohv(FIXTURE, _meta(), FrameMap.identity(15.0)).perception
    perception.tracks[99] = TrackData(track_id=99, obs=[TrackObs(frame=1, bbox=(1.23456, 2.0, 3.98765, 4.0), conf=0.987654, court_xy=(1.005, 2.555))])
    data = result.build_tracking_result(perception, [], job_id=None, pipeline_info={"name": "x"})
    sample = next(t for t in data["tracks"] if t["track_id"] == 99)["samples"][0]
    assert sample["bbox"] == [1.23, 2.0, 3.99, 4.0] and sample["conf"] == 0.988 and sample["court_xy"] == [1.0, 2.56]


# ---------------------------------------------------------------------------
# runner: progress mapping
# ---------------------------------------------------------------------------


def test_pipeline_progress_maps_stages_onto_weighted_slots():
    seen: list[tuple[str, float, str]] = []
    progress = runner.PipelineProgress(lambda stage, pct, message: seen.append((stage, pct, message)), min_interval_s=0)
    assert progress.update("download", 1.0, "ok") == pytest.approx(4.0)  # 3 of the 75 weighted units
    assert progress.update("ohv", 0.5, "half") == pytest.approx(100 * (3 + 1 + 50 * 0.55) / 75)
    assert progress.update("transcode", 1.0, "late") == pytest.approx(42.0)  # never goes backwards
    progress.done("finished")
    assert [s for s, _, _ in seen] == ["download", "ohv", "transcode", "done"] and seen[-1][1] == 100.0


# ---------------------------------------------------------------------------
# runner: end to end with OHV, ffmpeg and the supplementary detectors faked
# ---------------------------------------------------------------------------


class _Stack:
    def __init__(self) -> None:
        self.ohv_kwargs: dict[str, Any] = {}
        self.jsonl: Path = FIXTURE
        self.ohv_error: Exception | None = None
        self.render_error: Exception | None = None
        self.transcoded = False


def _records(players: int, ball_every: int | None, frames: int = 30) -> str:
    lines = []
    for n in range(1, frames + 1):
        rec: dict[str, Any] = {
            "frame": n,
            "players": [{"id": i + 1, "local_track_id": i + 1, "box": [100 * i, 300, 100 * i + 50, 480], "team": i % 2} for i in range(players)],
            "events": [],
        }
        if ball_every and n % ball_every == 0:
            rec["ball"] = {"center": [640, 300], "score": 0.8, "observed": True, "interpolated": False}
        lines.append(json.dumps(rec))
    return "\n".join(lines) + "\n"


@pytest.fixture
def stack(monkeypatch, tmp_path):
    state = _Stack()
    probe = _probe()  # 1920x1080 @ 30 fps -> analysed at 15 fps, 1280x720

    monkeypatch.setattr(video, "probe_video", lambda path: probe)
    monkeypatch.setattr(video, "check_decodable", lambda path: None)

    def fake_transcode(src, dst, plan, *, progress=None):
        state.transcoded = True
        Path(dst).write_bytes(b"analysis copy")
        progress(1.0, "done")
        return Path(dst)

    def fake_run_ohv(video_path, work_dir, **kwargs):
        state.ohv_kwargs = kwargs
        if state.ohv_error:
            raise state.ohv_error
        work = Path(work_dir)
        work.mkdir(parents=True, exist_ok=True)
        tracks = work / "ohv_tracks.jsonl"
        shutil.copyfile(state.jsonl, tracks)
        output = work / "ohv_annotated.mp4" if kwargs["render"] else None
        if output:
            output.write_bytes(b"raw overlay")
        kwargs["progress"](0.5, "half way")
        return ohv.OhvRun(
            tracks_path=tracks, events_path=work / "ohv_events.json", output_video=output, params=ohv.OhvParams(),
            attempts=1, summary=ohv.OhvSummary(team_colors_bgr=[(60, 20, 10), (240, 240, 245)]),
            warnings=[{"code": "OCR_UNAVAILABLE", "message": "no ocr", "severity": "warning"}], log_tail=["ohv says hi"],
        )  # fmt: skip

    def fake_render(src, dst, **kwargs):
        if state.render_error:
            raise state.render_error
        Path(dst).write_bytes(b"web overlay")
        return render.X264

    def fake_enrich(perception, existing_events, cfg=None):
        return [dict(e, attrs={**e["attrs"], "enriched": True}) for e in existing_events]

    def fake_detect(perception, cfg=None, existing_events=None):
        fallback = next(e for e in existing_events if e["attrs"].get("points_source") == "two_point_fallback")
        return [{"event_id": "ft-1", "type": "free_throw", "frame": fallback["frame"], "t": fallback["t"], "track_id": 5,
                 "team_id": 0, "conf": 0.6, "attrs": {"made": True, "replaces_event_id": fallback["event_id"]}}]  # fmt: skip

    monkeypatch.setattr(video, "transcode_for_analysis", fake_transcode)
    monkeypatch.setattr(ohv, "run_ohv", fake_run_ohv)
    monkeypatch.setattr(ohv, "gpu_name", lambda: "NVIDIA A10G")
    monkeypatch.setattr(render, "render_web_video", fake_render)
    monkeypatch.setattr(extra_events, "enrich_events", fake_enrich)
    monkeypatch.setattr(extra_events, "detect_events", fake_detect)
    monkeypatch.setattr(possession, "assign_ball_holders", lambda perception, cfg=None: None)
    return state


def _run(tmp_path, options: dict[str, Any] | None = None, progress=None) -> dict[str, Any]:
    film = tmp_path / "film.mp4"
    film.write_bytes(b"film")
    opts = {"analysis_fps": 15, "work_dir": str(tmp_path / "scratch"), **(options or {})}
    (tmp_path / "scratch").mkdir(exist_ok=True)
    return runner.run_pipeline(str(film), opts, output_dir=str(tmp_path / "results" / "j_1"), job_id="j_1", progress=progress, filename="vs-central.mp4")


def test_runner_end_to_end(stack, tmp_path):
    seen: list[tuple[str, float, str]] = []
    response = _run(tmp_path, progress=lambda s, p, m: seen.append((s, p, m)))
    assert response["status"] == "ok", response
    out = tmp_path / "results" / "j_1"
    assert response["tracking_path"] == str(out / runner.TRACKING_FILE)  # not under /data -> absolute
    assert response["annotated_video_path"] == str(out / runner.ANNOTATED_FILE)
    assert response["summary"]["tracks"] == 5 and response["summary"]["events"] == 7
    assert {w["code"] for w in response["warnings"]} >= {"OCR_UNAVAILABLE", "TRACKING_DATA_TRUNCATED"}
    assert (out / runner.OHV_LOG_FILE).read_text() == "ohv says hi\n"
    assert not list((tmp_path / "scratch").iterdir())  # OHV's scratch directory is removed

    tracking = TrackingResult.model_validate(json.loads(gzip.decompress((out / runner.TRACKING_FILE).read_bytes())))
    assert tracking.video.filename == "vs-central.mp4" and tracking.video.fps == 30.0 and tracking.video.width == 1920
    assert tracking.video.analysis_fps == 15.0
    assert tracking.pipeline.name == "openhoopvision" and tracking.pipeline.gpu == "NVIDIA A10G"
    assert tracking.pipeline.options["pre_transcoded"] is True and tracking.artifacts == {"annotated_video": str(out / runner.ANNOTATED_FILE)}
    # Frames and pixels are mapped back to the 30 fps 1080p original.
    track = next(t for t in tracking.tracks if t.track_id == 1)
    assert [s.f for s in track.samples][:3] == [0, 2, 4] and track.samples[0].bbox == (450.0, 450.0, 540.0, 720.0)
    # Supplementary events merged: the free throw replaced OHV's fallback "shot", ids renumbered.
    types = [e.type for e in tracking.events]
    assert types.count("shot") == 2 and types.count("free_throw") == 1
    assert [e.event_id for e in tracking.events] == [f"e{n:05d}" for n in range(1, 8)]
    assert all(e.attrs.get("enriched") for e in tracking.events if e.type != "free_throw")
    assert [e.frame for e in tracking.events] == sorted(e.frame for e in tracking.events)

    stages = [s for s, _, _ in seen]
    assert stages[0] == "download" and stages[-1] == "done" and {"probe", "transcode", "ohv", "events", "render", "write"} <= set(stages)
    pcts = [p for _, p, _ in seen]
    assert pcts == sorted(pcts) and pcts[-1] == 100.0
    assert stack.transcoded and stack.ohv_kwargs["analysis_fps"] == pytest.approx(15.0) and stack.ohv_kwargs["render"] is True
    assert stack.ohv_kwargs["court"] == ohv.CourtSpec(length_ft=84.0, width_ft=50.0)


def test_runner_survives_unfinished_supplementary_detectors(stack, tmp_path, monkeypatch):
    def not_ready(*args, **kwargs):
        raise NotImplementedError

    monkeypatch.setattr(extra_events, "enrich_events", not_ready)
    monkeypatch.setattr(extra_events, "detect_events", not_ready)
    response = _run(tmp_path)
    assert response["status"] == "ok"
    assert {"EVENT_ENRICHMENT_FAILED", "EXTRA_EVENTS_FAILED"} <= {w["code"] for w in response["warnings"]}
    assert response["summary"]["events"] == 7  # OHV's own events are kept


def test_runner_without_render(stack, tmp_path):
    response = _run(tmp_path, {"render_video": False, "court_length_ft": 74})
    assert response["status"] == "ok" and response["annotated_video_path"] is None
    assert stack.ohv_kwargs["render"] is False and stack.ohv_kwargs["court"].length_ft == 74


def test_runner_render_failure_only_warns(stack, tmp_path):
    stack.render_error = PipelineError(errors.PIPELINE_FAILED, "encode failed")
    response = _run(tmp_path)
    assert response["status"] == "ok" and response["annotated_video_path"] is None
    assert "ANNOTATED_VIDEO_FAILED" in {w["code"] for w in response["warnings"]}


def test_runner_returns_gpu_oom(stack, tmp_path):
    stack.ohv_error = PipelineError(errors.GPU_OOM, "Out of GPU memory even at detector batch size 1 and 640px.", "trace")
    response = _run(tmp_path)
    assert response["status"] == "error" and response["error"]["code"] == errors.GPU_OOM
    assert response["error"]["detail"] == "trace" and response["job_id"] == "j_1"
    assert not list((tmp_path / "scratch").iterdir())


def test_runner_returns_decode_failure(stack, tmp_path, monkeypatch):
    def corrupt(path):
        raise PipelineError(errors.VIDEO_DECODE_FAILED, "The video could not be decoded.")

    monkeypatch.setattr(video, "check_decodable", corrupt)
    response = _run(tmp_path)
    assert response["error"]["code"] == errors.VIDEO_DECODE_FAILED


def test_runner_detection_failure_for_close_up_film(stack, tmp_path):
    stack.jsonl = tmp_path / "closeup.jsonl"
    stack.jsonl.write_text(_records(players=2, ball_every=1))
    response = _run(tmp_path)
    assert response["error"]["code"] == errors.DETECTION_FAILED and "Only 2 players" in response["error"]["message"]


def test_runner_ball_checks(stack, tmp_path):
    stack.jsonl = tmp_path / "noball.jsonl"
    stack.jsonl.write_text(_records(players=6, ball_every=None))
    assert _run(tmp_path)["error"]["code"] == errors.BALL_NOT_DETECTED
    stack.jsonl.write_text(_records(players=6, ball_every=5))  # ball in 20% of frames
    response = _run(tmp_path)
    assert response["status"] == "ok"
    codes = {w["code"] for w in response["warnings"]}
    assert "BALL_TRACKING_SPARSE" in codes and "NO_COURT_HOMOGRAPHY" in codes


def test_runner_unexpected_errors_become_pipeline_failed(stack, tmp_path, monkeypatch):
    def boom(*args, **kwargs):
        raise RuntimeError("boom in the adapter")

    monkeypatch.setattr(adapter, "adapt_ohv", boom)
    response = _run(tmp_path)
    assert response["error"]["code"] == errors.PIPELINE_FAILED
    assert "boom in the adapter" in response["error"]["message"] and "Traceback" in response["error"]["detail"]

    def oom(*args, **kwargs):
        raise RuntimeError("CUDA error: out of memory")

    monkeypatch.setattr(adapter, "adapt_ohv", oom)
    assert _run(tmp_path)["error"]["code"] == errors.GPU_OOM


def test_runner_rejects_invalid_options(stack, tmp_path):
    response = _run(tmp_path, {"analysis_fps": "fast"})
    assert response["error"]["code"] == errors.PIPELINE_FAILED and "analysis_fps" in response["error"]["message"]
    response = _run(tmp_path, {"court_length_ft": 300})
    assert "court_length_ft" in response["error"]["message"]


def test_runner_passes_custom_weights_and_max_frames(stack, tmp_path):
    response = _run(tmp_path, {"detector_weights": "/models/custom.pth", "max_frames": 300})
    assert response["status"] == "ok"
    assert stack.ohv_kwargs["weight_overrides"] == {"rf-detr-basketball.pth": "/models/custom.pth"}
    assert stack.ohv_kwargs["max_frames"] == 300


def test_volume_paths_are_relative_to_the_volume_root():
    assert runner.volume_path("/data/results/j_1/tracking.json.gz") == "results/j_1/tracking.json.gz"
    assert runner.volume_path("/tmp/results/x.gz") == "/tmp/results/x.gz"
    assert runner.volume_path("/database/x") == "/database/x"


def test_merge_events_accepts_numpy_frames_and_drops_malformed_events(monkeypatch):
    import numpy as np

    perception = adapter.adapt_ohv(FIXTURE, _meta(), FrameMap.identity(15.0)).perception
    ohv_events = [{"event_id": "ohv-1", "type": "shot", "frame": 9, "t": 0.6, "attrs": {"made": False}}]
    monkeypatch.setattr(extra_events, "enrich_events", lambda p, events, cfg=None: [*events, {"type": "pass"}])
    monkeypatch.setattr(
        extra_events,
        "detect_events",
        lambda p, cfg=None, existing_events=None: [
            {"event_id": "ft", "type": "free_throw", "frame": np.int64(3), "t": 0.2, "attrs": {"made": True}},
            {"event_id": "bad", "type": "foul", "frame": "soon"},
        ],
    )
    merged = runner.merge_events(perception, ohv_events)
    assert [(e["event_id"], e["type"], e["frame"]) for e in merged] == [("e00001", "free_throw", 3), ("e00002", "shot", 9)]
    assert type(merged[0]["frame"]) is int


def test_runner_detection_failure_when_no_player_keeps_an_identity(stack, tmp_path):
    lines = [json.dumps({"frame": n, "players": [{"id": None, "local_track_id": i, "box": [100 * i, 300, 100 * i + 50, 480]} for i in range(6)],
                         "ball": {"center": [640, 300], "observed": True}}) for n in range(1, 11)]  # fmt: skip
    stack.jsonl = tmp_path / "anonymous.jsonl"
    stack.jsonl.write_text("\n".join(lines) + "\n")
    response = _run(tmp_path)
    assert response["error"]["code"] == errors.DETECTION_FAILED and "followed" in response["error"]["message"]
