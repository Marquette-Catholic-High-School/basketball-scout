"""Rule-based play recognition on top of tracking data.

Offense: pick-and-roll / pick-and-pop, isolation, fast break, post-up, dribble
handoff, off-ball screen, spot-up, cut, putback. Defense: man vs zone (with zone
shape such as 2-3 / 1-3-1 / 3-2), full-court press.

All thresholds live in ``config/play_rules.yaml`` (loaded into ``PlayRules``) so
coaches can tune them without touching code.

How it works
------------
Detectors run one possession at a time. For each possession a ``_Window`` samples
everyone's position at the analysis rate (court feet, or pixels converted to feet),
the ball holder and the speeds once, so every rule below is a few numpy comparisons
instead of pairwise checks on every frame of the game.

* Offensive detectors emit ``_Candidate`` plays. Their outcome/points come from the
  first timeline event that ends the action (shot, turnover, defensive foul + free
  throws). When two candidates end on the same event, ``dedupe.priority`` decides
  which one is kept (the other is listed in ``attrs["also"]``).
* Defense: one man/zone label per half-court possession, from how defenders move
  (man: copy their man's movement; zone: stay near their spots), plus a press check
  after made baskets / inbounds.
* Pixel mode (no court mapping): distances still use feet via the player-height
  ruler, detectors that need the basket location are skipped and confidence is
  multiplied by ``general.pixel_confidence_factor``.
"""

from __future__ import annotations

import copy
import logging
import math
from bisect import bisect_left, bisect_right
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from itertools import permutations
from pathlib import Path
from typing import Any, Literal

import numpy as np
import yaml

from scout.analysis.geometry import BasketSide, CourtConfig, nearest_basket
from scout.analysis.tracking_index import TrackingIndex
from scout.errors import ErrorCode, ScoutError
from scout.schemas import (
    PLAY_TYPE_LABELS,
    EventType,
    Play,
    PlayerRef,
    PlayOutcome,
    PlayType,
    PlayTypeSummary,
    Possession,
    PossessionOutcome,
    RawEvent,
    ShotZone,
    TeamSide,
    TimelineEvent,
    TrackAssignment,
)

logger = logging.getLogger(__name__)

# Built-in defaults; config/play_rules.yaml documents every key and overrides them.
DEFAULT_RULES: dict[str, dict[str, Any]] = {
    "general": {
        "pixel_confidence_factor": 0.6,
        "outcome_window_s": 3.0,
        "max_pass_flight_s": 2.0,
        "holder_gap_s": 0.3,
        "speed_window_s": 0.4,
    },
    "pick_and_roll": {
        "enabled": True,
        "screen_distance_ft": 4.0,
        "screener_max_speed_fts": 2.5,
        "min_screen_s": 0.4,
        "min_basket_distance_ft": 12.0,
        "defender_distance_ft": 6.0,
        "roll_window_s": 2.5,
        "roll_min_gain_ft": 5.0,
        "handoff_exclusion_s": 1.0,
        "confidence": 0.75,
    },
    "pick_and_pop": {"enabled": True, "pop_min_basket_distance_ft": 17.0, "confidence": 0.7},
    "handoff": {
        "enabled": True,
        "max_distance_ft": 3.0,
        "giver_max_speed_fts": 3.0,
        "max_gap_s": 0.4,
        "confidence": 0.7,
    },
    "isolation": {
        "enabled": True,
        "min_hold_s": 3.0,
        "min_basket_distance_ft": 15.0,
        "defender_distance_ft": 6.0,
        "spacing_ft": 12.0,
        "min_share": 0.7,
        "drive_min_gain_ft": 8.0,
        "shot_after_hold_s": 1.0,
        "confidence": 0.65,
    },
    "post_up": {
        "enabled": True,
        "max_basket_distance_ft": 12.0,
        "min_lane_offset_ft": 3.0,
        "max_lane_offset_ft": 10.0,
        "min_hold_s": 1.5,
        "defender_distance_ft": 4.0,
        "min_share": 0.6,
        "confidence": 0.7,
    },
    "off_ball_screen": {
        "enabled": True,
        "screen_distance_ft": 4.0,
        "screener_max_speed_fts": 2.5,
        "min_screen_s": 0.4,
        "defender_distance_ft": 6.0,
        "receive_within_s": 2.0,
        "confidence": 0.6,
    },
    "spot_up": {"enabled": True, "max_catch_to_shot_s": 1.5, "max_move_ft": 4.0, "confidence": 0.7},
    "cut": {"enabled": True, "min_speed_fts": 10.0, "lookback_s": 1.0, "confidence": 0.6},
    "putback": {"enabled": True, "max_rebound_to_shot_s": 2.0, "max_basket_distance_ft": 10.0, "confidence": 0.8},
    "fast_break": {
        "enabled": True,
        "start_reasons": ["def_rebound", "steal", "turnover"],
        "shot_within_s": 8.0,
        "cross_half_within_s": 5.0,
        "ahead_margin_ft": 3.0,
        "count_turnovers": False,
        "confidence": 0.75,
    },
    "defense": {
        "settle_s": 1.5,
        "min_window_s": 4.0,
        "sample_hz": 2.0,
        "min_move_ft": 1.5,
        "man_min_follow": 0.5,
        "zone_max_follow": 0.3,
        "zone_max_anchor_ratio": 0.6,
        "pixel_skip_s": 5.0,
        "set_speed_fts": 7.0,
        "confidence": 0.7,
    },
    "man_defense": {"enabled": True},
    "zone_defense": {
        "enabled": True,
        "max_template_error_ft": 5.0,
        "templates": {
            "2-3": [[22, 17], [22, 33], [9, 9], [9, 41], [6, 25]],
            "3-2": [[24, 25], [19, 10], [19, 40], [8, 17], [8, 33]],
            "1-3-1": [[28, 25], [18, 9], [16, 25], [18, 41], [5, 25]],
            "1-2-2": [[28, 25], [20, 14], [20, 36], [8, 15], [8, 35]],
        },
    },
    "press": {
        "enabled": True,
        "start_reasons": [
            "made_basket", "made_ft", "free_throws", "free_throw",
            "inbound", "out_of_bounds", "period_start", "timeout",
        ],
        "min_delay_s": 1.0,
        "pickup_within_s": 3.0,
        "min_defenders": 2,
        "pickup_distance_ft": 8.0,
        "backcourt_margin_ft": 2.0,
        "min_hold_s": 1.0,
        "trap_distance_ft": 6.0,
        "confidence": 0.7,
    },
    "dedupe": {
        "priority": [
            "fast_break", "putback", "pick_and_roll", "pick_and_pop", "handoff",
            "off_ball_screen", "post_up", "isolation", "cut", "spot_up",
        ],
    },
}

_YAML_HINT = (
    "Fix the setting in config/play_rules.yaml (or delete the line to use the built-in default) "
    "and re-run the analysis."
)


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
    """Load ``config/play_rules.yaml`` (defaults to settings.play_rules_config; missing file -> defaults).

    The file is merged over ``DEFAULT_RULES`` key by key, so a file that changes one
    threshold keeps every other default. ``enabled`` keys become ``PlayRules.enabled``.
    Unknown sections/keys are ignored with a warning; wrong value types raise
    ``ScoutError(CONFIG_INVALID)`` naming the offending key.
    """
    if path is None:
        from scout.config import get_settings

        path = get_settings().play_rules_config
    values = copy.deepcopy(DEFAULT_RULES)
    for section, overrides in _read_rules_file(Path(path)).items():
        if section not in values:
            logger.warning("play_rules.yaml: unknown section %r ignored", section)
            continue
        if not isinstance(overrides, dict):
            message = f"play_rules.yaml: '{section}' must contain settings."
            raise ScoutError(ErrorCode.CONFIG_INVALID, message, hint=_YAML_HINT, retryable=False)
        for key, value in overrides.items():
            if key not in values[section]:
                logger.warning("play_rules.yaml: unknown setting %s.%s ignored", section, key)
                continue
            values[section][key] = _coerce(section, key, value, values[section][key])
    _check_templates(values["zone_defense"]["templates"])
    enabled = {name: bool(section.pop("enabled")) for name, section in values.items() if "enabled" in section}
    return PlayRules(values=values, enabled=enabled)


