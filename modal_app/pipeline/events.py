"""Supplementary raw-event detection on perception data (pure Python + numpy).

OpenHoopVision already emits shots, passes, rebounds, turnovers/steals and dribbles.
This module adds what it does not produce -- free throws, (inferred) fouls, screens,
jump balls, period boundaries -- and fills attributes it leaves empty (assists,
offensive/defensive rebound, blocks). It works on a ``Perception`` built by
``modal_app.pipeline.adapter`` (or by any other front end).

Runner usage::

    enriched = enrich_events(perception, ohv_events)
    extra = detect_events(perception, existing_events=enriched)
    replaced = {e["attrs"]["replaces_event_id"] for e in extra if e["attrs"].get("replaces_event_id")}
    events = [e for e in enriched if e["event_id"] not in replaced] + extra
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from modal_app.pipeline.types import Perception


@dataclass
class EventConfig:
    """Thresholds (defaults tuned for high-school film at ~15 analysed fps)."""


def enrich_events(
    perception: Perception, existing_events: list[dict[str, Any]], cfg: EventConfig | None = None
) -> list[dict[str, Any]]:
    """Return copies of ``existing_events`` with missing attrs filled in:
    ``shot.assisted_by_track``, ``rebound.offensive``, ``shot.blocked_by_track``."""
    raise NotImplementedError


def detect_events(
    perception: Perception,
    cfg: EventConfig | None = None,
    existing_events: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Return only NEW RawEvent dicts (free_throw, foul, screen, jump_ball, period_start,
    period_end), deduplicated against ``existing_events``. A free throw that coincides
    with an existing ``shot`` carries ``attrs.replaces_event_id`` so the runner can drop it.
    """
    raise NotImplementedError
