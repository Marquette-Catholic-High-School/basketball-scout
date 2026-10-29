"""Local processor: runs ``modal_app.pipeline.runner.run_pipeline`` in a thread on this machine.

For a server (or development VM) with its own NVIDIA GPU and the GPU requirements
installed (``pip install -r modal_app/requirements-gpu.txt``). Runs go one at a time
through a single-thread executor because they share one GPU. Outputs are written to
``<data_dir>/local_runs/<job_id>/`` and copied into the game folder by ``fetch``.

Limitations, by design: progress lives in memory, so a run interrupted by a worker
restart is reported as ``WORKER_LOST`` (retry the job); a run that already started
cannot be stopped early: cancelling only discards its result.
"""

from __future__ import annotations

import importlib
import logging
import os
import shutil
import tempfile
import threading
from concurrent.futures import CancelledError, Future, ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from modal_app.pipeline import runner
from modal_app.pipeline.errors import PipelineError, is_cuda_oom
from scout.config import Settings, get_settings
from scout.errors import ErrorCode, ScoutError
from scout.processing.base import PollResult, Processor, ProcessorOutput, VideoSource, poll_result_from_response

logger = logging.getLogger(__name__)

HANDLE_PREFIX = "local:"
TRACKING_FILENAME = "tracking.json.gz"
ANNOTATED_FILENAME = "annotated.mp4"
GPU_HINT = "Install the GPU requirements: pip install -r modal_app/requirements-gpu.txt"


@dataclass
class _LocalRun:
    output_dir: Path
    future: Future[dict[str, Any]] | None = None
    pct: float | None = None
    message: str = "Waiting for the local GPU"
    lock: threading.Lock = field(default_factory=threading.Lock)

    def report(self, stage: str, pct: float, message: str) -> None:
        """Progress sink handed to the pipeline: (stage, overall pct, message)."""
        with self.lock:
            self.pct = pct
            self.message = message or f"Processing ({stage})"


class LocalProcessor(Processor):
    name = "local"
    poll_interval = 2.0

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="local-pipeline")
        self._runs: dict[str, _LocalRun] = {}
        self._lock = threading.Lock()

    def check_ready(self) -> None:
        try:
            importlib.import_module("torch")
        except ImportError as exc:
            message = "The local GPU pipeline needs PyTorch, which is not installed on this machine."
            raise ScoutError(ErrorCode.MODEL_LOAD_FAILED, message, hint=GPU_HINT, detail=str(exc)) from exc

    def submit(self, *, job_id: str, video: VideoSource, options: dict[str, Any]) -> str:
        source = self._source(video)
        run = _LocalRun(output_dir=self._run_dir(job_id))
        run.output_dir.mkdir(parents=True, exist_ok=True)
        run.future = self._executor.submit(
            runner.run_pipeline,
            source,
            dict(options),
            output_dir=str(run.output_dir),
            job_id=job_id,
            progress=run.report,
            filename=video.filename,
        )
        with self._lock:
            self._runs[job_id] = run
        logger.info("Local pipeline queued for job %s (%s)", job_id, video.filename)
        return HANDLE_PREFIX + job_id

    def poll(self, handle: str) -> PollResult:
        job_id = _job_id(handle)
        with self._lock:
            run = self._runs.get(job_id)
        if run is None or run.future is None:
            message = "The local run was interrupted (the worker restarted); retry the job."
            return PollResult(state="failed", error=ScoutError(ErrorCode.WORKER_LOST, message))
        if not run.future.done():
            with run.lock:
                return PollResult(state="running", progress=run.pct, message=run.message)
        try:
            response = run.future.result()
        except Exception as exc:
            return PollResult(state="failed", error=_error_from_exception(exc))
        return poll_result_from_response(response)

    def fetch(self, handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        run_dir = self._run_dir(_job_id(handle))
        tracking_src = _find_output(run_dir, result.get("tracking_path"), TRACKING_FILENAME)
        if tracking_src is None:
            raise ScoutError(ErrorCode.TRACKING_RESULT_INVALID, "The local pipeline did not write a tracking file.")
        dest_dir.mkdir(parents=True, exist_ok=True)
        output = ProcessorOutput(tracking_path=_copy_atomic(tracking_src, dest_dir / TRACKING_FILENAME))
        reported_video = result.get("annotated_video_path")
        if reported_video:
            video_src = _find_output(run_dir, reported_video, ANNOTATED_FILENAME)
            if video_src is None:
                output.warnings.append("The local pipeline did not produce the annotated video.")
            else:
                output.annotated_video_path = _copy_atomic(video_src, dest_dir / ANNOTATED_FILENAME)
        return output

    def cancel(self, handle: str) -> None:
        with self._lock:
            run = self._runs.get(_job_id(handle))
        if run is not None and run.future is not None and not run.future.cancel():
            logger.warning("Local run %s already started and cannot be stopped; its result will be ignored", handle)

    def cleanup(self, handle: str, result: dict[str, Any] | None) -> None:
        job_id = _job_id(handle)
        with self._lock:
            self._runs.pop(job_id, None)
        shutil.rmtree(self._run_dir(job_id), ignore_errors=True)

    def _run_dir(self, job_id: str) -> Path:
        return self.settings.data_dir / "local_runs" / job_id

    @staticmethod
    def _source(video: VideoSource) -> str:
        """Local file path, or the URL for the pipeline to download."""
        if video.kind == "url" and video.url:
            return video.url
        if video.kind == "file" and video.path is not None and video.path.exists():
            return str(video.path)
        raise ScoutError(ErrorCode.VIDEO_MISSING)


def _job_id(handle: str) -> str:
    job_id = handle[len(HANDLE_PREFIX) :] if handle.startswith(HANDLE_PREFIX) else ""
    if not job_id or any(c in job_id for c in "/\\") or job_id in {".", ".."}:
        raise ScoutError(ErrorCode.INTERNAL_ERROR, detail=f"not a local job handle: {handle!r}")
    return job_id


def _error_from_exception(exc: Exception) -> ScoutError:
    """The runner returns expected failures as dicts; map anything it raised anyway."""
    if isinstance(exc, ScoutError):
        return exc
    if isinstance(exc, CancelledError):
        return ScoutError(ErrorCode.JOB_CANCELLED)
    if isinstance(exc, PipelineError):
        return ScoutError.from_code(exc.code, exc.message, exc.detail)
    detail = f"{type(exc).__name__}: {exc}"[:2000]
    if is_cuda_oom(exc):
        return ScoutError(ErrorCode.GPU_OOM, detail=detail)
    logger.error("Local pipeline crashed: %s", detail, exc_info=exc)
    return ScoutError(ErrorCode.PIPELINE_FAILED, detail=detail)


def _find_output(run_dir: Path, reported: Any, default_name: str) -> Path | None:
    """Locate an output file the runner reported (absolute, or relative like "results/<job>/x")."""
    candidates: list[Path] = []
    if reported:
        path = Path(str(reported))
        candidates += [path] if path.is_absolute() else [run_dir / path, run_dir / path.name]
    candidates.append(run_dir / default_name)
    return next((c for c in candidates if c.is_file()), None)


def _copy_atomic(src: Path, dest: Path) -> Path:
    fd, tmp = tempfile.mkstemp(dir=dest.parent, prefix=f".{dest.name}.", suffix=".part")
    os.close(fd)
    try:
        shutil.copyfile(src, tmp)
        os.replace(tmp, dest)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return dest
