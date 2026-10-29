"""Rule-based play recognition on top of tracking data.

Offense: pick-and-roll / pick-and-pop, isolation, fast break, post-up, dribble
handoff, off-ball screen, spot-up, cut, putback. Defense: man vs zone (with zone
shape such as 2-3 / 1-3-1 / 3-2), full-court press.

All thresholds live in ``config/play_rules.yaml`` (loaded into ``PlayRules``) so
coaches can tune them without touching code.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from scout.analysis.geometry import CourtConfig
from scout.analysis.tracking_index import TrackingIndex
from scout.schemas import Play, PlayTypeSummary, Possession, TeamSide, TimelineEvent, TrackAssignment


@dataclass
class PlayRules:
    """Thresholds per detector, e.g. ``rules.get("pick_and_roll", "screen_distance_ft", 4.0)``."""

    values: dict[str, dict[str, Any]] = field(default_factory=dict)
    enabled: dict[str, bool] = field(default_factory=dict)

    def get(self, detector: str, key: str, default: Any) -> Any:
        return self.values.get(detector, {}).get(key, default)

    def is_enabled(self, detector: str) -> bool:
        return self.enabled.get(detector, True)


def load_play_rules(path: Path | str | None = None) -> PlayRules:
    """Load ``config/play_rules.yaml`` (defaults to settings.play_rules_config; missing file -> defaults)."""
    raise NotImplementedError


def detect_plays(
    index: TrackingIndex,
    timeline: list[TimelineEvent],
    possessions: list[Possession],
    assignments: list[TrackAssignment],
    team_map: dict[int, TeamSide],
    court: CourtConfig,
    rules: PlayRules,
) -> list[Play]:
    """Run every enabled detector and return plays sorted by ``start_t``.

    Each play has a stable id (``pl_<n>``), ``possession_id`` when it falls inside a
    possession, ``players`` keyed by role (``ball_handler``, ``screener``, ``post_player``,
    ``cutter``, ``shooter``, ``passer``...), an ``outcome``/``points`` taken from the
    timeline events that end the play, and a ``confidence`` lowered in pixel mode.
    """
    raise NotImplementedError


def link_plays(timeline: list[TimelineEvent], possessions: list[Possession], plays: list[Play]) -> None:
    """In place: set ``TimelineEvent.play_id`` (offensive play covering the event) and ``Possession.play_ids``."""
    raise NotImplementedError


def summarize_plays(plays: list[Play], possessions: list[Possession]) -> list[PlayTypeSummary]:
    """Per (side, play type): count, share of possessions, points, PPP, FG made/att, turnovers."""
    raise NotImplementedError
