"""Raw pipeline events -> chronological timeline, possessions and shot records."""

from __future__ import annotations

from dataclasses import dataclass, field

from scout.analysis.geometry import CourtConfig
from scout.analysis.tracking_index import TrackingIndex
from scout.schemas import (
    PlayerRef,
    Possession,
    Roster,
    ShotRecord,
    TeamSide,
    TimelineEvent,
    TrackAssignment,
    TrackingResult,
)


@dataclass
class TimelineBuild:
    timeline: list[TimelineEvent]
    possessions: list[Possession]
    shots: list[ShotRecord]
    score: dict[TeamSide, int] = field(default_factory=dict)


def player_ref(
    track_id: int | None,
    assignments: dict[int, TrackAssignment],
    rosters: dict[TeamSide, Roster],
) -> PlayerRef | None:
    """PlayerRef for a track (roster name/jersey when matched, OCR jersey otherwise)."""
    raise NotImplementedError


def build_timeline(
    tracking: TrackingResult,
    index: TrackingIndex,
    team_map: dict[int, TeamSide],
    assignments: list[TrackAssignment],
    rosters: dict[TeamSide, Roster],
    court: CourtConfig,
) -> TimelineBuild:
    """Normalise raw events into the coach-facing timeline.

    Rules (see docs/ARCHITECTURE.md "Event semantics"):
    * Sort by frame; drop events from ignored tracks / referees.
    * Event side = side of the actor's team (``team_map``); fall back to the
      track assignment's side.
    * Shots: zone/subzone/is_three from ``court`` geometry when ``shot_court_xy`` (or a
      projectable ``shot_xy_px``) is available, else the pipeline's ``is_three``; points
      = 3/2 when made. ``assisted_by_track`` -> extra ASSIST row; ``blocked_by_track`` ->
      extra BLOCK row (shot counts as missed).
    * Turnovers with ``kind == "steal"``/``stolen_by_track`` -> extra STEAL row.
    * Rebounds: offensive when ``attrs.offensive`` is True, or (when None) the rebounder's
      side equals the side of the last missed shot / FT.
    * Possessions: change on made FG (unless an and-one FT follows), last made/missed FT,
      defensive rebound, turnover, jump ball, period start; offensive rebounds continue
      the possession. Gaps are filled from ball-holder segments (``index``). Emits a
      POSSESSION_CHANGE row whenever the possession side flips.
    * Every row gets ``possession_side``/``possession_id`` and running ``score_*``.
    * ``ShotRecord.half_court_xy`` uses ``geometry.to_half_court`` for the basket attacked.
    """
    raise NotImplementedError
