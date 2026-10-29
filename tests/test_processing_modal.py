"""ModalProcessor against a fake ``modal`` module: no network, no credentials, no GPU."""

from __future__ import annotations

import subprocess
import sys
import time
import types
from pathlib import Path
from typing import Any

import pytest

from scout.errors import ErrorCode, ScoutError
from scout.processing import get_processor, modal_client
from scout.processing.base import VideoSource
from scout.processing.base import poll_result_from_response
from scout.processing.modal_client import ModalProcessor, parse_handle

# --- a fake modal SDK ------------------------------------------------------------


ERROR_SUBCLASSES = (
    "NotFoundError",
    "AuthError",
    "PermissionDeniedError",
    "ConnectionError",
    "ServiceError",
    "RemoteError",
    "ExecutionError",
)


def _exception_module() -> types.ModuleType:
    """Mirrors the parts of modal.exception (1.6.3) the processor relies on."""
    module = types.ModuleType("modal.exception")

    class Error(Exception):
        pass

    class TimeoutError(Error):  # noqa: A001 - like modal's: NOT the builtin TimeoutError
        pass

    classes: dict[str, type[BaseException]] = {"Error": Error, "TimeoutError": TimeoutError}
    for name in ERROR_SUBCLASSES:
        classes[name] = type(name, (Error,), {})
    for name in ("FunctionTimeoutError", "OutputExpiredError", "VolumeUploadTimeoutError"):
        classes[name] = type(name, (TimeoutError,), {})
    classes["InputCancellation"] = type("InputCancellation", (BaseException,), {})
    for name, cls in classes.items():
        setattr(module, name, cls)
    return module


EXC = _exception_module()


class FakeVolume:
    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}
        self.upload_error: BaseException | None = None
        self.read_failures = 0  # transient download failures before reads succeed
        self.force_flags: list[bool] = []

    def batch_upload(self, force: bool = False) -> FakeBatch:
        self.force_flags.append(force)
        return FakeBatch(self)

    def read_file_into_fileobj(self, path: str, fileobj: Any) -> int:
        if self.read_failures:
            self.read_failures -= 1
            raise RuntimeError("connection reset by peer")
        data = self.files.get(path.lstrip("/"))
        if data is None:
            raise FileNotFoundError(path)
        fileobj.write(data)
        return len(data)

    def remove_file(self, path: str, recursive: bool = False) -> None:
        prefix = path.strip("/")
        matches = [p for p in self.files if p == prefix or (recursive and p.startswith(prefix + "/"))]
        if not matches:
            raise FileNotFoundError(path)
        for name in matches:
            del self.files[name]


class FakeBatch:
    def __init__(self, volume: FakeVolume) -> None:
        self.volume = volume
        self.pending: dict[str, bytes] = {}

    def __enter__(self) -> FakeBatch:
        return self

    def __exit__(self, *exc_info: Any) -> None:
        if exc_info[0] is None and self.volume.upload_error is not None:
            raise self.volume.upload_error
        self.volume.files.update(self.pending)

    def put_file(self, local_file: str, remote_path: str) -> None:
        assert remote_path.startswith("/"), "batch.put_file paths are absolute inside the volume"
        self.pending[remote_path.lstrip("/")] = Path(local_file).read_bytes()


class FakeProgressDict:
    def __init__(self) -> None:
        self.data: dict[str, Any] = {}
        self.error: BaseException | None = None

    def get(self, key: str, default: Any = None) -> Any:
        if self.error is not None:
            raise self.error
        return self.data.get(key, default)

    def pop(self, key: str, default: Any = None) -> Any:
        return self.data.pop(key, default)


