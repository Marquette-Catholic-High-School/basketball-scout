"""Raw pipeline events -> chronological timeline, possessions and shot records.

Possession rules (docs/ARCHITECTURE.md "Event semantics"):

* The ball changes hands on a made FG, the last free throw of a trip when it is made,
  a defensive rebound, a turnover, a jump ball (``won_by_team``) and at period start
  (when the period-start event names a team). Offensive rebounds continue it.
* And-ones: a made FG hands the ball to the other team, but when the scoring team's
  free throw comes next -- before the other team did anything -- the flip is undone
  and the free throws belong to the scoring possession. This gives the documented
  "unless free throws follow within 3 s" result and also handles film where the
  and-one free throw comes 30 s after the basket.
* A missed last free throw does not end the possession by itself: the rebound decides.
* Gaps: a ball-holder segment of >= 2 s by the team without the ball, or a shot, free
  throw, turnover or offensive rebound by that team, starts an "inferred" possession.
* ``transition``: the possession began live (defensive rebound, steal or a live-ball
  turnover) and its first shot / free throw / turnover came within 10 s -- FastScout's
  definition (ends within 10 s, does not follow a stoppage).

The triggering event (made shot, last FT, defensive rebound, turnover + steal, jump
ball) stays in the possession it ends; the POSSESSION_CHANGE row follows it.

Shots and free throws whose ``made`` is unknown (null) count as misses with half the
event confidence, so the box score never invents points.
"""

from __future__ import annotations

import logging
import math
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any

from scout.analysis import geometry
from scout.analysis.geometry import CourtConfig
from scout.analysis.teams import side_of
from scout.analysis.tracking_index import TrackingIndex
from scout.schemas import (
    ATTR_ASSISTED_BY,
    ATTR_BALL_HANDLER,
    ATTR_BLOCKED_BY,
    ATTR_FOULED_TRACK,
    ATTR_IS_THREE,
    ATTR_KIND,
    ATTR_MADE,
    ATTR_OFFENSIVE,
    ATTR_ON_BALL,
    ATTR_PERIOD,
    ATTR_SHOT_COURT_XY,
    ATTR_SHOT_XY_PX,
    ATTR_STOLEN_BY,
    ATTR_TO_TRACK,
    ATTR_WON_BY_TEAM,
    EventType,
    PlayerRef,
    Point,
    Possession,
    PossessionOutcome,
    RawEvent,
    RawEventType,
    Roster,
    ShotRecord,
    ShotZone,
    TeamSide,
    TimelineEvent,
    TrackAssignment,
    TrackingResult,
)

logger = logging.getLogger(__name__)

MIN_HOLD_S = 2.0  # a holder segment this long by the other team starts a possession
TRANSITION_WINDOW_S = 10.0
UNKNOWN_MADE_CONF_FACTOR = 0.5  # made == null: counted as a miss, confidence halved
INFERRED_CONFIDENCE = 0.4  # possession changes we deduced rather than saw
OFF_COURT_MARGIN_FT = 6.0  # shot locations further off the floor are ignored (bad homography)
DEAD_BALL_TURNOVERS = frozenset({"travel", "out_of_bounds", "offensive_foul"})
BALL_EVENTS = frozenset(
    {
        RawEventType.SHOT,
        RawEventType.FREE_THROW,
        RawEventType.REBOUND,
        RawEventType.TURNOVER,
        RawEventType.JUMP_BALL,
        RawEventType.PERIOD_START,
        RawEventType.PERIOD_END,
    }
)
# Same-frame ordering: a period starts before anything else and ends after everything.
_TYPE_ORDER = {RawEventType.PERIOD_START: 0, RawEventType.JUMP_BALL: 1, RawEventType.PERIOD_END: 3}
DEFAULT_TEAM_NAMES = {TeamSide.SCOUTED: "Scouted team", TeamSide.OTHER: "Other team"}


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
    """PlayerRef for a track (roster name/jersey when matched, OCR jersey otherwise).

    None for unknown, ignored and referee tracks, and for tracks with no jersey at all
    (their stats go to the team line).
    """
    if track_id is None:
        return None
    a = assignments.get(track_id)
    if a is None or a.ignored or a.role == "referee":
        return None
    if a.player_id:
        sides = [a.side] if a.side is not None else list(rosters)
        for side in sides:
            roster = rosters.get(side)
            player = roster.by_id(a.player_id) if roster is not None else None
            if player is not None:
                return PlayerRef(
                    player_id=player.id,
                    jersey=player.jersey,
                    name=player.name or None,
                    side=side,
                    match_confidence=a.match_score,
                )
    jersey = a.jersey or a.best_read
    if not jersey:
        return None
    return PlayerRef(jersey=jersey, side=a.side, match_confidence=a.match_score)