def _check_templates(templates: dict[str, Any]) -> None:
    """Each zone template is a list of [feet from baseline, feet from the left sideline] spots."""
    for name, spots in templates.items():
        points = spots if isinstance(spots, list) else []
        ok = bool(points) and all(
            isinstance(p, list) and len(p) == 2 and all(isinstance(v, (int, float)) for v in p) for p in points
        )
        if not ok:
            message = f"play_rules.yaml: zone template {name!r} must be a list of [x, y] spots in feet."
            raise ScoutError(ErrorCode.CONFIG_INVALID, message, hint=_YAML_HINT, retryable=False)


def _read_rules_file(path: Path) -> dict[str, Any]:
    if not path.exists():
        logger.info("No play rules file at %s; using built-in defaults", path)
        return {}
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        raise ScoutError(
            ErrorCode.CONFIG_INVALID,
            f"config/play_rules.yaml could not be read: {exc}",
            hint="Fix the YAML (indentation, colons) or delete the file to use the built-in defaults.",
            retryable=False,
        ) from exc
    if not isinstance(data, dict):
        message = "config/play_rules.yaml must be a list of sections."
        raise ScoutError(ErrorCode.CONFIG_INVALID, message, hint=_YAML_HINT, retryable=False)
    return data


def _coerce(section: str, key: str, value: Any, default: Any) -> Any:
    """Check a YAML value against the default's type (numbers may be ints or floats)."""
    if isinstance(default, bool):
        ok = isinstance(value, bool)
    elif isinstance(default, (int, float)):
        ok = isinstance(value, (int, float)) and not isinstance(value, bool)
        value = float(value) if ok and isinstance(default, float) else value
    else:
        ok = isinstance(value, type(default))
    if not ok:
        raise ScoutError(
            ErrorCode.CONFIG_INVALID,
            f"play_rules.yaml: {section}.{key} should be like {default!r}, got {value!r}.",
            hint=_YAML_HINT,
            retryable=False,
        )
    return value


# ---------------------------------------------------------------------------
# Shared context
# ---------------------------------------------------------------------------

_SHOTS = frozenset({EventType.SHOT_MADE, EventType.SHOT_MISSED})
# Timeline rows whose ``player`` is the raw event's primary actor (``RawEvent.track_id``).
_PRIMARY_ROWS = _SHOTS | {
    EventType.FT_MADE, EventType.FT_MISSED, EventType.OREB, EventType.DREB, EventType.TURNOVER,
    EventType.FOUL, EventType.PASS, EventType.SCREEN,
}


@dataclass
class _Ctx:
    """Everything the detectors share for one game."""

    index: TrackingIndex
    court: CourtConfig
    rules: PlayRules
    rows: list[TimelineEvent]  # sorted by frame
    sides: dict[int, TeamSide]  # player track -> side (referees / ignored tracks left out)
    refs: dict[int, PlayerRef]
    raw: dict[str, RawEvent]
    has_court: bool
    row_frames: list[int] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.row_frames = [r.frame for r in self.rows]

    def rule(self, section: str, key: str) -> Any:
        return self.rules.get(section, key, DEFAULT_RULES[section][key])

    @property
    def dt(self) -> float:
        return self.index.step / self.index.fps

    def samples(self, seconds: float) -> int:
        """Number of analysis samples covering ``seconds`` (at least 1)."""
        return max(1, int(round(seconds / self.dt)))

    def rows_between(self, f0: int, f1: int) -> list[TimelineEvent]:
        return self.rows[bisect_left(self.row_frames, f0) : bisect_right(self.row_frames, f1)]

    def actor(self, row: TimelineEvent) -> int | None:
        """Track id of the row's primary actor (shooter, rebounder...)."""
        raw = self.raw.get(row.source_event_id or "")
        if raw is not None and row.type in _PRIMARY_ROWS:
            return raw.track_id
        holder = self.index.holder_at(row.frame - self.index.step)  # no raw event: who had the ball
        return holder if holder is not None and self.sides.get(holder) == row.side else None

    def ref(self, track_id: int | None) -> PlayerRef | None:
        if track_id is None:
            return None
        return self.refs.get(track_id) or PlayerRef(side=self.sides.get(track_id))


def _track_sides(
    index: TrackingIndex, team_map: dict[int, TeamSide], assignments: list[TrackAssignment]
) -> dict[int, TeamSide]:
    by_track = {a.track_id: a for a in assignments}
    sides: dict[int, TeamSide] = {}
    for tid in index.track_ids("player"):
        a = by_track.get(tid)
        if a is not None and (a.ignored or a.role == "referee"):
            continue
        side = (a.side if a is not None else None) or team_map.get(index.team_of(tid))  # type: ignore[arg-type]
        if side is not None:
            sides[tid] = side
    return sides


def _player_refs(
    rows: list[TimelineEvent], raw: dict[str, RawEvent], assignments: list[TrackAssignment]
) -> dict[int, PlayerRef]:
    """Track -> PlayerRef: the timeline's refs (roster names) where available, else the assignment."""
    refs = {
        a.track_id: PlayerRef(player_id=a.player_id, jersey=a.jersey, side=a.side, match_confidence=a.match_score)
        for a in assignments
        if not a.ignored
    }
    for row in rows:
        ev = raw.get(row.source_event_id or "")
        if ev is not None and ev.track_id is not None and row.player is not None and row.type in _PRIMARY_ROWS:
            refs[ev.track_id] = row.player
    return refs


def _possession_baskets(ctx: _Ctx, possessions: list[Possession]) -> dict[int, BasketSide]:
    """Basket each possession attacks, from shot locations.

    A possession's own shot decides; otherwise the nearest (in time) shots by the same
    side in the same period vote, since teams only switch baskets between periods.
    """
    period_starts = sorted(r.t for r in ctx.rows if r.type == EventType.PERIOD_START)
    shots: dict[tuple[int, TeamSide], list[tuple[float, BasketSide]]] = defaultdict(list)
    for r in ctx.rows:
        if r.type in _SHOTS and r.side is not None and r.court_xy is not None:
            shots[(bisect_right(period_starts, r.t), r.side)].append((r.t, nearest_basket(ctx.court, r.court_xy)))
    out: dict[int, BasketSide] = {}
    for p in possessions:
        if p.side is None:
            continue
        candidates = shots.get((bisect_right(period_starts, p.start_t), p.side), [])
        own = [b for t, b in candidates if p.start_t <= t <= p.end_t]
        if own:
            out[p.id] = own[0]
            continue
        mid = (p.start_t + p.end_t) / 2
        nearest = sorted(candidates, key=lambda tb: abs(tb[0] - mid))[:3]
        if nearest:
            out[p.id] = Counter(b for _, b in nearest).most_common(1)[0][0]
    return out


def _first_run(mask: np.ndarray, min_len: int) -> tuple[int, int] | None:
    """First run of True values at least ``min_len`` long, as inclusive (start, end)."""
    start = None
    for i, value in enumerate(mask.tolist()):
        if value and start is None:
            start = i
        elif not value and start is not None:
            if i - start >= min_len:
                return start, i - 1
            start = None
    if start is not None and len(mask) - start >= min_len:
        return start, len(mask) - 1
    return None


def _lateral(court: CourtConfig, hy: float) -> Literal["left", "middle", "right"]:
    """Which part of the floor, from the offense's view (``hy`` = half-court feet)."""
    if hy < court.mid_y - court.lane_width_ft / 2:
        return "left"
    if hy > court.mid_y + court.lane_width_ft / 2:
        return "right"
    return "middle"


# ---------------------------------------------------------------------------
# Per-possession window
# ---------------------------------------------------------------------------


@dataclass
class _Hold:
    """One player's uninterrupted control of the ball, in window sample indices."""

    track_id: int
    side: TeamSide
    k0: int
    k1: int
    prev: _Hold | None = None  # previous hold in the window (any team)


@dataclass
class _Finish:
    """The timeline event that ended an action."""

    outcome: PlayOutcome = PlayOutcome.NO_SHOT
    points: int = 0
    frame: int | None = None
    shooter: int | None = None
    row: TimelineEvent | None = None  # the shot / turnover / foul row (None: no event ended it)


