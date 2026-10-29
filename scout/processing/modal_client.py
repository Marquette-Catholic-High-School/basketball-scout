"""Modal GPU processor: upload film to a Modal Volume, spawn the deployed function, poll, download.

One job, step by step::

    check_ready()  credentials exist and the deployed function can be looked up
    submit()       upload the film to the volume at uploads/<job_id>/<name> (URL films
                   skip this), spawn process_video(request); handle = "<fc-id>|<job_id>"
    poll()         FunctionCall.get(timeout=0); while running, progress comes from the
                   Modal Dict the pipeline writes to
    fetch()        download results/<job_id>/tracking.json.gz (+ annotated.mp4)
    cleanup()      delete uploads/<job_id> and results/<job_id>, drop the progress entry

``modal`` is imported inside methods so the web server and worker start (and the mock /
local processors work) on machines where Modal is not installed or configured.

A spawned call keeps its result for 7 days, so a worker that restarts resumes polling
with nothing but the handle saved on the job (``Job.external_id``).
"""

from __future__ import annotations

import logging
import math
import os
import re
import tempfile
import threading
import time
from pathlib import Path
from types import ModuleType
from typing import Any

from scout.config import Settings, get_settings
from scout.errors import ErrorCode, ScoutError
from scout.processing.base import PollResult, Processor, ProcessorOutput, VideoSource, poll_result_from_response

logger = logging.getLogger(__name__)

HANDLE_SEPARATOR = "|"
TRACKING_FILENAME = "tracking.json.gz"
ANNOTATED_FILENAME = "annotated.mp4"
# While Modal cannot be reached at all, poll() keeps answering "running" for this long
# before failing the job: the GPU call keeps running meanwhile and its result waits for us.
CONNECTION_GRACE_S = 3600.0
DOWNLOAD_ATTEMPTS = 3
_UNSAFE_CHARS = re.compile(r"[^A-Za-z0-9._-]+")


def _modal() -> ModuleType:
    import modal

    return modal


def make_handle(call_id: str, job_id: str) -> str:
    return f"{call_id}{HANDLE_SEPARATOR}{job_id}"


def parse_handle(handle: str) -> tuple[str, str | None]:
    """``"fc-...|<job_id>"`` -> ``(call_id, job_id)``. A bare ``"fc-..."`` id is accepted (no job id)."""
    call_id, _, job_id = (handle or "").partition(HANDLE_SEPARATOR)
    call_id, job_id = call_id.strip(), job_id.strip()
    if not call_id.startswith("fc-"):
        raise ScoutError(ErrorCode.INTERNAL_ERROR, detail=f"not a Modal job handle: {handle!r}")
    return call_id, job_id or None