def build_timeline(
    tracking: TrackingResult,
    index: TrackingIndex,
    team_map: dict[int, TeamSide],
    assignments: list[TrackAssignment],
    rosters: dict[TeamSide, Roster],
    court: CourtConfig,
) -> TimelineBuild:
    """Normalise raw events into the coach-facing timeline.

    Rules (see docs/ARCHITECTURE.md "Event semantics" and the module docstring):
    * Sort by frame; drop events from ignored tracks / referees.
    * Event side = side of the actor's team (``team_map``); fall back to the
      track assignment's side. A manual track override's side always wins.
    * Shots: zone/subzone/is_three from ``court`` geometry when ``shot_court_xy`` (or a
      projectable ``shot_xy_px``, or the shooter's court position) is available, else
      the pipeline's ``is_three``; points = 3/2 when made. ``assisted_by_track`` -> extra
      ASSIST row; ``blocked_by_track`` -> extra BLOCK row (shot counts as missed).
    * Turnovers with ``kind == "steal"``/``stolen_by_track`` -> extra STEAL row.
    * Rebounds: offensive when ``attrs.offensive`` is True, or (when None) the rebounder's
      side equals the side of the last missed shot / FT.
    * Possessions as described in the module docstring; a POSSESSION_CHANGE row
      (``poss<n>``) opens every possession.
    * Every row gets ``possession_side``/``possession_id`` and running ``score_*``.
    * ``ShotRecord.half_court_xy`` uses ``geometry.to_half_court`` for the basket attacked.
    """
    builder = _TimelineBuilder(index, team_map, assignments, rosters, court)
    return builder.run(tracking.events)


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def _other(side: TeamSide | None) -> TeamSide | None:
    if side is None:
        return None
    return TeamSide.OTHER if side == TeamSide.SCOUTED else TeamSide.SCOUTED


def _as_int(value: Any) -> int | None:
    """Track / team ids from event attrs (JSON numbers); None for anything else."""
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _as_point(value: Any) -> Point | None:
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        return None
    try:
        x, y = float(value[0]), float(value[1])
    except (TypeError, ValueError):
        return None
    return (x, y) if math.isfinite(x) and math.isfinite(y) else None


def _location_candidates(event: RawEvent, index: TrackingIndex) -> Iterator[Point | None]:
    """Shot location sources in priority order (court feet)."""
    yield _as_point(event.attrs.get(ATTR_SHOT_COURT_XY))
    px = _as_point(event.attrs.get(ATTR_SHOT_XY_PX))
    homography = index.homography_for_frame(event.frame) if px is not None else None
    if px is not None and homography is not None:
        yield geometry.apply_homography(homography.matrix, px)
    if index.coord_mode == "court" and event.track_id is not None:
        yield index.position(event.track_id, event.frame)


def shot_location(event: RawEvent, index: TrackingIndex, court: CourtConfig) -> Point | None:
    """First plausible (on or near the floor) shot location, or None."""
    for xy in _location_candidates(event, index):
        if xy is not None and geometry.on_court(court, xy, margin_ft=OFF_COURT_MARGIN_FT):
            return xy
    return None


