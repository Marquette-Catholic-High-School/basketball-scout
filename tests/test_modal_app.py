"""modal_app/app.py: imports with only ``modal`` installed, GPU/timeout settings, image
recipe, request handling (volume / URL sources) with fake Volume and Dict objects."""

from __future__ import annotations

import importlib
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import modal
import pytest

import modal_app.app as app_module
from modal_app.pipeline import errors, ohv
from modal_app.pipeline.errors import PipelineError

REPO = Path(__file__).resolve().parent.parent


@pytest.fixture
def reload_app(monkeypatch):
    """Reload modal_app.app under the test environment (conftest removes every SCOUT_* variable)
    plus ``env``; afterwards reload it again with the defaults."""
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


def test_module_exposes_the_modal_objects():
    assert isinstance(app_module.app, modal.App)
    assert isinstance(app_module.process_video, modal.Function)
    assert isinstance(app_module.warmup, modal.Function)
    assert isinstance(app_module.main, modal.app.LocalEntrypoint)
    assert isinstance(app_module.image, modal.Image)


def test_app_imports_where_only_modal_is_installed():
    """The server and `modal deploy` import this module; no GPU stack (or scout) may be needed."""
    code = (
        "import sys\n"
        "for name in ('numpy', 'torch', 'cv2', 'rfdetr', 'scout'):\n"
        "    sys.modules[name] = None  # importing them now fails\n"
        "import modal_app.app\n"
    )
    proc = subprocess.run([sys.executable, "-c", code], cwd=REPO, capture_output=True, text=True, env=dict(os.environ))
    assert proc.returncode == 0, proc.stderr


def test_default_gpu_timeout_and_resources(reload_app):
    module = reload_app()  # defaults, whatever the developer's shell exports
    assert module.GPU_TYPE == "A10G"
    assert module.PROCESS_TIMEOUT_S == 21600  # 6 h budget for a 60-minute game
    assert module.MAX_TIMEOUT_S == 86400
    assert (module.CPU_CORES, module.MEMORY_MB, module.MAX_CONTAINERS) == (8.0, 32768, 2)
    spec = getattr(module.process_video, "_spec_", None)  # private in modal 1.6; best effort
    if spec is not None:
        assert spec.gpus == "A10G" and spec.cpu == 8.0 and spec.memory == 32768
        assert list(spec.volumes) == ["/data"]


def test_gpu_and_timeout_can_be_overridden_at_deploy_time(reload_app):
    module = reload_app(SCOUT_MODAL_GPU="L40S", SCOUT_MODAL_TIMEOUT_S="999999", SCOUT_MODAL_MAX_CONTAINERS="5")
    assert module.GPU_TYPE == "L40S" and module.PROCESS_TIMEOUT_S == 86400 and module.MAX_CONTAINERS == 5
    module = reload_app(SCOUT_MODAL_TIMEOUT_S="60")
    assert module.PROCESS_TIMEOUT_S == 600
    module = reload_app(SCOUT_MODAL_TIMEOUT_S="soon")
    assert module.PROCESS_TIMEOUT_S == module.DEFAULT_TIMEOUT_S


def test_image_recipe_downloads_and_verifies_every_weight():
    commands = ohv.weight_download_commands("/opt/openhoopvision/weights")
    for weight in ohv.WEIGHTS:
        command = next(c for c in commands if weight.name in c)
        assert weight.sha256 in command and "sha256sum -c" in command
        assert f"/OpenHoopVision/{ohv.OHV_COMMIT}/weights/{weight.name}" in command
    assert len(ohv.OHV_COMMIT) == 40
    assert isinstance(app_module.build_image(), modal.Image)  # add_local_python_source stays last


def test_gpu_requirements_file_matches_the_image_pins():
    lines = [line.strip() for line in (REPO / "modal_app" / "requirements-gpu.txt").read_text().splitlines()]
    pins = [line for line in lines if line and not line.startswith(("#", "--"))]
    assert pins == [*ohv.TORCH_REQUIREMENTS, *ohv.OHV_REQUIREMENTS]
    assert f"--extra-index-url {ohv.TORCH_INDEX_URL}" in lines


# ---------------------------------------------------------------------------
# Request parsing
# ---------------------------------------------------------------------------