class ModalProcessor(Processor):
    name = "modal"
    download_retry_delay_s = 5.0

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()
        self._lock = threading.Lock()
        self._unreachable_since: dict[str, float] = {}  # handle -> monotonic time of the first failed poll

    # --- Processor interface ------------------------------------------------

    def check_ready(self) -> None:
        self._lookup_function()

    def submit(self, *, job_id: str, video: VideoSource, options: dict[str, Any]) -> str:
        function = self._lookup_function()
        request = {
            "job_id": job_id,
            "video": self._video_spec(job_id, video),
            "output_dir": f"results/{job_id}",
            "options": options,
        }
        errors = _modal().exception
        try:
            call = function.spawn(request)
        except (errors.AuthError, errors.PermissionDeniedError) as exc:
            raise ScoutError(ErrorCode.MODAL_AUTH_FAILED, detail=_describe(exc)) from exc
        except Exception as exc:
            message = "Modal did not accept the GPU job."
            raise ScoutError(ErrorCode.MODAL_REMOTE_ERROR, message, detail=_describe(exc)) from exc
        logger.info("Spawned Modal call %s for job %s", call.object_id, job_id)
        return make_handle(call.object_id, job_id)

    def poll(self, handle: str) -> PollResult:
        call_id, job_id = parse_handle(handle)
        modal = _modal()
        errors = modal.exception
        try:
            response = modal.FunctionCall.from_id(call_id).get(timeout=0)
        except TimeoutError:  # the BUILTIN TimeoutError: still queued or running
            self._forget_unreachable(handle)
            return self._running(job_id)
        except errors.FunctionTimeoutError as exc:  # subclass of modal's TimeoutError: check it first
            return _failed(ErrorCode.MODAL_TIMEOUT, "The GPU function ran past its time limit on Modal.", exc)
        except errors.OutputExpiredError as exc:
            return _failed(ErrorCode.MODAL_RESULT_EXPIRED, None, exc)
        except (errors.ConnectionError, errors.ServiceError, errors.TimeoutError) as exc:
            return self._unreachable(handle, exc)
        except (errors.AuthError, errors.PermissionDeniedError) as exc:
            return _failed(ErrorCode.MODAL_AUTH_FAILED, None, exc)
        except errors.InputCancellation as exc:  # a BaseException, so it is not caught below
            return _failed(ErrorCode.JOB_CANCELLED, "The GPU job was cancelled on Modal.", exc)
        except Exception as exc:  # RemoteError, ExecutionError, or the remote exception itself
            logger.warning("Modal call %s failed: %s", call_id, _describe(exc))
            return _failed(ErrorCode.MODAL_REMOTE_ERROR, None, exc)
        self._forget_unreachable(handle)
        return poll_result_from_response(response)

    def fetch(self, handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        remote_tracking = result.get("tracking_path")
        if not remote_tracking:
            message = "The GPU job finished without reporting a tracking file."
            raise ScoutError(ErrorCode.TRACKING_RESULT_INVALID, message)
        dest_dir.mkdir(parents=True, exist_ok=True)
        volume = self._volume()
        try:
            tracking = self._download(volume, str(remote_tracking), dest_dir / TRACKING_FILENAME)
        except FileNotFoundError as exc:
            message = "The tracking file is missing from the Modal volume."
            raise ScoutError(ErrorCode.TRACKING_RESULT_INVALID, message, detail=str(remote_tracking)) from exc
        output = ProcessorOutput(tracking_path=tracking)
        remote_video = result.get("annotated_video_path")
        if remote_video:
            try:
                output.annotated_video_path = self._download(volume, str(remote_video), dest_dir / ANNOTATED_FILENAME)
            except (FileNotFoundError, ScoutError) as exc:
                logger.warning("Annotated video %s not downloaded: %s", remote_video, exc)
                output.warnings.append(
                    "The annotated video could not be downloaded; the original film is still available."
                )
        return output

    def cancel(self, handle: str) -> None:
        call_id, _ = parse_handle(handle)
        try:
            _modal().FunctionCall.from_id(call_id).cancel()
        except Exception as exc:
            logger.warning("Could not cancel Modal call %s: %s", call_id, _describe(exc))
            return
        logger.info("Cancelled Modal call %s", call_id)

    def cleanup(self, handle: str, result: dict[str, Any] | None) -> None:
        """Delete the uploaded film, the remote results and the progress entry (errors only logged)."""
        _, job_id = parse_handle(handle)
        self._forget_unreachable(handle)
        if not job_id:
            return
        volume = self._volume()
        for path in (f"uploads/{job_id}", f"results/{job_id}"):
            try:
                volume.remove_file(path, recursive=True)
            except FileNotFoundError:
                pass
            except Exception as exc:
                logger.warning("Could not delete %s from the Modal volume: %s", path, _describe(exc))
        try:
            self._progress_store().pop(job_id, None)
        except Exception as exc:
            logger.warning("Could not clear GPU progress for %s: %s", job_id, _describe(exc))

    # --- helpers --------------------------------------------------------------

    def _lookup_function(self) -> Any:
        """The deployed GPU function, hydrated (``from_name`` alone is lazy and checks nothing)."""
        if not self.settings.modal_configured:
            raise ScoutError(ErrorCode.MODAL_NOT_CONFIGURED)
        modal = _modal()
        errors = modal.exception
        s = self.settings
        target = f"{s.modal_app_name}/{s.modal_function_name}"
        try:
            function = modal.Function.from_name(
                s.modal_app_name, s.modal_function_name, environment_name=s.modal_environment
            )
            function.hydrate()
        except errors.NotFoundError as exc:
            message = f"The Modal function {target} was not found."
            raise ScoutError(ErrorCode.MODAL_APP_NOT_DEPLOYED, message, detail=_describe(exc)) from exc
        except (errors.AuthError, errors.PermissionDeniedError) as exc:
            raise ScoutError(ErrorCode.MODAL_AUTH_FAILED, detail=_describe(exc)) from exc
        except Exception as exc:
            raise ScoutError(
                ErrorCode.MODAL_REMOTE_ERROR,
                f"Could not reach Modal to look up {target}.",
                hint="Check the server's internet connection and retry.",
                detail=_describe(exc),
            ) from exc
        return function

    def _volume(self) -> Any:
        s = self.settings
        return _modal().Volume.from_name(
            s.modal_volume_name, create_if_missing=True, environment_name=s.modal_environment
        )

    def _progress_store(self) -> Any:
        s = self.settings
        return _modal().Dict.from_name(
            s.modal_progress_dict, create_if_missing=True, environment_name=s.modal_environment
        )

    def _video_spec(self, job_id: str, video: VideoSource) -> dict[str, str]:
        """The request's ``video`` entry; uploads a local film to the volume first."""
        if video.kind == "url":
            if not video.url:
                raise ScoutError(ErrorCode.VIDEO_MISSING)
            return {"type": "url", "url": video.url, "filename": video.filename}
        if video.path is None or not video.path.exists():
            raise ScoutError(ErrorCode.VIDEO_MISSING, "The uploaded film is missing from the server.")
        remote_path = f"uploads/{job_id}/{_safe_name(video.path.name)}"
        self._upload(video.path, remote_path)
        return {"type": "volume", "path": remote_path, "filename": video.filename}

    def _upload(self, local_path: Path, remote_path: str) -> None:
        errors = _modal().exception
        size_mb = local_path.stat().st_size / 1e6
        volume_name = self.settings.modal_volume_name
        logger.info("Uploading %s (%.0f MB) to Modal volume %s at %s", local_path, size_mb, volume_name, remote_path)
        started = time.monotonic()
        try:
            with self._volume().batch_upload(force=True) as batch:
                batch.put_file(str(local_path), "/" + remote_path)
        except errors.VolumeUploadTimeoutError as exc:
            message = "Uploading the film to Modal timed out."
            raise ScoutError(ErrorCode.MODAL_UPLOAD_FAILED, message, detail=_describe(exc)) from exc
        except (errors.AuthError, errors.PermissionDeniedError) as exc:
            raise ScoutError(ErrorCode.MODAL_AUTH_FAILED, detail=_describe(exc)) from exc
        except Exception as exc:
            raise ScoutError(ErrorCode.MODAL_UPLOAD_FAILED, detail=_describe(exc)) from exc
        logger.info("Uploaded %s in %.0fs", remote_path, time.monotonic() - started)

    def _running(self, job_id: str | None) -> PollResult:
        pct, message = self._read_progress(job_id)
        if pct is None and message is None:
            return PollResult(state="running", message="Waiting for a GPU (starting one can take a minute or two)")
        return PollResult(state="running", progress=pct, message=message or "Processing on the GPU")

    def _read_progress(self, job_id: str | None) -> tuple[float | None, str | None]:
        """``(pct, message)`` from the progress Dict; ``(None, None)`` when missing or unreadable."""
        if not job_id:
            return None, None
        try:
            entry = self._progress_store().get(job_id)
        except Exception as exc:
            logger.debug("Could not read GPU progress for %s: %s", job_id, exc)
            return None, None
        if not isinstance(entry, dict):
            return None, None
        message = entry.get("message")
        message = message.strip() if isinstance(message, str) and message.strip() else None
        return _as_percent(entry.get("pct")), message

    def _unreachable(self, handle: str, exc: BaseException) -> PollResult:
        """Modal could not be reached: keep waiting, but not forever."""
        now = time.monotonic()
        with self._lock:
            since = self._unreachable_since.setdefault(handle, now)
        if now - since > CONNECTION_GRACE_S:
            self._forget_unreachable(handle)
            message = f"Lost contact with Modal for more than {CONNECTION_GRACE_S / 60:.0f} minutes."
            return _failed(ErrorCode.MODAL_REMOTE_ERROR, message, exc)
        logger.warning("Could not reach Modal to check %s (will keep trying): %s", handle, _describe(exc))
        return PollResult(state="running", message="Lost contact with the GPU service; retrying...")

    def _forget_unreachable(self, handle: str) -> None:
        with self._lock:
            self._unreachable_since.pop(handle, None)

    def _download(self, volume: Any, remote_path: str, dest: Path) -> Path:
        """Download one volume file to ``dest`` atomically, retrying transient failures."""
        attempt = 1
        while True:
            try:
                _download_once(volume, remote_path, dest)
                return dest
            except FileNotFoundError:
                raise
            except Exception as exc:
                if attempt >= DOWNLOAD_ATTEMPTS:
                    raise ScoutError(
                        ErrorCode.MODAL_REMOTE_ERROR,
                        "Downloading the GPU results from Modal failed.",
                        hint="Check the server's internet connection and retry.",
                        detail=_describe(exc),
                    ) from exc
                logger.warning(
                    "Download of %s failed (attempt %d of %d): %s", remote_path, attempt, DOWNLOAD_ATTEMPTS, exc
                )
                attempt += 1
                time.sleep(self.download_retry_delay_s)


def _download_once(volume: Any, remote_path: str, dest: Path) -> None:
    """Write to a temp file next to ``dest`` and rename, so nobody sees a half-downloaded file."""
    fd, tmp = tempfile.mkstemp(dir=dest.parent, prefix=f".{dest.name}.", suffix=".part")
    try:
        with os.fdopen(fd, "wb") as fh:
            volume.read_file_into_fileobj(remote_path, fh)
        os.replace(tmp, dest)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def _failed(code: ErrorCode, message: str | None, exc: BaseException) -> PollResult:
    return PollResult(state="failed", error=ScoutError(code, message, detail=_describe(exc)))


def _describe(exc: BaseException) -> str:
    text = str(exc).strip()
    return (f"{type(exc).__name__}: {text}" if text else type(exc).__name__)[:2000]


def _as_percent(value: Any) -> float | None:
    """Progress percentage clamped to 0..100; None for anything that is not a finite number."""
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        pct = float(value)
    except ValueError:
        return None
    return min(100.0, max(0.0, pct)) if math.isfinite(pct) else None


def _safe_name(name: str) -> str:
    """Volume file name without spaces or path tricks (the coach's filename travels separately)."""
    return _UNSAFE_CHARS.sub("_", name).strip("._") or "source.mp4"