def _readable(text: str) -> str:
    return text.replace("_", " ")


def _sort_events(events: list[RawEvent]) -> list[RawEvent]:
    order = sorted(range(len(events)), key=lambda i: (events[i].frame, _TYPE_ORDER.get(events[i].type, 2), i))
    return [events[i] for i in order]


# ---------------------------------------------------------------------------
# Possession state machine
# ---------------------------------------------------------------------------

ATTR_COMPLETED = "completed"  # pass: bool, default true (docs/TRACKING_SCHEMA.md)


@dataclass
class _Poss:
    """A possession while it is being built."""

    side: TeamSide
    start_frame: int
    start_t: float
    start_reason: str
    live_start: bool  # began from a live ball: eligible for transition
    change_row: TimelineEvent
    end_frame: int = 0
    end_t: float = 0.0
    outcome: PossessionOutcome | None = None
    pending: PossessionOutcome | None = None  # outcome if it ends without an explicit trigger
    made_fg: bool = False
    first_action_t: float | None = None  # first FGA / FTA / turnover by the team in possession
    activity: int = 0  # live events by the team in possession
    merged_into: _Poss | None = None  # set when an and-one folds this (empty) possession away
    number: int = 0

    def resolved(self) -> _Poss:
        poss = self
        while poss.merged_into is not None:
            poss = poss.merged_into
        return poss

    @property
    def transition(self) -> bool:
        return (
            self.live_start
            and self.first_action_t is not None
            and self.first_action_t - self.start_t <= TRANSITION_WINDOW_S
        )


