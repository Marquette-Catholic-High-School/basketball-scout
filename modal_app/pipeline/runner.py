"""End-to-end pipeline orchestration (used by the Modal function and the local processor)."""

from __future__ import annotations

from typing import Any

from modal_app.pipeline.progress import ProgressSink


def run_pipeline(
    video_path: str,
    options: dict[str, Any],
    *,
    output_dir: str,
    job_id: str,
    progress: ProgressSink | None = None,
    filename: str | None = None,
) -> dict[str, Any]:
    """Process one film and write ``tracking.json.gz`` (+ ``annotated.mp4``) to ``output_dir``.

    Returns the processing response dict (docs/TRACKING_SCHEMA.md): ``{"status": "ok", ...}``
    or ``{"status": "error", "error": {"code", "message", "detail"}}``. Expected failures
    (PipelineError, CUDA OOM after retries) are returned, not raised.
    """
    raise NotImplementedError
