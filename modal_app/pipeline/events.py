"""Raw game-event detection from perception data (pure Python, unit-testable).

Turns ball trajectory + ball holders + player tracks (+ rims / court mapping when
available) into RawEvent dicts: shot (made/missed, location, assisted_by, blocked_by,
putback), free_throw, rebound (offensive/defensive), pass, turnover (incl. steals),
foul (best effort), screen, jump_ball, period_start/period_end.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from modal_app.pipeline.types import Perception


@dataclass
class EventConfig:
    """Thresholds (defaults tuned for high-school film at 10 analysed fps)."""


def detect_events(perception: Perception, cfg: EventConfig | None = None) -> list[dict[str, Any]]:
    """Return RawEvent dicts sorted by frame (see docs/TRACKING_SCHEMA.md for attrs).

    Requires ``possession.assign_ball_holders`` to have run first.
    """
    raise NotImplementedError