class _TimelineBuilder:
    """Walks the sorted raw events once, emitting rows and tracking possession state."""

    def __init__(
        self,
        index: TrackingIndex,
        team_map: dict[int, TeamSide],
        assignments: list[TrackAssignment],
        rosters: dict[TeamSide, Roster],
        court: CourtConfig,
    ) -> None:
        self.index = index
        self.team_map = team_map
        self.by_track = {a.track_id: a for a in assignments}
        self.rosters = rosters
        self.court = court
        self.rows: list[tuple[TimelineEvent, _Poss | None]] = []
        self.possessions: list[_Poss] = []
        self.shots: list[ShotRecord] = []
        self.score = {TeamSide.SCOUTED: 0, TeamSide.OTHER: 0}
        self.poss: _Poss | None = None
        self.last_miss: TeamSide | None = None  # side of the last missed FG / last FT
        self.in_break = False  # between period_end and the next period_start
        self.period_pending = False  # the next possession is the first of a period
        self.last_frame = 0
        self.last_t = 0.0
        self.last_ft_ids: set[str] = set()
        min_frames = index.frames_for_seconds(MIN_HOLD_S)
        # (frame at which the segment has lasted MIN_HOLD_S, segment), in time order.
        self.segments = [(s.start_frame + min_frames, s) for s in index.holder_segments(min_frames=min_frames)]
        self.seg_i = 0
        self.handlers = {
            RawEventType.SHOT: self._shot,
            RawEventType.FREE_THROW: self._free_throw,
            RawEventType.REBOUND: self._rebound,
            RawEventType.PASS: self._pass,
            RawEventType.TURNOVER: self._turnover,
            RawEventType.FOUL: self._foul,
            RawEventType.SCREEN: self._screen,
            RawEventType.JUMP_BALL: self._jump_ball,
            RawEventType.PERIOD_START: self._period_start,
            RawEventType.PERIOD_END: self._period_end,
            RawEventType.TIMEOUT: self._timeout,
        }

    # ------------------------------------------------------------------ run
    def run(self, raw_events: list[RawEvent]) -> TimelineBuild:
        events = self._usable(raw_events)
        sides = [self._event_side(e) for e in events]
        self.last_ft_ids = _last_free_throws(events, sides)
        for e, side in zip(events, sides, strict=True):
            self._fill_from_holders(e.frame)
            self.handlers[e.type](e, side)
        self._fill_from_holders(math.inf)
        self._close()
        return self._finish()

    def _usable(self, raw_events: list[RawEvent]) -> list[RawEvent]:
        """Sorted events minus duplicates and events by ignored / referee tracks."""
        seen: set[str] = set()
        usable = []
        for e in _sort_events(raw_events):
            if e.event_id in seen:
                logger.warning("Duplicate raw event id %s ignored", e.event_id)
                continue
            seen.add(e.event_id)
            if e.track_id is not None and self._excluded(e.track_id):
                continue
            usable.append(e)
        return usable

    def _finish(self) -> TimelineBuild:
        for n, poss in enumerate(self.possessions, start=1):
            poss.number = n
            poss.change_row.id = f"poss{n}"
        event_ids: dict[int, list[str]] = {p.number: [] for p in self.possessions}
        points = dict.fromkeys(event_ids, 0)
        timeline: list[TimelineEvent] = []
        for row, owner in self.rows:
            if owner is not None and owner.merged_into is not None and row is owner.change_row:
                continue  # possession folded into an and-one: its change row never happened
            if owner is not None:
                poss = owner.resolved()
                row.possession_id, row.possession_side = poss.number, poss.side
                event_ids[poss.number].append(row.id)
                if row.side == poss.side:
                    points[poss.number] += row.points
            timeline.append(row)
        possessions = [
            Possession(
                id=p.number,
                side=p.side,
                start_t=p.start_t,
                end_t=p.end_t,
                start_frame=p.start_frame,
                end_frame=p.end_frame,
                outcome=p.outcome or PossessionOutcome.UNKNOWN,
                points=points[p.number],
                start_reason=p.start_reason,
                transition=p.transition,
                event_ids=event_ids[p.number],
            )
            for p in self.possessions
        ]
        return TimelineBuild(timeline=timeline, possessions=possessions, shots=self.shots, score=dict(self.score))

    # ------------------------------------------------------------------ lookups
    def _excluded(self, track_id: int) -> bool:
        a = self.by_track.get(track_id)
        if a is not None and (a.ignored or a.role == "referee"):
            return True
        return self.index.roles.get(track_id) == "referee"

    def _manual_side(self, track_id: int | None) -> TeamSide | None:
        a = self.by_track.get(track_id) if track_id is not None else None
        return a.side if a is not None and a.method == "manual" else None

    def _track_side(self, track_id: int) -> TeamSide | None:
        side = self._manual_side(track_id) or side_of(self.team_map, self.index.team_of(track_id))
        if side is None and (a := self.by_track.get(track_id)) is not None:
            side = a.side
        return side

    def _event_side(self, e: RawEvent) -> TeamSide | None:
        side = self._manual_side(e.track_id) or side_of(self.team_map, e.team_id)
        if side is None and e.track_id is not None:
            side = self._track_side(e.track_id)
        return side

    def _ref(self, track_id: int | None) -> PlayerRef | None:
        return player_ref(track_id, self.by_track, self.rosters)

    def _team_name(self, side: TeamSide) -> str:
        roster = self.rosters.get(side)
        return roster.team_name if roster is not None and roster.team_name else DEFAULT_TEAM_NAMES[side]

    def _who(self, ref: PlayerRef | None, side: TeamSide | None) -> str:
        if ref is not None:
            return ref.label
        return self._team_name(side) if side is not None else "Unknown player"

    # ------------------------------------------------------------------ rows & possessions
    def _new_row(
        self, e: RawEvent, type_: EventType, label: str, side: TeamSide | None, *, suffix: str = "", **fields: Any
    ) -> TimelineEvent:
        fields.setdefault("confidence", e.conf)
        return TimelineEvent(
            id=f"{e.event_id}{suffix}",
            t=e.t,
            frame=e.frame,
            type=type_,
            label=label,
            side=side,
            source_event_id=e.event_id,
            **fields,
        )

    def _add(self, row: TimelineEvent, *, live: bool = False) -> None:
        """Append a row to the current possession and stamp the running score."""
        if row.points and row.side is not None:
            self.score[row.side] += row.points
        row.score_scouted = self.score[TeamSide.SCOUTED]
        row.score_other = self.score[TeamSide.OTHER]
        if live and self.poss is not None and row.side == self.poss.side:
            self.poss.activity += 1
        self.rows.append((row, self.poss))
        self.last_frame = max(self.last_frame, row.frame)
        self.last_t = max(self.last_t, row.t)

    def _open(
        self,
        side: TeamSide,
        frame: int,
        t: float,
        reason: str,
        *,
        conf: float,
        live_start: bool = False,
        outcome: PossessionOutcome | None = None,
    ) -> _Poss:
        """Close the current possession (with ``outcome``) and start one for ``side``."""
        self._close(outcome)
        if self.period_pending and reason == "inferred":
            reason = "period_start"
        self.period_pending = False
        self.in_break = False
        frame, t = max(int(frame), self.last_frame), max(t, self.last_t)
        name = self._team_name(side)
        row = TimelineEvent(
            id="",  # numbered in _finish
            t=t,
            frame=frame,
            type=EventType.POSSESSION_CHANGE,
            label=f"Possession: {name}",
            side=side,
            confidence=conf,
            description=f"{name} ball ({_readable(reason)})",
        )
        poss = _Poss(
            side=side, start_frame=frame, start_t=t, start_reason=reason, live_start=live_start, change_row=row
        )
        self.possessions.append(poss)
        self.poss = poss
        self._add(row)
        return poss

    def _close(
        self, outcome: PossessionOutcome | None = None, *, default: PossessionOutcome = PossessionOutcome.UNKNOWN
    ) -> None:
        """End the current possession at the last row seen."""
        poss = self.poss
        if poss is None:
            return
        poss.end_frame = max(self.last_frame, poss.start_frame)
        poss.end_t = max(self.last_t, poss.start_t)
        poss.outcome = outcome or poss.pending or default
        self.poss = None

    def _ensure_possession(self, side: TeamSide | None, e: RawEvent) -> _Poss | None:
        """The team acting on the ball has it: start an inferred possession if needed."""
        if side is None:
            return None
        if self.poss is None or self.poss.side != side:
            return self._open(side, e.frame, e.t, "inferred", conf=INFERRED_CONFIDENCE)
        return self.poss

    def _resume_after_and_one(self, side: TeamSide) -> _Poss | None:
        """Free throw by the team that just scored, before the other team did anything:
        fold the empty possession away and continue the scoring one."""
        current = self.poss
        if current is None or current.activity or len(self.possessions) < 2:
            return None
        previous = self.possessions[-2]
        if previous.side != side or not previous.made_fg:
            return None
        current.merged_into = previous
        self.possessions.pop()
        previous.pending, previous.outcome = previous.outcome, None
        self.poss = previous
        return previous

    def _note_action(self, side: TeamSide | None, t: float) -> None:
        if self.poss is not None and self.poss.side == side and self.poss.first_action_t is None:
            self.poss.first_action_t = t

    def _fill_from_holders(self, up_to_frame: float) -> None:
        """Holder segments that reached MIN_HOLD_S before ``up_to_frame`` (gap filling)."""
        while self.seg_i < len(self.segments) and self.segments[self.seg_i][0] < up_to_frame:
            _, seg = self.segments[self.seg_i]
            self.seg_i += 1
            if self.in_break or self._excluded(seg.track_id):
                continue
            side = self._track_side(seg.track_id)
            if side is not None and (self.poss is None or self.poss.side != side):
                t = self.index.frame_to_t(seg.start_frame)
                self._open(side, seg.start_frame, t, "inferred", conf=INFERRED_CONFIDENCE)

    def _is_offensive(self, e: RawEvent, side: TeamSide | None) -> bool:
        flag = e.attrs.get(ATTR_OFFENSIVE)
        if isinstance(flag, bool):
            return flag
        if side is None:
            return False
        if self.last_miss is not None:
            return self.last_miss == side
        return self.poss is not None and self.poss.side == side

    # ------------------------------------------------------------------ handlers
    def _shot(self, e: RawEvent, side: TeamSide | None) -> None:
        made_attr = e.attrs.get(ATTR_MADE)
        blocker_id = _as_int(e.attrs.get(ATTR_BLOCKED_BY))
        blocked = blocker_id is not None and not self._excluded(blocker_id)
        made = made_attr is True and not blocked
        xy = shot_location(e, self.index, self.court)
        if xy is not None:
            zone, subzone = geometry.classify_shot(self.court, xy)
            three = geometry.is_three(self.court, xy)  # server geometry beats the pipeline's call
        else:
            zone, subzone, three = ShotZone.UNKNOWN, None, e.attrs.get(ATTR_IS_THREE) is True
        points = (3 if three else 2) if made else 0
        assister_id = _as_int(e.attrs.get(ATTR_ASSISTED_BY))
        assisted = made and assister_id is not None and assister_id != e.track_id and not self._excluded(assister_id)
        shooter = self._ref(e.track_id)
        assister = self._ref(assister_id) if assisted else None
        blocker = self._ref(blocker_id) if blocked else None
        block_side = (self._track_side(blocker_id) if blocker_id is not None else None) or _other(side)

        poss = self._ensure_possession(side, e)
        self._note_action(side, e.t)
        kind, result = ("3PT" if three else "2PT"), ("Make" if made else "Miss")
        text = f"{self._who(shooter, side)} {kind} {result.lower()}"
        if subzone:
            text += f" ({_readable(subzone)})"
        if assisted:
            text += f", assist {self._who(assister, side)}"
        if blocked:
            text += f", blocked by {self._who(blocker, block_side)}"
        conf = e.conf if made_attr is not None else e.conf * UNKNOWN_MADE_CONF_FACTOR
        row_type = EventType.SHOT_MADE if made else EventType.SHOT_MISSED
        self._add(
            self._new_row(
                e, row_type, f"{kind} {result}", side, player=shooter, points=points, is_three=three,
                zone=zone, subzone=subzone, court_xy=xy, confidence=conf, description=text,
            ),
            live=True,
        )
        if assisted:
            text = f"{self._who(assister, side)} assist to {self._who(shooter, side)}"
            self._add(self._new_row(e, EventType.ASSIST, "Assist", side, suffix=":ast", player=assister,
                                    secondary_player=shooter, description=text))
        if blocked:
            text = f"{self._who(blocker, block_side)} block on {self._who(shooter, side)}"
            self._add(self._new_row(e, EventType.BLOCK, "Block", block_side, suffix=":blk", player=blocker,
                                    secondary_player=shooter, description=text))
        self.shots.append(
            ShotRecord(
                event_id=e.event_id, t=e.t, side=side, player=shooter, made=made, points=points, is_three=three,
                zone=zone, subzone=subzone, court_xy=xy,
                half_court_xy=geometry.to_half_court(self.court, xy) if xy is not None else None,
                assisted=assisted, blocked=blocked,
            )
        )
        if poss is None:  # unknown team: nothing to say about possession
            return
        if made:
            poss.made_fg = True
            self.last_miss = None
            self._open(_other(side), e.frame, e.t, "made_basket", conf=e.conf, outcome=PossessionOutcome.MADE_FG)
        else:
            self.last_miss = side
            poss.pending = PossessionOutcome.MADE_FG if poss.made_fg else PossessionOutcome.MISSED_FG

    def _free_throw(self, e: RawEvent, side: TeamSide | None) -> None:
        made_attr = e.attrs.get(ATTR_MADE)
        made = made_attr is True
        poss = self.poss
        if side is not None and (poss is None or poss.side != side):
            poss = self._resume_after_and_one(side) or self._open(
                side, e.frame, e.t, "inferred", conf=INFERRED_CONFIDENCE
            )
        self._note_action(side, e.t)
        shooter = self._ref(e.track_id)
        result = "Make" if made else "Miss"
        conf = e.conf if made_attr is not None else e.conf * UNKNOWN_MADE_CONF_FACTOR
        self._add(
            self._new_row(
                e, EventType.FT_MADE if made else EventType.FT_MISSED, f"FT {result}", side, player=shooter,
                points=1 if made else 0, confidence=conf, description=f"{self._who(shooter, side)} FT {result.lower()}",
            ),
            live=True,
        )
        if side is None or poss is None or e.event_id not in self.last_ft_ids:
            return
        outcome = PossessionOutcome.MADE_FG if poss.made_fg else PossessionOutcome.FREE_THROWS
        if made:
            self.last_miss = None
            self._open(_other(side), e.frame, e.t, "made_basket", conf=e.conf, outcome=outcome)
        else:  # the rebound decides who has the ball next
            self.last_miss = side
            poss.pending = outcome

    def _rebound(self, e: RawEvent, side: TeamSide | None) -> None:
        offensive = self._is_offensive(e, side)
        if offensive:
            self._ensure_possession(side, e)
        player = self._ref(e.track_id)
        label = "Off. Rebound" if offensive else "Def. Rebound"
        self._add(
            self._new_row(e, EventType.OREB if offensive else EventType.DREB, label, side, player=player,
                          description=f"{self._who(player, side)} {label.lower()}"),
            live=True,
        )
        self.last_miss = None
        if side is not None and not offensive and (self.poss is None or self.poss.side != side):
            self._open(side, e.frame, e.t, "def_rebound", conf=e.conf, live_start=True)

    def _turnover(self, e: RawEvent, side: TeamSide | None) -> None:
        kind = str(e.attrs.get(ATTR_KIND) or "other")
        stealer_id = _as_int(e.attrs.get(ATTR_STOLEN_BY))
        if stealer_id is not None and self._excluded(stealer_id):
            stealer_id = None
        is_steal = kind == "steal" or stealer_id is not None
        loser, stealer = self._ref(e.track_id), self._ref(stealer_id)
        steal_side = (self._track_side(stealer_id) if stealer_id is not None else None) or _other(side)

        self._ensure_possession(side, e)
        self._note_action(side, e.t)
        text = f"{self._who(loser, side)} turnover"
        if kind not in ("steal", "other"):
            text += f" ({_readable(kind)})"
        if is_steal:
            text += f", stolen by {self._who(stealer, steal_side)}"
        self._add(self._new_row(e, EventType.TURNOVER, "Turnover", side, player=loser, secondary_player=stealer,
                                description=text), live=True)
        if is_steal:
            text = f"{self._who(stealer, steal_side)} steal" + (f" from {loser.label}" if loser else "")
            self._add(self._new_row(e, EventType.STEAL, "Steal", steal_side, suffix=":stl", player=stealer,
                                    secondary_player=loser, description=text))
        self.last_miss = None
        if side is not None:
            live = is_steal or kind not in DEAD_BALL_TURNOVERS
            self._open(_other(side), e.frame, e.t, "steal" if is_steal else "turnover", conf=e.conf,
                       live_start=live, outcome=PossessionOutcome.TURNOVER)

    def _foul(self, e: RawEvent, side: TeamSide | None) -> None:
        kind = e.attrs.get(ATTR_KIND)
        fouler, fouled = self._ref(e.track_id), self._ref(_as_int(e.attrs.get(ATTR_FOULED_TRACK)))
        text = f"{self._who(fouler, side)} foul"
        if kind:
            text += f" ({_readable(str(kind))})"
        if fouled is not None:
            text += f" on {fouled.label}"
        self._add(self._new_row(e, EventType.FOUL, "Foul", side, player=fouler, secondary_player=fouled,
                                description=text))

    def _screen(self, e: RawEvent, side: TeamSide | None) -> None:
        screener, handler = self._ref(e.track_id), self._ref(_as_int(e.attrs.get(ATTR_BALL_HANDLER)))
        on_ball = e.attrs.get(ATTR_ON_BALL)
        kind = "on-ball screen" if on_ball is True else "off-ball screen" if on_ball is False else "screen"
        text = f"{self._who(screener, side)} {kind}" + (f" for {handler.label}" if handler else "")
        self._add(self._new_row(e, EventType.SCREEN, "Screen", side, player=screener, secondary_player=handler,
                                description=text), live=True)

    def _pass(self, e: RawEvent, side: TeamSide | None) -> None:
        passer, receiver = self._ref(e.track_id), self._ref(_as_int(e.attrs.get(ATTR_TO_TRACK)))
        text = f"{self._who(passer, side)} pass" + (f" to {receiver.label}" if receiver else "")
        if e.attrs.get(ATTR_COMPLETED) is False:
            text += " (incomplete)"
        self._add(self._new_row(e, EventType.PASS, "Pass", side, player=passer, secondary_player=receiver,
                                description=text), live=True)

    def _jump_ball(self, e: RawEvent, side: TeamSide | None) -> None:
        winner = side_of(self.team_map, _as_int(e.attrs.get(ATTR_WON_BY_TEAM)))
        text = f"Jump ball won by {self._team_name(winner)}" if winner is not None else "Jump ball"
        self._add(self._new_row(e, EventType.JUMP_BALL, "Jump Ball", winner, description=text), live=True)
        self.last_miss = None
        if winner is not None and (self.poss is None or self.poss.side != winner):
            self._open(winner, e.frame, e.t, "jump_ball", conf=e.conf)

    def _period_start(self, e: RawEvent, side: TeamSide | None) -> None:
        self._close(default=PossessionOutcome.END_OF_PERIOD)
        label = _period_label("Start of Period", e)
        self._add(self._new_row(e, EventType.PERIOD_START, label, None, description=label))
        self.in_break = False
        self.last_miss = None
        if side is not None:  # the pipeline knows who inbounds
            self._open(side, e.frame, e.t, "period_start", conf=e.conf)
        else:
            self.period_pending = True

    def _period_end(self, e: RawEvent, side: TeamSide | None) -> None:
        label = _period_label("End of Period", e)
        self._add(self._new_row(e, EventType.PERIOD_END, label, None, description=label))
        self._close(default=PossessionOutcome.END_OF_PERIOD)
        self.in_break = True
        self.period_pending = False
        self.last_miss = None

    def _timeout(self, e: RawEvent, side: TeamSide | None) -> None:
        text = f"Timeout {self._team_name(side)}" if side is not None else "Timeout"
        self._add(self._new_row(e, EventType.TIMEOUT, "Timeout", side, description=text))


def _period_label(prefix: str, e: RawEvent) -> str:
    period = _as_int(e.attrs.get(ATTR_PERIOD))
    return f"{prefix} {period}" if period is not None else prefix


def _last_free_throws(events: list[RawEvent], sides: list[TeamSide | None]) -> set[str]:
    """Ids of free throws that end a trip: the next ball event is not another FT by the same team."""
    last: set[str] = set()
    next_ball: tuple[RawEventType, TeamSide | None] | None = None
    for e, side in zip(reversed(events), reversed(sides), strict=True):
        if e.type == RawEventType.FREE_THROW and next_ball != (RawEventType.FREE_THROW, side):
            last.add(e.event_id)
        if e.type in BALL_EVENTS:
            next_ball = (e.type, side)
    return last