def _request(**overrides: Any) -> dict[str, Any]:
    request = {
        "job_id": "j_abc123",
        "video": {"type": "volume", "path": "uploads/j_abc123/source.mp4", "filename": "vs-central.mp4"},
        "output_dir": "results/j_abc123",
        "options": {"analysis_fps": 15},
    }
    request.update(overrides)
    return request


def test_parse_volume_and_url_requests():
    parsed = app_module.parse_request(_request())
    assert (parsed.job_id, parsed.volume_path, parsed.url, parsed.filename) == ("j_abc123", "uploads/j_abc123/source.mp4", None, "vs-central.mp4")
    url = app_module.parse_request(_request(video={"type": "url", "url": "https://cdn.example.org/films/game7.mp4?sig=1"}, output_dir=None))
    assert (url.url, url.filename, url.output_dir) == ("https://cdn.example.org/films/game7.mp4?sig=1", "game7.mp4", "results/j_abc123")
    page = app_module.parse_request(_request(video={"type": "url", "url": "https://hudl.example/watch?v=12"}))
    assert page.filename == "film.mp4"


@pytest.mark.parametrize(
    "request_",
    [
        "not a dict",
        _request(job_id="../escape"),
        _request(job_id=""),
        _request(video=None),
        _request(video={"type": "volume"}),
        _request(video={"type": "s3", "path": "x"}),
        _request(video={"type": "url", "url": ""}),
        _request(options=["fps"]),
    ],
)
def test_parse_request_rejects_bad_requests(request_):
    with pytest.raises(PipelineError) as info:
        app_module.parse_request(request_)
    assert info.value.code == errors.PIPELINE_FAILED and "Invalid processing request" in info.value.message


def test_resolve_volume_path(tmp_path):
    film = tmp_path / "uploads" / "j" / "a.mp4"
    film.parent.mkdir(parents=True)
    film.write_bytes(b"x")
    assert app_module.resolve_volume_path(tmp_path, "uploads/j/a.mp4", must_exist=True) == film
    assert app_module.resolve_volume_path(tmp_path, "/results/j") == tmp_path / "results" / "j"
    with pytest.raises(PipelineError):
        app_module.resolve_volume_path(tmp_path, "uploads/../../etc/passwd")
    with pytest.raises(PipelineError) as missing:
        app_module.resolve_volume_path(tmp_path, "uploads/j/b.mp4", must_exist=True)
    assert missing.value.code == errors.VIDEO_INVALID


# ---------------------------------------------------------------------------
# handle_request (the body of process_video)
# ---------------------------------------------------------------------------


class FakeVolume:
    def __init__(self, fail_commit: bool = False) -> None:
        self.calls: list[str] = []
        self.fail_commit = fail_commit

    def reload(self) -> None:
        self.calls.append("reload")

    def commit(self) -> None:
        self.calls.append("commit")
        if self.fail_commit:
            raise RuntimeError("volume busy")


@pytest.fixture
def volume_root(tmp_path):
    root = tmp_path / "volume"
    film = root / "uploads" / "j_abc123" / "source.mp4"
    film.parent.mkdir(parents=True)
    film.write_bytes(b"film")
    return root


@pytest.fixture
def pipeline_calls(monkeypatch):
    calls: list[dict[str, Any]] = []

    def fake_run_pipeline(video_path, options, *, output_dir, job_id, progress=None, filename=None):
        calls.append({"video_path": video_path, "options": options, "output_dir": output_dir, "job_id": job_id, "filename": filename})
        progress("ohv", 50.0, "half way")
        return {"status": "ok", "job_id": job_id, "tracking_path": "results/j_abc123/tracking.json.gz", "warnings": []}

    monkeypatch.setattr(app_module, "run_pipeline", fake_run_pipeline)
    return calls


def test_handle_volume_request(volume_root, pipeline_calls):
    volume, store = FakeVolume(), {}
    response = app_module.handle_request(_request(), volume=volume, progress_store=store, root=volume_root)
    assert response["status"] == "ok"
    assert volume.calls == ["reload", "commit"]  # see the fresh upload, persist the results
    call = pipeline_calls[0]
    assert call["video_path"] == str(volume_root / "uploads" / "j_abc123" / "source.mp4")
    assert call["output_dir"] == str(volume_root / "results" / "j_abc123")
    assert (call["job_id"], call["filename"], call["options"]) == ("j_abc123", "vs-central.mp4", {"analysis_fps": 15})
    assert store["j_abc123"]["stage"] == "ohv" and store["j_abc123"]["pct"] == 50.0 and "updated_at" in store["j_abc123"]


