"""Local processor: runs ``modal_app.pipeline.runner.run_pipeline`` in a thread on this machine."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from scout.config import Settings
from scout.processing.base import PollResult, Processor, ProcessorOutput, VideoSource


class LocalProcessor(Processor):
    name = "local"

    def __init__(self, settings: Settings | None = None) -> None:
        raise NotImplementedError

    def check_ready(self) -> None:
        raise NotImplementedError

    def submit(self, *, job_id: str, video: VideoSource, options: dict[str, Any]) -> str:
        raise NotImplementedError

    def poll(self, handle: str) -> PollResult:
        raise NotImplementedError

    def fetch(self, handle: str, result: dict[str, Any], dest_dir: Path) -> ProcessorOutput:
        raise NotImplementedError