class _Window:
    """Sampled positions, speeds and ball holders of everyone during one possession."""

    def __init__(
        self, ctx: _Ctx, possession: Possession, side: TeamSide, basket: BasketSide | None, possession_id: int | None
    ) -> None:
        idx = ctx.index
        self.ctx = ctx
        self.possession = possession
        self.possession_id = possession_id
        self.side = side
        self.start_frame, self.end_frame = possession.start_frame, possession.end_frame
        self.frames = np.asarray(idx.sample_frames(self.start_frame, self.end_frame), dtype=np.int64)
        n = len(self.frames)
        frames = self.frames.tolist()
        self.pos: dict[int, np.ndarray] = {}
        self.scale: dict[int, float] = {}
        for tid in ctx.sides:
            span = idx.track_span(tid)
            if span is None or span[1] < self.start_frame or span[0] > self.end_frame:
                continue
            arr = np.full((n, 2), np.nan)
            for k, f in enumerate(frames):
                p = idx.position(tid, f)
                if p is not None:
                    arr[k] = p
            if np.isfinite(arr[:, 0]).any():
                self.pos[tid] = arr
                self.scale[tid] = idx.scale_ft(tid, (self.start_frame + self.end_frame) // 2)
        self.offense = [t for t in self.pos if ctx.sides[t] == side]
        self.defense = [t for t in self.pos if ctx.sides[t] != side]
        self.holder = np.asarray([h if (h := idx.holder_at(f)) is not None else -1 for f in frames], dtype=np.int64)
        ball = [idx.ball_xy(f) for f in frames]
        self.ball = np.asarray([b if b is not None else (np.nan, np.nan) for b in ball], dtype=float).reshape(n, 2)
        self.basket = basket if ctx.has_court else None
        if self.basket is None and ctx.has_court:
            self.basket = self._centroid_basket()
        self.holds = self._find_holds()
        self._cache: dict[tuple[Any, ...], np.ndarray] = {}

    # ------------------------------------------------------------- basics
    @property
    def n(self) -> int:
        return len(self.frames)

    @property
    def has_basket(self) -> bool:
        return self.basket is not None

    def frame(self, k: int) -> int:
        return int(self.frames[min(max(k, 0), self.n - 1)])

    def k_of(self, frame: int) -> int:
        return int(min(max(np.searchsorted(self.frames, frame), 0), self.n - 1))

    def _centroid_basket(self) -> BasketSide | None:
        """Fallback when no shot tells us: the half where the offense spends the second half of the possession."""
        late = [self.pos[t][self.n // 2 :, 0] for t in self.offense]
        xs = np.concatenate(late) if late else np.array([])
        xs = xs[np.isfinite(xs)]
        return nearest_basket(self.ctx.court, (float(np.mean(xs)), self.ctx.court.mid_y)) if len(xs) else None

    def _find_holds(self) -> list[_Hold]:
        gap = self.ctx.samples(self.ctx.rule("general", "holder_gap_s"))
        holds: list[_Hold] = []
        for k, h in enumerate(self.holder.tolist()):
            side = self.ctx.sides.get(h)
            if side is None:
                continue
            last = holds[-1] if holds else None
            if last is not None and last.track_id == h and k - last.k1 <= gap + 1:
                last.k1 = k
            else:
                holds.append(_Hold(h, side, k, k, prev=last))
        return holds

    def is_catch(self, hold: _Hold) -> bool:
        """The hold started with a pass from a teammate."""
        prev = hold.prev
        return (
            prev is not None
            and prev.side == hold.side
            and prev.track_id != hold.track_id
            and (hold.k0 - prev.k1) * self.ctx.dt <= self.ctx.rule("general", "max_pass_flight_s")
        )

    def offense_holds(self) -> list[_Hold]:
        return [h for h in self.holds if h.side == self.side and h.track_id in self.pos]

    # ------------------------------------------------------------- geometry
    def dist(self, a: int, b: int) -> np.ndarray:
        """Feet between two tracks at every sample (NaN where unknown)."""
        key = ("d", min(a, b), max(a, b))
        if key not in self._cache:
            pa, pb = self.pos[a], self.pos[b]
            scale = (self.scale[a] + self.scale[b]) / 2
            self._cache[key] = np.hypot(pa[:, 0] - pb[:, 0], pa[:, 1] - pb[:, 1]) * scale
        return self._cache[key]

    def nearest(self, tid: int, others: list[int]) -> np.ndarray:
        """Distance to the nearest of ``others`` at every sample."""
        others = [o for o in others if o != tid]
        if not others:
            return np.full(self.n, np.nan)
        return np.fmin.reduce(np.vstack([self.dist(tid, o) for o in others]), axis=0)

    def speed(self, tid: int) -> np.ndarray:
        """Feet per second, central difference over ``general.speed_window_s``."""
        key = ("v", tid)
        if key not in self._cache:
            h = max(1, self.ctx.samples(self.ctx.rule("general", "speed_window_s")) // 2)
            p = np.pad(self.pos[tid], ((h, h), (0, 0)), mode="edge")
            step = p[2 * h :] - p[: -2 * h]
            self._cache[key] = np.hypot(step[:, 0], step[:, 1]) * self.scale[tid] / (2 * h * self.ctx.dt)
        return self._cache[key]

    def half(self, tid: int | None) -> np.ndarray:
        """Half-court coordinates (feet from the attacked baseline, feet from the offense's left)."""
        key = ("h", tid)
        if key not in self._cache:
            self._cache[key] = self._to_half(self.ball_xy() if tid is None else self.pos[tid])
        return self._cache[key]

    def basket_dist(self, tid: int) -> np.ndarray:
        key = ("b", tid)
        if key not in self._cache:
            h = self.half(tid)
            c = self.ctx.court
            self._cache[key] = np.hypot(h[:, 0] - c.basket_from_baseline_ft, h[:, 1] - c.mid_y)
        return self._cache[key]

    def _to_half(self, xy: np.ndarray) -> np.ndarray:
        if self.basket == "left":
            return xy.copy()
        c = self.ctx.court
        return np.column_stack([c.length_ft - xy[:, 0], c.width_ft - xy[:, 1]])

    def ball_xy(self) -> np.ndarray:
        """Ball position, falling back to the holder's position when the ball was not seen."""
        out = self.ball.copy()
        for k in np.flatnonzero(~np.isfinite(out[:, 0])).tolist():
            h = int(self.holder[k])
            if h in self.pos:
                out[k] = self.pos[h][k]
        return out

    def in_paint(self, hxy: np.ndarray | tuple[float, float]) -> bool:
        c = self.ctx.court
        return bool(0 <= hxy[0] <= c.ft_line_from_baseline_ft and abs(hxy[1] - c.mid_y) <= c.lane_width_ft / 2)

    # ------------------------------------------------------------- events
    def rows(self, types: frozenset[EventType] | set[EventType], side: TeamSide | None = None) -> list[TimelineEvent]:
        side = side or self.side
        rows = self.ctx.rows_between(self.start_frame, self.end_frame)
        return [r for r in rows if r.type in types and r.side == side]

    def finish(self, f_from: int, f_until: int) -> _Finish:
        """First shot / turnover / defensive foul by this possession between the two frames."""
        rows = self.ctx.rows_between(f_from, min(f_until, self.end_frame))
        for i, row in enumerate(rows):
            if self._ends_action(row):
                if row.type == EventType.FOUL:  # shooting foul: prefer the shot logged at the same moment
                    late = row.frame + self.ctx.index.frames_for_seconds(0.5)
                    same_time = (r for r in rows[i:] if r.type in _SHOTS and r.side == self.side and r.frame <= late)
                    row = next(same_time, row)
                return self.finish_at(row)
        return _Finish()

    def _ends_action(self, row: TimelineEvent) -> bool:
        if row.type in _SHOTS or row.type == EventType.TURNOVER:
            return row.side == self.side
        return row.type == EventType.FOUL and row.side is not None and row.side != self.side

    def finish_at(self, row: TimelineEvent) -> _Finish:
        """Outcome and points of an action that ended with ``row`` (free throws included)."""
        if row.type in _SHOTS:
            made = row.type == EventType.SHOT_MADE
            outcome = PlayOutcome.MADE_FG if made else PlayOutcome.MISSED_FG
            points = row.points if made else 0
        else:
            outcome = PlayOutcome.TURNOVER if row.type == EventType.TURNOVER else PlayOutcome.FOUL
            points = 0
        if outcome != PlayOutcome.TURNOVER:
            points += self._free_throw_points(row)
        shooter = self.ctx.actor(row) if row.type in _SHOTS else None
        return _Finish(outcome, points, row.frame, shooter, row)

    def _free_throw_points(self, after: TimelineEvent) -> int:
        points = 0
        for row in self.ctx.rows_between(after.frame, self.end_frame):
            if row is after or row.side != self.side:
                continue
            if row.frame > after.frame and (row.type in _SHOTS or row.type == EventType.TURNOVER):
                break
            if row.type == EventType.FT_MADE:
                points += row.points or 1
        return points


# ---------------------------------------------------------------------------
# Offensive detectors (one possession window at a time)
# ---------------------------------------------------------------------------


@dataclass
class _Candidate:
    """A detected play before de-duplication; ``k0``/``k1`` are window sample indices."""

    type: PlayType
    window: _Window
    k0: int
    k1: int
    players: dict[str, int | None]
    confidence: float
    attrs: dict[str, Any] = field(default_factory=dict)
    category: Literal["offense", "defense"] = "offense"
    side: TeamSide | None = None  # defaults to the possession's offense
    end_row: TimelineEvent | None = None  # the shot that ends it, when the detector knows it
    finish: _Finish | None = None


def _finite_min(values: np.ndarray) -> float:
    known = values[np.isfinite(values)]
    return float(known.min()) if len(known) else math.nan


def _finite_mean(values: np.ndarray) -> float:
    known = values[np.isfinite(values)]
    return float(known.mean()) if len(known) else math.nan


def _last_run(mask: np.ndarray, min_len: int) -> tuple[int, int] | None:
    run = _first_run(mask[::-1], min_len)
    return None if run is None else (len(mask) - 1 - run[1], len(mask) - 1 - run[0])


def _shot_by(w: _Window, track_id: int, f0: int, f1: int) -> TimelineEvent | None:
    rows = w.ctx.rows_between(f0, min(f1, w.end_frame))
    return next((r for r in rows if r.type in _SHOTS and r.side == w.side and w.ctx.actor(r) == track_id), None)


def _ball_screens(w: _Window) -> list[_Candidate]:
    """Pick-and-roll / pick-and-pop: a nearly stationary teammate right next to the ball handler."""
    ctx, rule = w.ctx, "pick_and_roll"
    if not w.has_basket:
        return []
    n_min = ctx.samples(ctx.rule(rule, "min_screen_s"))
    out: list[_Candidate] = []
    for hold in w.offense_holds():
        if hold.k1 - hold.k0 + 1 < n_min:
            continue
        handler, sl = hold.track_id, slice(hold.k0, hold.k1 + 1)
        for screener in w.offense:
            if screener == handler:
                continue
            close = w.dist(handler, screener)[sl] <= ctx.rule(rule, "screen_distance_ft")
            still = w.speed(screener)[sl] <= ctx.rule(rule, "screener_max_speed_fts")
            run = _first_run(close & still, n_min)
            if run is None:
                continue
            r0, r1 = hold.k0 + run[0], hold.k0 + run[1]
            prev = hold.prev
            just_handed_off = prev is not None and prev.track_id == screener
            if just_handed_off and (r0 - prev.k1) * ctx.dt <= ctx.rule(rule, "handoff_exclusion_s"):
                continue  # the "screener" just handed the ball off: that is a handoff
            km = (r0 + r1) // 2
            if not w.basket_dist(screener)[km] >= ctx.rule(rule, "min_basket_distance_ft"):
                continue
            if not w.nearest(handler, w.defense)[km] <= ctx.rule(rule, "defender_distance_ft"):
                continue
            out.append(_screen_candidate(w, handler, screener, r0, r1))
    return out


def _screen_candidate(w: _Window, handler: int, screener: int, r0: int, r1: int) -> _Candidate:
    """Roll (screener heads to the basket), pop (ends on the perimeter) or short roll."""
    ctx, rule = w.ctx, "pick_and_roll"
    k_end = min(w.n - 1, r1 + ctx.samples(ctx.rule(rule, "roll_window_s")))
    ended = w.finish(w.frame(r0), w.frame(k_end))
    if ended.frame is not None:  # what the screener does after the shot / foul is not part of the action
        k_end = max(r1, w.k_of(ended.frame))
    after = w.basket_dist(screener)[r1 : k_end + 1]
    known = after[np.isfinite(after)]
    gain = float(known[0] - known.min()) if len(known) else 0.0
    final = float(known[-1]) if len(known) else math.nan
    if gain >= ctx.rule(rule, "roll_min_gain_ft"):
        play_type, how = PlayType.PICK_AND_ROLL, "roll"
    elif final >= ctx.rule("pick_and_pop", "pop_min_basket_distance_ft"):
        play_type, how = PlayType.PICK_AND_POP, "pop"
    else:
        play_type, how = PlayType.PICK_AND_ROLL, "short_roll"
    hs, hh = w.half(screener), w.half(handler)
    km = (r0 + r1) // 2
    move = float(hh[k_end, 1] - hh[r1, 1])
    direction = ("left" if move < 0 else "right") if abs(move) >= 3.0 else "straight"
    confidence = ctx.rule(play_type.value, "confidence") * (0.85 if how == "short_roll" else 1.0)
    attrs = {
        "screen_side": "left" if hs[km, 1] < hh[km, 1] else "right",
        "location": _lateral(ctx.court, float(hh[km, 1])),
        "handler_direction": direction,
        "roll_or_pop": how,
    }
    players: dict[str, int | None] = {"ball_handler": handler, "screener": screener}
    return _Candidate(play_type, w, max(0, r0 - ctx.samples(1.0)), k_end, players, confidence, attrs)


def _handoffs(w: _Window) -> list[_Candidate]:
    """Dribble handoff: the ball goes hand to hand between teammates with the giver standing still."""
    ctx, rule = w.ctx, "handoff"
    out: list[_Candidate] = []
    for hold in w.offense_holds():
        prev = hold.prev
        if prev is None or prev.side != w.side or prev.track_id == hold.track_id or prev.track_id not in w.pos:
            continue
        if (hold.k0 - prev.k1) * ctx.dt > ctx.rule(rule, "max_gap_s"):
            continue
        giver, receiver = prev.track_id, hold.track_id
        if not _finite_min(w.dist(giver, receiver)[prev.k1 : hold.k0 + 1]) <= ctx.rule(rule, "max_distance_ft"):
            continue
        k_look = max(prev.k0, prev.k1 - ctx.samples(0.5))
        if not _finite_mean(w.speed(giver)[k_look : prev.k1 + 1]) <= ctx.rule(rule, "giver_max_speed_fts"):
            continue
        attrs = {"location": _lateral(ctx.court, float(w.half(giver)[prev.k1, 1]))} if w.has_basket else {}
        players: dict[str, int | None] = {"ball_handler": receiver, "passer": giver}
        k0 = max(prev.k0, prev.k1 - ctx.samples(1.0))
        out.append(_Candidate(PlayType.HANDOFF, w, k0, hold.k0, players, ctx.rule(rule, "confidence"), attrs))
    return out


def _isolations(w: _Window) -> list[_Candidate]:
    """One-on-one: a long hold on the perimeter, one defender close, teammates spaced away."""
    ctx, rule = w.ctx, "isolation"
    if not w.has_basket or not w.defense:
        return []
    out: list[_Candidate] = []
    for hold in w.offense_holds():
        if (hold.k1 - hold.k0 + 1) * ctx.dt < ctx.rule(rule, "min_hold_s"):
            continue
        handler, sl = hold.track_id, slice(hold.k0, hold.k1 + 1)
        to_basket = w.basket_dist(handler)[sl]
        if not to_basket[0] >= ctx.rule(rule, "min_basket_distance_ft"):
            continue
        gaps = np.vstack([w.dist(handler, d)[sl] for d in w.defense])
        guarded = gaps <= ctx.rule(rule, "defender_distance_ft")
        mates = w.nearest(handler, w.offense)[sl]
        share = ctx.rule(rule, "min_share")
        if (guarded.sum(axis=0) == 1).mean() < share or (mates > ctx.rule(rule, "spacing_ft")).mean() < share:
            continue
        if np.any(mates <= ctx.rule("pick_and_roll", "screen_distance_ft")):
            continue  # someone came to screen: not an isolation
        drive = to_basket[0] - _finite_min(to_basket) >= ctx.rule(rule, "drive_min_gain_ft")
        f_shot = w.frame(hold.k1) + ctx.index.frames_for_seconds(ctx.rule(rule, "shot_after_hold_s"))
        shot = _shot_by(w, handler, w.frame(hold.k0), f_shot)
        if not drive and shot is None:
            continue
        defender = w.defense[int(np.argmax(guarded.sum(axis=1)))]
        location = _lateral(ctx.court, float(w.half(handler)[hold.k0, 1]))
        attrs = {"location": location, "finish": "drive" if drive else "jumper"}
        players: dict[str, int | None] = {"ball_handler": handler, "defender": defender}
        confidence = ctx.rule(rule, "confidence")
        out.append(_Candidate(PlayType.ISOLATION, w, hold.k0, hold.k1, players, confidence, attrs, end_row=shot))
    return out


def _post_ups(w: _Window) -> list[_Candidate]:
    """Catch on the block / lane line close to the basket, held with a defender on the back."""
    ctx, rule, court = w.ctx, "post_up", w.ctx.court
    if not w.has_basket or not w.defense:
        return []
    out: list[_Candidate] = []
    for hold in w.offense_holds():
        if not w.is_catch(hold) or (hold.k1 - hold.k0 + 1) * ctx.dt < ctx.rule(rule, "min_hold_s"):
            continue
        post = hold.track_id
        to_basket = float(w.basket_dist(post)[hold.k0])
        offset = abs(float(w.half(post)[hold.k0, 1]) - court.mid_y)
        if not court.restricted_radius_ft < to_basket <= ctx.rule(rule, "max_basket_distance_ft"):
            continue
        if not ctx.rule(rule, "min_lane_offset_ft") <= offset <= ctx.rule(rule, "max_lane_offset_ft"):
            continue
        sl = slice(hold.k0, hold.k1 + 1)
        guarded = w.nearest(post, w.defense)[sl] <= ctx.rule(rule, "defender_distance_ft")
        if guarded.mean() < ctx.rule(rule, "min_share"):
            continue
        defender = min(w.defense, key=lambda d: np.nan_to_num(_finite_mean(w.dist(post, d)[sl]), nan=1e9))
        side = "left" if float(w.half(post)[hold.k0, 1]) < court.mid_y else "right"
        passer = hold.prev.track_id if hold.prev else None
        players: dict[str, int | None] = {"post_player": post, "passer": passer, "defender": defender}
        k0 = max(0, hold.k0 - ctx.samples(0.5))
        out.append(_Candidate(PlayType.POST_UP, w, k0, hold.k1, players, ctx.rule(rule, "confidence"), {"block": side}))
    return out


def _off_ball_screens(w: _Window) -> list[_Candidate]:
    """A stationary teammate next to a guarded player without the ball, who then catches a pass."""
    ctx, rule = w.ctx, "off_ball_screen"
    n_min = ctx.samples(ctx.rule(rule, "min_screen_s"))
    n_recv = ctx.samples(ctx.rule(rule, "receive_within_s"))
    out: list[_Candidate] = []
    for hold in w.offense_holds():
        if not w.is_catch(hold) or hold.prev is None:
            continue
        receiver, passer = hold.track_id, hold.prev.track_id
        lo = max(0, hold.k0 - n_recv - ctx.samples(1.5))
        sl = slice(lo, hold.k0 + 1)
        guarded = w.nearest(receiver, w.defense)[sl] <= ctx.rule(rule, "defender_distance_ft")
        for screener in w.offense:
            if screener in (receiver, passer):
                continue
            close = w.dist(screener, receiver)[sl] <= ctx.rule(rule, "screen_distance_ft")
            still = w.speed(screener)[sl] <= ctx.rule(rule, "screener_max_speed_fts")
            run = _last_run(guarded & close & still, n_min)
            if run is None or lo + run[1] < hold.k0 - n_recv:
                continue
            players: dict[str, int | None] = {"screener": screener, "receiver": receiver, "passer": passer}
            confidence = ctx.rule(rule, "confidence")
            out.append(_Candidate(PlayType.OFF_BALL_SCREEN, w, lo + run[0], hold.k0, players, confidence))
            break
    return out


def _spot_ups(w: _Window) -> list[_Candidate]:
    """Catch-and-shoot outside the paint without moving much."""
    ctx, rule = w.ctx, "spot_up"
    out: list[_Candidate] = []
    for row in w.rows(_SHOTS):
        shooter = ctx.actor(row)
        if shooter is None or shooter not in w.pos:
            continue
        k_shot = w.k_of(row.frame)
        hold = next(
            (h for h in reversed(w.holds) if h.track_id == shooter and h.k0 <= k_shot <= h.k1 + ctx.samples(0.5)), None
        )
        if hold is None or not w.is_catch(hold) or hold.prev is None:
            continue
        if (k_shot - hold.k0) * ctx.dt > ctx.rule(rule, "max_catch_to_shot_s"):
            continue
        if not _outside_paint(w, row, shooter, k_shot):
            continue
        path = w.pos[shooter]
        moved = float(np.hypot(*(path[k_shot] - path[hold.k0]))) * w.scale[shooter]
        if not moved <= ctx.rule(rule, "max_move_ft"):
            continue
        players: dict[str, int | None] = {"shooter": shooter, "passer": hold.prev.track_id}
        attrs = {"zone": row.zone.value} if row.zone else {}
        k0 = max(0, hold.k0 - ctx.samples(0.5))
        confidence = ctx.rule(rule, "confidence")
        out.append(_Candidate(PlayType.SPOT_UP, w, k0, k_shot, players, confidence, attrs, end_row=row))
    return out


def _outside_paint(w: _Window, row: TimelineEvent, shooter: int, k: int) -> bool:
    """Shot zone from the timeline when known, else court geometry, else the three-point flag."""
    if row.zone not in (None, ShotZone.UNKNOWN):
        return row.zone != ShotZone.PAINT
    if w.has_basket:
        spot = w.half(shooter)[k]
        return bool(np.isfinite(spot).all()) and not w.in_paint(spot)
    return row.is_three is True


def _cuts(w: _Window) -> list[_Candidate]:
    """Receiver sprinted toward the basket in the second before catching in the paint."""
    ctx, rule = w.ctx, "cut"
    if not w.has_basket:
        return []
    n_back = ctx.samples(ctx.rule(rule, "lookback_s"))
    out: list[_Candidate] = []
    for hold in w.offense_holds():
        if not w.is_catch(hold) or hold.prev is None or hold.k0 < n_back:
            continue
        cutter = hold.track_id
        if not w.in_paint(w.half(cutter)[hold.k0]):
            continue
        to_basket = w.basket_dist(cutter)
        speed = (to_basket[hold.k0 - n_back] - to_basket[hold.k0]) / (n_back * ctx.dt)
        if not speed >= ctx.rule(rule, "min_speed_fts"):
            continue
        players: dict[str, int | None] = {"cutter": cutter, "passer": hold.prev.track_id}
        attrs = {"speed_fts": round(float(speed), 1)}
        out.append(_Candidate(PlayType.CUT, w, hold.k0 - n_back, hold.k0, players, ctx.rule(rule, "confidence"), attrs))
    return out


def _putbacks(w: _Window) -> list[_Candidate]:
    """Shot by the offensive rebounder within seconds of the rebound (or flagged by the pipeline)."""
    ctx, rule = w.ctx, "putback"
    within = ctx.index.frames_for_seconds(ctx.rule(rule, "max_rebound_to_shot_s"))
    out: list[_Candidate] = []
    used: set[str] = set()
    for reb in w.rows({EventType.OREB}):
        rebounder = ctx.actor(reb)
        limit = ctx.rule(rule, "max_basket_distance_ft")
        if w.has_basket and rebounder in w.pos and w.basket_dist(rebounder)[w.k_of(reb.frame)] > limit:
            continue
        rows = ctx.rows_between(reb.frame, min(reb.frame + within, w.end_frame))
        shot = next((r for r in rows if r.type in _SHOTS and r.side == w.side), None)
        if shot is None or shot.id in used:
            continue
        shooter = ctx.actor(shot)
        if shooter != rebounder and not _pipeline_putback(ctx, shot):
            continue
        used.add(shot.id)
        out.append(_Candidate(PlayType.PUTBACK, w, w.k_of(reb.frame), w.k_of(shot.frame), {"shooter": shooter},
                              ctx.rule(rule, "confidence"), end_row=shot))
    for shot in w.rows(_SHOTS):
        if shot.id not in used and _pipeline_putback(ctx, shot):
            k = w.k_of(shot.frame)
            confidence = ctx.rule(rule, "confidence") * 0.9
            players: dict[str, int | None] = {"shooter": ctx.actor(shot)}
            k0 = max(0, k - ctx.samples(1.0))
            out.append(_Candidate(PlayType.PUTBACK, w, k0, k, players, confidence, end_row=shot))
    return out


def _raw_kind(ctx: _Ctx, row: TimelineEvent) -> str | None:
    raw = ctx.raw.get(row.source_event_id or "")
    return raw.attrs.get("kind") if raw is not None else None


def _pipeline_putback(ctx: _Ctx, shot: TimelineEvent) -> bool:
    raw = ctx.raw.get(shot.source_event_id or "")
    return bool(raw is not None and raw.attrs.get("putback"))


def _fast_break(w: _Window) -> list[_Candidate]:
    """Live-ball start, ball over half court fast, shot within seconds, no stoppage (FastScout transition)."""
    ctx, rule, p = w.ctx, "fast_break", w.possession
    if p.start_reason not in ctx.rule(rule, "start_reasons"):
        return []
    fin = w.finish(w.start_frame, w.start_frame + ctx.index.frames_for_seconds(ctx.rule(rule, "shot_within_s")))
    if fin.frame is None or (fin.outcome == PlayOutcome.TURNOVER and not ctx.rule(rule, "count_turnovers")):
        return []
    stoppages = {EventType.FOUL, EventType.TIMEOUT}
    if any(r.type in stoppages for r in ctx.rows_between(w.start_frame, fin.frame - 1)):
        return []
    if fin.row is not None and fin.row.type == EventType.FOUL and _raw_kind(ctx, fin.row) not in (None, "shooting"):
        return []  # a reach-in / common foul stops play: not transition
    attrs: dict[str, Any] = {"start": p.start_reason}
    k_cross = 0
    if w.has_basket:
        front = np.flatnonzero(w.half(None)[:, 0] < ctx.court.mid_x)
        if not len(front) or front[0] * ctx.dt > ctx.rule(rule, "cross_half_within_s"):
            return []
        k_cross = int(front[0])
        attrs["numbers"] = _numbers(w, k_cross)
    handler: int | None = int(w.holder[k_cross])
    if handler not in w.offense:
        handler = next((h.track_id for h in w.offense_holds()), None)
    players: dict[str, int | None] = {"ball_handler": handler, "shooter": fin.shooter}
    candidate = _Candidate(PlayType.FAST_BREAK, w, 0, w.k_of(fin.frame), players, ctx.rule(rule, "confidence"), attrs)
    candidate.finish = fin
    return [candidate]


def _numbers(w: _Window, k: int) -> str:
    """Attackers level with or ahead of the ball vs defenders between the ball and the basket, e.g. "3v2"."""
    ball_hx = float(w.half(None)[k, 0])
    margin = w.ctx.rule("fast_break", "ahead_margin_ft")
    attackers = sum(1 for t in w.offense if w.half(t)[k, 0] <= ball_hx + margin)
    defenders = sum(1 for t in w.defense if w.half(t)[k, 0] < ball_hx)
    return f"{attackers}v{defenders}"


# ---------------------------------------------------------------------------
# Defensive detectors
# ---------------------------------------------------------------------------


def _other(side: TeamSide) -> TeamSide:
    return TeamSide.OTHER if side == TeamSide.SCOUTED else TeamSide.SCOUTED


def _steady(w: _Window, tracks: list[int], ks: np.ndarray) -> list[int]:
    """Tracks seen in at least 80% of the samples, at most five (the best covered)."""
    coverage = {t: float(np.isfinite(w.pos[t][ks, 0]).mean()) for t in tracks}
    keep = sorted((t for t, c in coverage.items() if c >= 0.8), key=lambda t: -coverage[t])
    return keep[:5]


def _coverage(w: _Window, defenders: list[int], attackers: list[int], ks: np.ndarray) -> tuple[float, float]:
    """How defenders relate to the attacker they stay closest to, as ``(follow, anchor)``.

    * follow (0..1): 1 - how much the defender-to-attacker offset changes relative to the
      attacker's own movement. Man: the offset stays put (~1). Zone: the defender holds
      his spot while attackers move through (~0).
    * anchor: the defender's wander divided by that attacker's wander (man ~1, zone << 1).

    Only pairs whose attacker moved at least ``defense.min_move_ft`` (RMS) count.
    """
    min_move = w.ctx.rule("defense", "min_move_ft")
    follows, anchors = [], []
    for d in defenders:
        own = w.pos[d][ks]  # raw units (feet, or pixels in pixel mode); scaled per pair below
        best = min(attackers, key=lambda a: np.nan_to_num(_finite_mean(w.dist(d, a)[ks]), nan=math.inf), default=None)
        if best is None:
            continue
        theirs = w.pos[best][ks]
        ok = np.isfinite(own[:, 0]) & np.isfinite(theirs[:, 0])
        if ok.sum() < 3:
            continue
        theirs, own = theirs[ok], own[ok]
        their_wander = _rms_spread(theirs) * w.scale[best]
        if their_wander < min_move:
            continue
        pair_scale = (w.scale[d] + w.scale[best]) / 2
        follows.append(max(0.0, 1.0 - _rms_spread(own - theirs) * pair_scale / their_wander))
        anchors.append(_rms_spread(own) * w.scale[d] / their_wander)
    if len(follows) < 2:
        return math.nan, math.nan
    return float(np.mean(follows)), float(np.mean(anchors))


def _rms_spread(points: np.ndarray) -> float:
    """RMS distance of points from their mean."""
    return float(np.sqrt(((points - points.mean(axis=0)) ** 2).sum(axis=1).mean()))


def _half_court_span(w: _Window) -> tuple[int, int] | None:
    """Samples from shortly after the ball crosses half court until the first shot."""
    ctx, rule = w.ctx, "defense"
    if w.has_basket:
        front = np.flatnonzero(w.half(None)[:, 0] < ctx.court.mid_x)
        if not len(front):
            return None
        # Wait until every defender is back in the half court (after a press they are still recovering).
        back = np.vstack([w.half(d)[:, 0] for d in w.defense]) if w.defense else np.zeros((1, w.n))
        all_back = np.all(np.nan_to_num(back, nan=0.0) < ctx.court.mid_x, axis=0)
        set_up = np.flatnonzero(all_back & (np.arange(w.n) >= front[0]))
        if not len(set_up):
            return None
        k_a = int(set_up[0]) + ctx.samples(ctx.rule(rule, "settle_s"))
    else:
        k_a = ctx.samples(ctx.rule(rule, "pixel_skip_s"))
    k_a = _defense_set(w, k_a)
    shots = w.rows(_SHOTS)
    k_b = w.k_of(shots[0].frame) - 1 if shots else w.n - 1
    if (k_b - k_a) * ctx.dt < ctx.rule(rule, "min_window_s"):
        return None
    return k_a, k_b


def _defense_set(w: _Window, k: int) -> int:
    """First sample from ``k`` on where the defense is set: low average speed and nobody sprinting."""
    if not w.defense:
        return k
    speeds = np.vstack([w.speed(d) for d in w.defense])
    known = np.isfinite(speeds)
    zeroed = np.where(known, speeds, 0.0)
    mean = np.where(known.any(axis=0), zeroed.sum(axis=0) / np.maximum(known.sum(axis=0), 1), np.inf)
    limit = w.ctx.rule("defense", "set_speed_fts")
    calm = np.flatnonzero((mean <= limit) & (zeroed.max(axis=0) <= 2 * limit) & (np.arange(w.n) >= k))
    return int(calm[0]) if len(calm) else w.n


def _zone_shape(w: _Window, defenders: list[int], ks: np.ndarray) -> str:
    """Best-fitting zone template for the defenders' average spots (court mode only)."""
    if not w.has_basket or len(defenders) != 5:
        return "unknown"
    means = np.array([np.nanmean(w.half(d)[ks], axis=0) for d in defenders])
    best, best_err = "unknown", math.inf
    for name, spots in w.ctx.rule("zone_defense", "templates").items():
        template = np.asarray(spots, dtype=float)
        if template.shape != means.shape:
            continue
        err = min(float(np.hypot(*(means[list(perm)] - template).T).mean()) for perm in permutations(range(5)))
        if err < best_err:
            best, best_err = str(name), err
    return best if best_err <= w.ctx.rule("zone_defense", "max_template_error_ft") else "unknown"


def _possession_finish(w: _Window) -> _Finish:
    """Defense plays are judged by how the whole possession ended (points allowed)."""
    mapping = {
        PossessionOutcome.MADE_FG: PlayOutcome.MADE_FG,
        PossessionOutcome.MISSED_FG: PlayOutcome.MISSED_FG,
        PossessionOutcome.TURNOVER: PlayOutcome.TURNOVER,
        PossessionOutcome.FREE_THROWS: PlayOutcome.FOUL,
        PossessionOutcome.FOUL: PlayOutcome.FOUL,
        PossessionOutcome.END_OF_PERIOD: PlayOutcome.NO_SHOT,
    }
    p = w.possession
    return _Finish(mapping.get(p.outcome, PlayOutcome.UNKNOWN), p.points, p.end_frame)


def _half_court_defense(w: _Window) -> list[_Candidate]:
    """Man vs zone for one half-court possession: do defenders follow a man or hold a spot?"""
    ctx, rule = w.ctx, "defense"
    if not (ctx.rules.is_enabled(PlayType.MAN_DEFENSE.value) or ctx.rules.is_enabled(PlayType.ZONE_DEFENSE.value)):
        return []
    span = _half_court_span(w)
    if span is None:
        return []
    stride = max(1, int(round(1.0 / (ctx.rule(rule, "sample_hz") * ctx.dt))))
    ks = np.arange(span[0], span[1] + 1, stride)
    attackers, defenders = _steady(w, w.offense, ks), _steady(w, w.defense, ks)
    if len(attackers) < 4 or len(defenders) < 4 or len(ks) < 3:
        return []
    follow, anchor = _coverage(w, defenders, attackers, ks)
    if not (np.isfinite(follow) and np.isfinite(anchor)):
        return []
    man_min, zone_max = ctx.rule(rule, "man_min_follow"), ctx.rule(rule, "zone_max_follow")
    anchored = anchor <= ctx.rule(rule, "zone_max_anchor_ratio")  # tie-breaker between the two thresholds
    attrs: dict[str, Any] = {"follow_score": round(follow, 2), "anchor_ratio": round(anchor, 2)}
    if follow >= man_min and anchored:  # follow whoever comes into their area: matchup zone
        play_type, attrs["zone_shape"] = PlayType.ZONE_DEFENSE, "matchup"
    elif follow >= man_min or (follow > zone_max and not anchored):
        play_type = PlayType.MAN_DEFENSE
    else:
        play_type, attrs["zone_shape"] = PlayType.ZONE_DEFENSE, _zone_shape(w, defenders, ks)
    unsure = zone_max < follow < man_min or attrs.get("zone_shape") in ("matchup", "unknown")
    confidence = ctx.rule(rule, "confidence") * (0.8 if unsure else 1.0)
    candidate = _Candidate(play_type, w, int(ks[0]), int(ks[-1]), {}, confidence, attrs, "defense", _other(w.side))
    candidate.finish = _possession_finish(w)
    return [candidate]


def _dead_ball_start(w: _Window) -> bool:
    """The possession began with an inbound (made basket, free throw, out of bounds...)."""
    ctx, reason = w.ctx, w.possession.start_reason
    if reason in ctx.rule("press", "start_reasons"):
        return True
    if reason in ctx.rule("fast_break", "start_reasons"):
        return False
    before = ctx.rows_between(w.start_frame - ctx.index.frames_for_seconds(3.0), w.start_frame)
    return any(r.type in (EventType.SHOT_MADE, EventType.FT_MADE) for r in before)


def _press(w: _Window) -> list[_Candidate]:
    """Two or more defenders picking up in the offense's backcourt while the ball is still there."""
    ctx, rule = w.ctx, "press"
    if not w.has_basket or not w.defense or not _dead_ball_start(w):
        return []
    k_lo = ctx.samples(ctx.rule(rule, "min_delay_s"))
    line = ctx.court.mid_x
    ball_back = w.half(None)[:, 0] > line
    deep = line + ctx.rule(rule, "backcourt_margin_ft")
    # Judge from the inbound catch on: right after a basket everybody is still in that end of the floor.
    in_bounds = ctx.court.length_ft
    inbounded = [k for k in range(k_lo, w.n) if (h := int(w.holder[k])) in w.offense and w.half(h)[k, 0] < in_bounds]
    if not inbounded:
        return []
    k_lo = inbounded[0]
    n_hold, n_pickup = ctx.samples(ctx.rule(rule, "min_hold_s")), ctx.samples(ctx.rule(rule, "pickup_within_s"))
    k_hi = min(w.n - 1, k_lo + n_pickup + n_hold)
    pressing = np.zeros(w.n, dtype=bool)
    for k in range(k_lo, k_hi + 1):
        if ball_back[k]:
            pickup = ctx.rule(rule, "pickup_distance_ft")
            near = [d for d in w.defense if w.half(d)[k, 0] > deep and w.nearest(d, w.offense)[k] <= pickup]
            pressing[k] = len(near) >= ctx.rule(rule, "min_defenders")
    run = _first_run(pressing[k_lo : k_hi + 1], n_hold)
    if run is None or run[0] > n_pickup:
        return []
    r0, r1 = k_lo + run[0], k_lo + run[1]
    crossed = np.flatnonzero(w.half(None)[r1:, 0] < line)
    k_end = r1 + int(crossed[0]) if len(crossed) else w.n - 1
    attrs = {"press_type": _press_type(w, r0, max(r1, k_end))}
    confidence = ctx.rule(rule, "confidence")
    candidate = _Candidate(PlayType.PRESS, w, r0, k_end, {}, confidence, attrs, "defense", _other(w.side))
    candidate.finish = _possession_finish(w)
    return [candidate]


def _press_type(w: _Window, k0: int, k1: int) -> str:
    """Zone press when two defenders trap the ball handler; man press when defenders shadow their man."""
    ctx = w.ctx
    trap = ctx.rule("press", "trap_distance_ft")
    trapped = 0
    for k in range(k0, k1 + 1):
        h = int(w.holder[k])
        if h in w.offense and sum(1 for d in w.defense if w.dist(h, d)[k] <= trap) >= 2:
            trapped += 1
    if trapped >= ctx.samples(0.5):
        return "zone"
    stride = max(1, int(round(1.0 / (ctx.rule("defense", "sample_hz") * ctx.dt))))
    ks = np.arange(k0, k1 + 1, stride)
    attackers, defenders = _steady(w, w.offense, ks), _steady(w, w.defense, ks)
    follow = _coverage(w, defenders, attackers, ks)[0] if len(ks) >= 3 and attackers and defenders else math.nan
    if not np.isfinite(follow):
        return "unknown"
    man_min = ctx.rule("defense", "man_min_follow")
    return "man" if follow >= man_min else ("zone" if follow < man_min / 2 else "unknown")


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

_OFFENSE_DETECTORS = (
    (_ball_screens, (PlayType.PICK_AND_ROLL, PlayType.PICK_AND_POP)),
    (_handoffs, (PlayType.HANDOFF,)),
    (_isolations, (PlayType.ISOLATION,)),
    (_post_ups, (PlayType.POST_UP,)),
    (_off_ball_screens, (PlayType.OFF_BALL_SCREEN,)),
    (_spot_ups, (PlayType.SPOT_UP,)),
    (_cuts, (PlayType.CUT,)),
    (_putbacks, (PlayType.PUTBACK,)),
)


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
    rules = rules or PlayRules()
    rows = sorted(timeline, key=lambda r: (r.frame, r.t))
    raw = {e.event_id: e for e in index.tracking.events}
    sides = _track_sides(index, team_map, assignments)
    ctx = _Ctx(index, court, rules, rows, sides, _player_refs(rows, raw, assignments), raw, index.coord_mode == "court")
    candidates: list[_Candidate] = []
    for w in _windows(ctx, possessions):
        found = _fast_break(w) if rules.is_enabled(PlayType.FAST_BREAK.value) else []
        for detector, types in _OFFENSE_DETECTORS:
            if any(rules.is_enabled(t.value) for t in types):
                found += detector(w)
        if not any(c.type == PlayType.FAST_BREAK for c in found):
            found += _half_court_defense(w)
        if rules.is_enabled(PlayType.PRESS.value):
            found += _press(w)
        candidates += [c for c in found if rules.is_enabled(c.type.value)]
    plays = _to_plays(ctx, _dedupe(ctx, _resolve(ctx, candidates)))
    logger.info("Detected %d plays in %d possessions (%s mode)", len(plays), len(possessions), index.coord_mode)
    return plays


def _windows(ctx: _Ctx, possessions: list[Possession]) -> list[_Window]:
    if not possessions:
        inferred = [p for p in _fallback_possessions(ctx) if p.side and _long_enough(ctx, p)]
        return [_Window(ctx, p, p.side, None, None) for p in inferred]  # type: ignore[arg-type]
    baskets = _possession_baskets(ctx, possessions)
    out = []
    for p in sorted(possessions, key=lambda p: p.start_frame):
        side = p.side or _holder_side(ctx, p.start_frame, p.end_frame)
        if side is not None and _long_enough(ctx, p):
            out.append(_Window(ctx, p, side, baskets.get(p.id), p.id))
    return out


def _long_enough(ctx: _Ctx, p: Possession) -> bool:
    return len(ctx.index.sample_frames(p.start_frame, p.end_frame)) >= 2


def _holder_side(ctx: _Ctx, f0: int, f1: int) -> TeamSide | None:
    holders = (ctx.index.holder_at(f) for f in ctx.index.sample_frames(f0, f1))
    counts = Counter(ctx.sides.get(h) for h in holders if h is not None)
    counts.pop(None, None)
    return counts.most_common(1)[0][0] if counts else None


def _fallback_possessions(ctx: _Ctx) -> list[Possession]:
    """No possessions supplied: treat each run of ball-holder segments by one side as a possession."""
    out: list[Possession] = []
    for seg in ctx.index.holder_segments():
        side = ctx.sides.get(seg.track_id)
        if side is None:
            continue
        if out and out[-1].side == side:
            out[-1].end_frame, out[-1].end_t = seg.end_frame, ctx.index.frame_to_t(seg.end_frame)
            continue
        start_t, end_t = ctx.index.frame_to_t(seg.start_frame), ctx.index.frame_to_t(seg.end_frame)
        out.append(
            Possession(id=len(out), side=side, start_frame=seg.start_frame, end_frame=seg.end_frame, start_t=start_t,
                       end_t=end_t, start_reason="inferred")
        )
    return out


def _resolve(ctx: _Ctx, candidates: list[_Candidate]) -> list[_Candidate]:
    """Fill the outcome of offensive candidates from the event that ends the action."""
    after = ctx.index.frames_for_seconds(ctx.rule("general", "outcome_window_s"))
    for c in candidates:
        if c.finish is not None:
            continue
        w = c.window
        c.finish = w.finish_at(c.end_row) if c.end_row is not None else w.finish(w.frame(c.k0), w.frame(c.k1) + after)
    return candidates


def _dedupe(ctx: _Ctx, candidates: list[_Candidate]) -> list[_Candidate]:
    """One play per shot/turnover: keep the highest-priority type, note the others in ``attrs["also"]``."""
    rank = {name: i for i, name in enumerate(ctx.rule("dedupe", "priority"))}
    kept: list[_Candidate] = []
    by_end: dict[str, list[_Candidate]] = defaultdict(list)
    for c in candidates:
        end_row = c.finish.row if c.finish is not None and c.category == "offense" else None
        if end_row is not None:
            by_end[end_row.id].append(c)
        else:
            kept.append(c)
    for group in by_end.values():
        group.sort(key=lambda c: (rank.get(c.type.value, len(rank)), -c.confidence, c.k0))
        best = group[0]
        also = sorted({c.type.value for c in group[1:] if c.type != best.type})
        if also:
            best.attrs["also"] = also
        kept.append(best)
    return kept


def _to_plays(ctx: _Ctx, candidates: list[_Candidate]) -> list[Play]:
    factor = 1.0 if ctx.has_court else ctx.rule("general", "pixel_confidence_factor")
    candidates.sort(key=lambda c: (c.window.frame(c.k0), c.category != "offense", c.type.value))
    plays: list[Play] = []
    for c in candidates:
        w, fin = c.window, c.finish or _Finish()
        start_frame = w.frame(c.k0)
        end_frame = max(w.frame(c.k1), fin.frame or 0)
        players = {role: ref for role, tid in c.players.items() if (ref := ctx.ref(tid)) is not None}
        side = c.side or w.side
        plays.append(
            Play(
                id=f"pl_{len(plays) + 1}",
                type=c.type,
                category=c.category,
                side=side,
                start_t=ctx.index.frame_to_t(start_frame),
                end_t=ctx.index.frame_to_t(end_frame),
                start_frame=start_frame,
                end_frame=end_frame,
                possession_id=w.possession_id,
                players=players,
                outcome=fin.outcome,
                points=fin.points,
                confidence=round(min(1.0, c.confidence * factor), 3),
                attrs=c.attrs,
                description=_describe(c.type, players, c.attrs, fin),
            )
        )
    return plays


_OUTCOME_TEXT = {
    PlayOutcome.MADE_FG: "made shot",
    PlayOutcome.MISSED_FG: "missed shot",
    PlayOutcome.TURNOVER: "turnover",
    PlayOutcome.FOUL: "fouled",
    PlayOutcome.NO_SHOT: "no shot",
}


def _describe(play_type: PlayType, players: dict[str, PlayerRef], attrs: dict[str, Any], fin: _Finish) -> str:
    """Coach-readable sentence, e.g. "Pick & Roll: #3 (ball handler), #23 (screener); roll -> made shot, 2 pts"."""
    text = PLAY_TYPE_LABELS[play_type]
    who = ", ".join(f"{ref.label} ({role.replace('_', ' ')})" for role, ref in players.items())
    if who:
        text += f": {who}"
    details = [str(attrs[k]) for k in ("roll_or_pop", "numbers", "zone_shape", "press_type") if attrs.get(k)]
    if details:
        text += "; " + ", ".join(details)
    if play_type in (PlayType.MAN_DEFENSE, PlayType.ZONE_DEFENSE, PlayType.PRESS):
        return f"{text} -> allowed {fin.points} pts"
    outcome = _OUTCOME_TEXT.get(fin.outcome)
    if outcome:
        text += f" -> {outcome}" + (f", {fin.points} pts" if fin.points else "")
    return text


# ---------------------------------------------------------------------------
# Linking and summaries
# ---------------------------------------------------------------------------


def link_plays(timeline: list[TimelineEvent], possessions: list[Possession], plays: list[Play]) -> None:
    """In place: set ``TimelineEvent.play_id`` (offensive play covering the event) and ``Possession.play_ids``."""
    offense = sorted((p for p in plays if p.category == "offense"), key=lambda p: p.start_frame)
    starts = [p.start_frame for p in offense]
    longest = max((p.end_frame - p.start_frame for p in offense), default=0)
    for ev in timeline:
        covering = None
        for play in offense[bisect_left(starts, ev.frame - longest) : bisect_right(starts, ev.frame)]:
            if play.end_frame >= ev.frame and _same_possession(ev, play):
                covering = play  # sorted by start: the latest-starting play wins
        ev.play_id = covering.id if covering else None
    by_possession: dict[int, list[str]] = defaultdict(list)
    for play in sorted(plays, key=lambda p: (p.start_t, p.id)):
        possession_id = play.possession_id if play.possession_id is not None else _possession_at(possessions, play)
        if possession_id is not None:
            by_possession[possession_id].append(play.id)
    for p in possessions:
        p.play_ids = by_possession.get(p.id, [])


def _same_possession(ev: TimelineEvent, play: Play) -> bool:
    if ev.possession_id is not None and play.possession_id is not None:
        return ev.possession_id == play.possession_id
    return play.side in (ev.possession_side, ev.side)


def _possession_at(possessions: list[Possession], play: Play) -> int | None:
    """Possession containing a play that came without a ``possession_id`` (offense: same side)."""
    for p in possessions:
        if p.start_frame <= play.start_frame <= p.end_frame:
            offense_side = play.side if play.category == "offense" else None
            if offense_side is None or p.side == offense_side:
                return p.id
    return None


def summarize_plays(plays: list[Play], possessions: list[Possession]) -> list[PlayTypeSummary]:
    """Per (side, play type): count, share of possessions, points, PPP, FG made/att, turnovers.

    PPP = points / possessions featuring the play. For defensive looks the side is the
    defending team, the share is of its defensive possessions and the points are allowed.
    """
    totals = Counter(p.side for p in possessions if p.side is not None)
    groups: dict[tuple[TeamSide | None, PlayType], list[Play]] = defaultdict(list)
    for play in plays:
        groups[(play.side, play.type)].append(play)
    out = []
    for (side, play_type), group in groups.items():
        category = group[0].category
        with_id = {p.possession_id for p in group if p.possession_id is not None}
        featured = len(with_id) + sum(p.possession_id is None for p in group)
        if category == "offense":
            denominator = totals.get(side, 0) if side is not None else 0
        else:
            denominator = sum(n for s, n in totals.items() if s != side)
        points = sum(p.points for p in group)
        made = sum(p.outcome == PlayOutcome.MADE_FG for p in group)
        out.append(
            PlayTypeSummary(
                type=play_type,
                category=category,
                side=side,
                count=len(group),
                possessions_pct=round(min(1.0, featured / denominator), 3) if denominator else None,
                points=points,
                ppp=round(points / featured, 3) if featured else None,
                fgm=made,
                fga=made + sum(p.outcome == PlayOutcome.MISSED_FG for p in group),
                turnovers=sum(p.outcome == PlayOutcome.TURNOVER for p in group),
            )
        )
    side_order = {TeamSide.SCOUTED: 0, TeamSide.OTHER: 1, None: 2}
    out.sort(key=lambda s: (side_order[s.side], s.category != "offense", -s.count, s.type.value))
    return out