def test_handle_url_request_downloads_into_tmp_and_cleans_up(volume_root, pipeline_calls, monkeypatch):
    downloads: list[Path] = []

    def fake_download(url, dest, *, max_bytes, progress=None):
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"downloaded film")
        progress(1.0, "Downloading film")
        downloads.append(dest)
        return dest

    monkeypatch.setattr(app_module, "download_video", fake_download)
    request = _request(video={"type": "url", "url": "https://cdn.example.org/a b.mp4", "filename": "a b.mp4"})
    response = app_module.handle_request(request, volume=FakeVolume(), progress_store={}, root=volume_root)
    assert response["status"] == "ok"
    assert downloads == [volume_root / "tmp" / "j_abc123" / "a_b.mp4"]
    assert pipeline_calls[0]["video_path"] == str(downloads[0])
    assert not (volume_root / "tmp" / "j_abc123").exists()  # the temporary copy is removed


def test_handle_request_returns_expected_failures(volume_root, monkeypatch):
    def failing_download(url, dest, *, max_bytes, progress=None):
        raise PipelineError(errors.VIDEO_DOWNLOAD_FAILED, "The video link returned HTTP 404.")

    monkeypatch.setattr(app_module, "download_video", failing_download)
    volume, store = FakeVolume(), {}
    request = _request(video={"type": "url", "url": "https://cdn.example.org/missing.mp4"})
    response = app_module.handle_request(request, volume=volume, progress_store=store, root=volume_root)
    assert response == {
        "status": "error",
        "job_id": "j_abc123",
        "error": {"code": errors.VIDEO_DOWNLOAD_FAILED, "message": "The video link returned HTTP 404.", "detail": None},
        "warnings": [],
    }
    assert volume.calls == ["reload", "commit"]
    assert store["j_abc123"]["stage"] == "error" and "HTTP 404" in store["j_abc123"]["message"]


def test_handle_request_missing_upload(volume_root, pipeline_calls):
    request = _request(video={"type": "volume", "path": "uploads/j_abc123/other.mp4"})
    response = app_module.handle_request(request, volume=FakeVolume(), progress_store={}, root=volume_root)
    assert response["error"]["code"] == errors.VIDEO_INVALID and not pipeline_calls


def test_handle_request_never_raises_for_unexpected_errors(volume_root, monkeypatch):
    def broken(*args, **kwargs):
        raise RuntimeError("disk on fire")

    monkeypatch.setattr(app_module, "run_pipeline", broken)
    response = app_module.handle_request(_request(), volume=FakeVolume(), progress_store={}, root=volume_root)
    assert response["error"]["code"] == errors.PIPELINE_FAILED and "disk on fire" in response["error"]["message"]
    bad = app_module.handle_request(None, volume=FakeVolume(), progress_store={}, root=volume_root)
    assert bad["status"] == "error" and bad["job_id"] == "unknown"


def test_handle_request_reports_a_failed_volume_commit(volume_root, pipeline_calls):
    response = app_module.handle_request(_request(), volume=FakeVolume(fail_commit=True), progress_store={}, root=volume_root)
    assert response["error"]["code"] == errors.PIPELINE_FAILED and "volume" in response["error"]["message"]


def test_handle_request_lets_cancellation_through(volume_root, monkeypatch):
    class Cancelled(BaseException):  # like modal.exception.InputCancellation
        pass

    def cancelled(*args, **kwargs):
        raise Cancelled

    monkeypatch.setattr(app_module, "run_pipeline", cancelled)
    with pytest.raises(Cancelled):
        app_module.handle_request(_request(), volume=FakeVolume(), progress_store={}, root=volume_root)


def test_progress_store_errors_never_break_processing(volume_root, monkeypatch):
    class BrokenStore(dict):
        def __setitem__(self, key, value):
            raise ConnectionError("dict unavailable")

    failed = {"status": "error", "job_id": "j_abc123", "error": {"code": errors.GPU_OOM, "message": "oom", "detail": None}, "warnings": []}
    monkeypatch.setattr(app_module, "run_pipeline", lambda *args, **kwargs: failed)
    response = app_module.handle_request(_request(), volume=FakeVolume(), progress_store=BrokenStore(), root=volume_root)
    assert response == failed  # the final "error" progress entry could not be written; that is fine