class FakeModal:
    """State behind the fake module: what was looked up, spawned, cancelled..."""

    def __init__(self) -> None:
        self.volume = FakeVolume()
        self.progress = FakeProgressDict()
        self.lookups: list[tuple[str, str, str | None]] = []
        self.lookup_error: BaseException | None = None
        self.spawn_error: BaseException | None = None
        self.spawned: list[dict] = []
        self.outcome: Any = TimeoutError()  # what FunctionCall.get() raises / returns; builtin = still running
        self.cancelled: list[str] = []
        self.cancel_error: BaseException | None = None

    def module(self) -> types.ModuleType:
        state = self

        class Function:
            def __init__(self, app: str, name: str, environment_name: str | None) -> None:
                state.lookups.append((app, name, environment_name))

            @classmethod
            def from_name(cls, app: str, name: str, *, environment_name: str | None = None) -> Function:
                return cls(app, name, environment_name)

            def hydrate(self) -> Function:
                if state.lookup_error is not None:
                    raise state.lookup_error
                return self

            def spawn(self, request: dict) -> Any:
                if state.spawn_error is not None:
                    raise state.spawn_error
                state.spawned.append(request)
                return types.SimpleNamespace(object_id="fc-01ABC")

        class FunctionCall:
            def __init__(self, call_id: str) -> None:
                self.call_id = call_id

            @classmethod
            def from_id(cls, call_id: str) -> FunctionCall:
                return cls(call_id)

            def get(self, timeout: float | None = None) -> Any:
                assert timeout == 0, "poll must never block"
                if isinstance(state.outcome, BaseException):
                    raise state.outcome
                return state.outcome

            def cancel(self) -> None:
                if state.cancel_error is not None:
                    raise state.cancel_error
                state.cancelled.append(self.call_id)

        module = types.ModuleType("modal")
        module.exception = EXC
        module.Function = Function
        module.FunctionCall = FunctionCall
        module.Volume = types.SimpleNamespace(from_name=lambda name, **kw: state.volume)
        module.Dict = types.SimpleNamespace(from_name=lambda name, **kw: state.progress)
        return module


@pytest.fixture
def fake_modal(monkeypatch) -> FakeModal:
    state = FakeModal()
    module = state.module()
    monkeypatch.setitem(sys.modules, "modal", module)
    monkeypatch.setitem(sys.modules, "modal.exception", module.exception)
    monkeypatch.setenv("MODAL_TOKEN_ID", "ak-test-only")  # settings.modal_configured
    monkeypatch.setenv("MODAL_TOKEN_SECRET", "as-test-only")
    return state


@pytest.fixture
def processor(settings) -> ModalProcessor:
    proc = get_processor(settings, name="modal")
    assert isinstance(proc, ModalProcessor)
    proc.download_retry_delay_s = 0.0
    return proc


@pytest.fixture
def film(tmp_path) -> VideoSource:
    path = tmp_path / "source.mp4"
    path.write_bytes(b"film bytes")
    return VideoSource(kind="file", filename="vs Central (Senior Night).mp4", path=path)


HANDLE = "fc-01ABC|j_1"

# --- readiness & submit -------------------------------------------------------------


def test_importing_the_client_does_not_import_modal():
    code = "import sys, scout.processing.modal_client; print('modal' in sys.modules)"
    repo = Path(__file__).parent.parent
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True, cwd=repo)
    assert out.stdout.strip() == "False"


def test_check_ready_requires_credentials(fake_modal, processor, monkeypatch):
    monkeypatch.delenv("MODAL_TOKEN_ID")
    with pytest.raises(ScoutError) as exc:
        processor.check_ready()
    assert exc.value.code == ErrorCode.MODAL_NOT_CONFIGURED
    assert fake_modal.lookups == []


@pytest.mark.parametrize(
    ("error", "code"),
    [
        (EXC.NotFoundError("App 'basketball-scout' not found"), ErrorCode.MODAL_APP_NOT_DEPLOYED),
        (EXC.AuthError("token rejected"), ErrorCode.MODAL_AUTH_FAILED),
        (EXC.PermissionDeniedError("no access to environment"), ErrorCode.MODAL_AUTH_FAILED),
        (OSError("network unreachable"), ErrorCode.MODAL_REMOTE_ERROR),
    ],
)
def test_check_ready_hydrates_the_function(fake_modal, processor, error, code):
    processor.check_ready()
    assert fake_modal.lookups == [("basketball-scout", "process_video", None)]
    fake_modal.lookup_error = error
    with pytest.raises(ScoutError) as exc:
        processor.check_ready()
    assert exc.value.code == code
    assert type(error).__name__ in exc.value.detail


