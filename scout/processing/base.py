"""Video processor interface.

A processor turns a game film into a ``TrackingResult`` (``tracking.json.gz``) and,
optionally, an annotated MP4. The worker drives every processor the same way so
long GPU jobs survive worker restarts::

    handle = processor.submit(job_id=..., video=..., options=...)   # persist handle on the job
    while True:
        status = processor.poll(handle)                              # non-blocking
        if status.state != "running": break
    output = processor.fetch(handle, status.result, dest_dir)        # download artifacts
    processor.cleanup(handle, status.result)

Implementations:

* ``scout.processing.modal_client.ModalProcessor`` -- uploads the film to a Modal
  Volume and spawns the deployed GPU function (``modal_app/app.py``).
* ``scout.processing.mock.MockProcessor`` -- no GPU; generates a synthetic game so the
  whole UI can be exercised (``SCOUT_PROCESSOR=mock``).
* ``scout.processing.local.LocalProcessor`` -- runs ``modal_app.pipeline.runner`` in a
  background thread on this machine (needs the GPU requirements installed locally).

The request/response dictionaries are the same for every processor and are
documented in ``docs/TRACKING_SCHEMA.md`` ("Processing request/response").
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

from scout.errors import ScoutError


@dataclass(frozen=True)
class VideoSource:
    """Where the film comes from: a local file (uploaded) or a remote URL."""

    kind: Literal["file", "url"]
    filename: str
    path: Path | None = None
    url: str | None = None


@dataclass
class PollResult:
    state: Literal["running", "succeeded", "failed"]
    progress: float | None = None  # 0..100 within the GPU stage
    message: str | None = None
    result: dict[str, Any] | None = None  # processor response dict (see docs/TRACKING_SCHEMA.md)
    error: ScoutError | None = None


@dataclass
class ProcessorOutput:
    tracking_path: Path
    annotated_video_path: Path | None = None
    warnings: list[str] = field(default_factory=list)


class Processor(ABC):
    name: str = "base"

    @abstractmethod
    def submit(self, *, job_id: str, video: VideoSource, options: dict[str, Any]) -> str:
        """Start processing; return an opaque handle (stored as ``Job.external_id``)."""

    @abstractmethod
    def poll(self, handle: str) -> PollResult:
        """Non-blocking status check."""

    @abstractmethod
    def fetch(self, handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        """Copy the tracking JSON (and annotated video, if any) into ``dest_dir``."""

    def cancel(self, handle: str) -> None:  # noqa: B027 - optional
        """Best-effort cancellation."""

    def cleanup(self, handle: str, result: dict[str, Any] | None) -> None:  # noqa: B027 - optional
        """Delete remote copies (Modal volume files) once results are safely local."""

    def check_ready(self) -> None:  # noqa: B027 - optional
        """Raise ``ScoutError`` if the processor cannot run at all (missing credentials...)."""
