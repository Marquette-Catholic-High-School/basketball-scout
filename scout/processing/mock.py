"""Mock processor: no GPU, produces a synthetic game (``SCOUT_PROCESSOR=mock``).

It lets a coach (or a developer without a GPU or Modal account) click through the
whole app: the job pretends to run on a GPU for ``SCOUT_MOCK_SECONDS`` and then
"returns" a synthetic game from ``scout.analysis.synthetic``.

Restart safety: the handle is ``mock:<job_id>``. If the worker restarts while a mock
job is "running", the in-memory start time is gone, so a poll for an unknown handle
reports the simulated run as finished (a real GPU job would also have kept running
while the worker was down).
"""

from __future__ import annotations

import logging
import math
import shutil
import subprocess
import threading
import time
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from scout import storage
from scout.analysis import synthetic
from scout.config import Settings, get_settings
from scout.errors import ErrorCode, ScoutError
from scout.processing.base import PollResult, Processor, ProcessorOutput, VideoSource

logger = logging.getLogger(__name__)

HANDLE_PREFIX = "mock:"
DEFAULT_DURATION_S = 600.0
SEED_OPTION = "seed"  # key in TrackingResult.pipeline.options; the worker reads it for demo rosters
TRACKING_FILENAME = "tracking.json.gz"


def seed_for_job(job_id: str) -> int:
    """Stable per-job seed (``hash()`` is randomised per process, crc32 is not)."""
    return zlib.crc32(job_id.encode("utf-8")) % 100_000


@dataclass
class _MockRun:
    started: float  # time.monotonic() at submit
    video: VideoSource


class MockProcessor(Processor):
    name = "mock"
    poll_interval = 0.5

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()
        self._runs: dict[str, _MockRun] = {}
        self._lock = threading.Lock()

    def submit(self, *, job_id: str, video: VideoSource, options: dict[str, Any]) -> str:
        with self._lock:
            self._runs[job_id] = _MockRun(started=time.monotonic(), video=video)
        seconds = self.settings.mock_seconds
        logger.info("Mock job %s started for %s (%.0fs simulated GPU time)", job_id, video.filename, seconds)
        return HANDLE_PREFIX + job_id

    def poll(self, handle: str) -> PollResult:
        job_id = _job_id(handle)
        with self._lock:
            run = self._runs.get(job_id)
        total = self.settings.mock_seconds
        elapsed = time.monotonic() - run.started if run else total
        if elapsed < total:
            pct = round(100.0 * elapsed / total, 1)
            message = f"Demo mode: simulating GPU processing ({pct:.0f}%)"
            return PollResult(state="running", progress=pct, message=message)
        message = "Demo mode: simulated processing finished"
        return PollResult(state="succeeded", progress=100.0, message=message, result=_response(job_id))

    def fetch(self, handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        """Generate the synthetic game and write ``tracking.json.gz`` into ``dest_dir``."""
        job_id = _job_id(handle)
        with self._lock:
            run = self._runs.pop(job_id, None)
        seed = seed_for_job(job_id)
        duration_s = _source_duration(run.video) if run else None
        filename = run.video.filename if run else "synthetic.mp4"
        tracking, _truth = synthetic.generate_synthetic_game(
            seed=seed, duration_s=duration_s or DEFAULT_DURATION_S, filename=filename
        )
        # Record provenance so a later re-analysis can rebuild matching demo rosters.
        options = {**tracking.pipeline.options, SEED_OPTION: seed}
        tracking = tracking.model_copy(
            update={"job_id": job_id, "pipeline": tracking.pipeline.model_copy(update={"options": options})}
        )
        dest_dir.mkdir(parents=True, exist_ok=True)
        path = dest_dir / TRACKING_FILENAME
        storage.write_json(path, tracking.model_dump_json())
        duration = tracking.video.duration_s
        logger.info("Mock job %s wrote a synthetic game (seed %d, %.0fs) to %s", job_id, seed, duration, path)
        return ProcessorOutput(tracking_path=path)


def _job_id(handle: str) -> str:
    if not handle.startswith(HANDLE_PREFIX) or len(handle) == len(HANDLE_PREFIX):
        raise ScoutError(ErrorCode.INTERNAL_ERROR, detail=f"not a mock job handle: {handle!r}")
    return handle[len(HANDLE_PREFIX) :]


def _response(job_id: str) -> dict[str, Any]:
    """Same shape as the GPU function's success response (docs/TRACKING_SCHEMA.md)."""
    return {
        "status": "ok",
        "job_id": job_id,
        "tracking_path": TRACKING_FILENAME,
        "annotated_video_path": None,
        "summary": {},
        "warnings": [],
    }


def _source_duration(video: VideoSource) -> float | None:
    """Length of the uploaded film, so the demo game is about as long as the real one."""
    if video.kind != "file" or video.path is None or not video.path.exists():
        return None
    return probe_duration(video.path)


def probe_duration(path: Path) -> float | None:
    """Video duration in seconds via ``ffprobe``; None when ffprobe is missing or fails."""
    exe = shutil.which("ffprobe")
    if exe is None:
        return None
    command = [exe, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)]
    try:
        out = subprocess.run(command, capture_output=True, text=True, timeout=60, check=True).stdout
        duration = float(out.strip())
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        logger.info("ffprobe could not read the duration of %s: %s", path, exc)
        return None
    return duration if math.isfinite(duration) and duration > 0 else None