def test_submit_uploads_the_film_and_spawns(fake_modal, processor, film):
    handle = processor.submit(job_id="j_1", video=film, options={"analysis_fps": 15, "render_video": True})
    assert handle == HANDLE
    assert parse_handle(handle) == ("fc-01ABC", "j_1")
    assert fake_modal.volume.files == {"uploads/j_1/source.mp4": b"film bytes"}
    assert fake_modal.volume.force_flags == [True]
    assert fake_modal.spawned == [
        {
            "job_id": "j_1",
            "video": {"type": "volume", "path": "uploads/j_1/source.mp4", "filename": "vs Central (Senior Night).mp4"},
            "output_dir": "results/j_1",
            "options": {"analysis_fps": 15, "render_video": True},
        }
    ]


def test_submit_url_film_skips_the_upload(fake_modal, processor):
    video = VideoSource(kind="url", filename="film.mp4", url="https://films.example.org/film.mp4")
    processor.submit(job_id="j_2", video=video, options={})
    assert fake_modal.volume.files == {}
    assert fake_modal.spawned[0]["video"] == {
        "type": "url",
        "url": "https://films.example.org/film.mp4",
        "filename": "film.mp4",
    }


@pytest.mark.parametrize(
    ("error", "code"),
    [
        (EXC.VolumeUploadTimeoutError("upload timed out"), ErrorCode.MODAL_UPLOAD_FAILED),
        (RuntimeError("broken pipe"), ErrorCode.MODAL_UPLOAD_FAILED),
        (EXC.AuthError("expired"), ErrorCode.MODAL_AUTH_FAILED),
    ],
)
def test_submit_upload_failures(fake_modal, processor, film, error, code):
    fake_modal.volume.upload_error = error
    with pytest.raises(ScoutError) as exc:
        processor.submit(job_id="j_1", video=film, options={})
    assert exc.value.code == code
    assert fake_modal.spawned == []


def test_submit_spawn_failure_and_missing_film(fake_modal, processor, film, tmp_path):
    fake_modal.spawn_error = RuntimeError("quota exceeded")
    with pytest.raises(ScoutError) as exc:
        processor.submit(job_id="j_1", video=film, options={})
    assert exc.value.code == ErrorCode.MODAL_REMOTE_ERROR and "quota exceeded" in exc.value.detail

    missing = VideoSource(kind="file", filename="gone.mp4", path=tmp_path / "gone.mp4")
    with pytest.raises(ScoutError) as exc:
        processor.submit(job_id="j_1", video=missing, options={})
    assert exc.value.code == ErrorCode.VIDEO_MISSING


# --- poll -------------------------------------------------------------------------------


def test_poll_running_reads_progress_from_the_dict(fake_modal, processor):
    status = processor.poll(HANDLE)
    assert (status.state, status.progress) == ("running", None)
    assert "Waiting for a GPU" in status.message

    message = "Detecting players (12000/36000 frames)"
    fake_modal.progress.data["j_1"] = {"stage": "detect", "pct": 42.5, "message": message, "updated_at": 1.0}
    status = processor.poll(HANDLE)
    assert (status.state, status.progress, status.message) == ("running", 42.5, message)


@pytest.mark.parametrize(
    ("entry", "progress", "message"),
    [
        ({"pct": "61.0"}, 61.0, "Processing on the GPU"),
        ({"pct": 250, "message": "   "}, 100.0, "Processing on the GPU"),
        ({"pct": float("nan"), "message": "Rendering"}, None, "Rendering"),
        ({"pct": True, "message": 7}, None, None),
        ("garbage", None, None),
    ],
)
def test_poll_tolerates_odd_progress_entries(fake_modal, processor, entry, progress, message):
    fake_modal.progress.data["j_1"] = entry
    status = processor.poll(HANDLE)
    assert status.state == "running"
    assert status.progress == progress
    if message is None:
        assert "Waiting for a GPU" in status.message
    else:
        assert status.message == message


def test_poll_survives_an_unreadable_progress_dict(fake_modal, processor):
    fake_modal.progress.error = RuntimeError("dict service down")
    status = processor.poll(HANDLE)
    assert status.state == "running" and status.progress is None


