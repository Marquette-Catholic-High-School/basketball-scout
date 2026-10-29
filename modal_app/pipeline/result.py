"""Serialise perception + events into the TrackingResult dict (docs/TRACKING_SCHEMA.md)."""

from __future__ import annotations

from typing import Any

from modal_app.pipeline.types import Perception

TRACKING_SCHEMA_VERSION = "1.0"


def build_tracking_result(
    perception: Perception,
    events: list[dict[str, Any]],
    *,
    job_id: str | None,
    pipeline_info: dict[str, Any],
    artifacts: dict[str, str] | None = None,
    sample_stride: int = 1,
) -> dict[str, Any]:
    """JSON-serialisable dict that validates as ``scout.schemas.TrackingResult``.

    ``sample_stride`` thins track samples (every n-th analysed frame) to bound size;
    keypoints are not included (too large).
    """
    raise NotImplementedError