@pytest.mark.parametrize(
    ("raised", "code"),
    [
        (EXC.FunctionTimeoutError("function timed out after 14400s"), ErrorCode.MODAL_TIMEOUT),
        (EXC.OutputExpiredError("output expired"), ErrorCode.MODAL_RESULT_EXPIRED),
        (EXC.RemoteError("container crashed"), ErrorCode.MODAL_REMOTE_ERROR),
        (EXC.ExecutionError("could not deserialize"), ErrorCode.MODAL_REMOTE_ERROR),
        (KeyError("frames"), ErrorCode.MODAL_REMOTE_ERROR),  # an exception re-raised from the remote function
        (EXC.AuthError("token revoked"), ErrorCode.MODAL_AUTH_FAILED),
        (EXC.InputCancellation("Input was cancelled by user"), ErrorCode.JOB_CANCELLED),
    ],
)
def test_poll_maps_modal_failures(fake_modal, processor, raised, code):
    fake_modal.outcome = raised
    status = processor.poll(HANDLE)
    assert status.state == "failed"
    assert status.error.code == code
    assert type(raised).__name__ in status.error.detail


def test_poll_keeps_waiting_through_connection_trouble(fake_modal, processor, monkeypatch):
    monkeypatch.setattr(modal_client, "CONNECTION_GRACE_S", 0.05)
    fake_modal.outcome = EXC.ConnectionError("Could not connect to the Modal server.")
    first = processor.poll(HANDLE)
    assert first.state == "running" and "Lost contact" in first.message
    time.sleep(0.1)
    later = processor.poll(HANDLE)  # still unreachable after the grace period
    assert later.state == "failed" and later.error.code == ErrorCode.MODAL_REMOTE_ERROR

    monkeypatch.setattr(modal_client, "CONNECTION_GRACE_S", 3600.0)
    fake_modal.outcome = EXC.ServiceError("unavailable")
    assert processor.poll(HANDLE).state == "running"
    fake_modal.outcome = TimeoutError()  # reachable again: the grace clock resets
    assert processor.poll(HANDLE).state == "running"


def test_poll_finished_responses(fake_modal, processor):
    fake_modal.outcome = {"status": "ok", "job_id": "j_1", "tracking_path": "results/j_1/tracking.json.gz"}
    status = processor.poll(HANDLE)
    assert status.state == "succeeded" and status.result["tracking_path"] == "results/j_1/tracking.json.gz"

    error = {"code": "GPU_OOM", "message": "Out of GPU memory at batch size 1", "detail": "tb"}
    fake_modal.outcome = {"status": "error", "error": error}
    status = processor.poll(HANDLE)
    assert status.state == "failed"
    assert (status.error.code, status.error.message, status.error.detail) == (
        ErrorCode.GPU_OOM,
        "Out of GPU memory at batch size 1",
        "tb",
    )


@pytest.mark.parametrize(
    ("response", "code"),
    [
        ({"status": "error", "error": {"code": "SOMETHING_NEW", "message": "?"}}, ErrorCode.PIPELINE_FAILED),
        ({"status": "error"}, ErrorCode.PIPELINE_FAILED),
        ({"status": "weird"}, ErrorCode.TRACKING_RESULT_INVALID),
        (None, ErrorCode.TRACKING_RESULT_INVALID),
    ],
)
def test_response_mapping_edge_cases(response, code):
    status = poll_result_from_response(response)
    assert status.state == "failed" and status.error.code == code


# --- fetch / cancel / cleanup ---------------------------------------------------------

RESULT = {
    "status": "ok",
    "job_id": "j_1",
    "tracking_path": "results/j_1/tracking.json.gz",
    "annotated_video_path": "results/j_1/annotated.mp4",
}


def test_fetch_downloads_both_files(fake_modal, processor, tmp_path):
    fake_modal.volume.files.update({"results/j_1/tracking.json.gz": b"gzip json", "results/j_1/annotated.mp4": b"mp4"})
    dest = tmp_path / "game"
    output = processor.fetch(HANDLE, RESULT, dest)
    assert output.tracking_path.read_bytes() == b"gzip json"
    assert output.annotated_video_path == dest / "annotated.mp4"
    assert output.annotated_video_path.read_bytes() == b"mp4"
    assert output.warnings == []
    assert sorted(p.name for p in dest.iterdir()) == ["annotated.mp4", "tracking.json.gz"]  # no temp files left


def test_fetch_without_annotated_video_is_only_a_warning(fake_modal, processor, tmp_path):
    fake_modal.volume.files["results/j_1/tracking.json.gz"] = b"gzip json"
    output = processor.fetch(HANDLE, RESULT, tmp_path)
    assert output.annotated_video_path is None
    assert output.warnings and "annotated video" in output.warnings[0]


def test_fetch_missing_tracking(fake_modal, processor, tmp_path):
    dest = tmp_path / "game"
    with pytest.raises(ScoutError) as exc:
        processor.fetch(HANDLE, RESULT, dest)
    assert exc.value.code == ErrorCode.TRACKING_RESULT_INVALID
    with pytest.raises(ScoutError) as exc:
        processor.fetch(HANDLE, {"status": "ok"}, dest)
    assert exc.value.code == ErrorCode.TRACKING_RESULT_INVALID
    assert list(dest.iterdir()) == []  # the half-downloaded temp file was removed


def test_fetch_retries_transient_download_errors(fake_modal, processor, tmp_path):
    fake_modal.volume.files["results/j_1/tracking.json.gz"] = b"gzip json"
    fake_modal.volume.read_failures = 2
    result = {"status": "ok", "tracking_path": "results/j_1/tracking.json.gz"}
    assert processor.fetch(HANDLE, result, tmp_path).tracking_path.read_bytes() == b"gzip json"

    fake_modal.volume.read_failures = modal_client.DOWNLOAD_ATTEMPTS
    with pytest.raises(ScoutError) as exc:
        processor.fetch(HANDLE, result, tmp_path / "again")
    assert exc.value.code == ErrorCode.MODAL_REMOTE_ERROR


def test_cancel_is_best_effort(fake_modal, processor):
    processor.cancel(HANDLE)
    assert fake_modal.cancelled == ["fc-01ABC"]
    fake_modal.cancel_error = RuntimeError("already finished")
    processor.cancel(HANDLE)  # logged, never raised


def test_cleanup_removes_this_jobs_files_and_progress(fake_modal, processor):
    fake_modal.volume.files.update(
        {
            "uploads/j_1/source.mp4": b"film",
            "results/j_1/tracking.json.gz": b"t",
            "results/j_1/annotated.mp4": b"v",
            "uploads/j_10/source.mp4": b"another job",
        }
    )
    fake_modal.progress.data.update({"j_1": {"pct": 100}, "j_10": {"pct": 3}})
    processor.cleanup(HANDLE, RESULT)
    assert fake_modal.volume.files == {"uploads/j_10/source.mp4": b"another job"}
    assert fake_modal.progress.data == {"j_10": {"pct": 3}}
    processor.cleanup(HANDLE, None)  # nothing left: missing paths are fine


@pytest.mark.parametrize(
    ("handle", "expected"),
    [("fc-abc|j_1", ("fc-abc", "j_1")), (" fc-abc | j_1 ", ("fc-abc", "j_1")), ("fc-abc", ("fc-abc", None))],
)
def test_parse_handle(handle, expected):
    assert parse_handle(handle) == expected


@pytest.mark.parametrize("handle", ["mock:j_1", "", "|j_1"])
def test_parse_handle_rejects_foreign_handles(handle):
    with pytest.raises(ScoutError) as exc:
        parse_handle(handle)
    assert exc.value.code == ErrorCode.INTERNAL_ERROR


def test_real_sdk_exception_hierarchy_matches_our_assumptions():
    """Guards the except-clause order in ModalProcessor.poll against SDK changes."""
    modal = pytest.importorskip("modal")
    errors = modal.exception
    assert not issubclass(errors.TimeoutError, TimeoutError)
    assert issubclass(errors.FunctionTimeoutError, errors.TimeoutError)
    assert issubclass(errors.OutputExpiredError, errors.TimeoutError)
    assert issubclass(errors.VolumeUploadTimeoutError, errors.TimeoutError)
    assert issubclass(errors.InputCancellation, BaseException) and not issubclass(errors.InputCancellation, Exception)
    for name in ERROR_SUBCLASSES:
        assert issubclass(getattr(errors, name), errors.Error)
