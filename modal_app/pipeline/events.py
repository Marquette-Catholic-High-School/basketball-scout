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

How things are measured
-----------------------
* Everything runs on *analysed slots*: slot ``k`` is original frame ``k * video.step``.
  Durations in :class:`EventConfig` are seconds and are converted with the analysis rate.
* Positions are court feet when players carry ``court_xy``. Without them ("pixel-only
  mode") they are bbox foot points in pixels, and distances become approximate feet by
  using each player's bbox height as a ruler (``player_height_ft``). Detectors that need
  the court (free throws, the fouls inferred from them, jump balls) are skipped then.
* Only ``role == "player"`` tracks can be actors; referees never are.
* Every heuristic would rather miss an event than invent one; ``conf`` (0-1) says how
  much evidence it had.
"""

from __future__ import annotations

import bisect
import copy
import logging
import math
from collections import Counter
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field
from functools import cached_property
from typing import Any

import numpy as np

from modal_app.pipeline.types import KP_L_WRIST, KP_R_WRIST, Perception, RimObs, TrackData, TrackObs

logger = logging.getLogger(__name__)

EVENT_ID_PREFIX = "sx"
NO_TRACK = -1  # "nobody" in integer arrays (track ids are non-negative)
_NAN2 = (math.nan, math.nan)
_NAN4 = (math.nan, math.nan, math.nan, math.nan)
# Same-frame order of new events (matches the server's sort).
_TYPE_ORDER = {"period_start": 0, "jump_ball": 1, "period_end": 3}
# Events that end the pass -> shot sequence an assist needs.
_PLAY_BREAKERS = frozenset(
    {"shot", "free_throw", "rebound", "turnover", "jump_ball", "period_start", "period_end", "timeout"}
)
# Ball-through-the-hoop test (_ft_made), in rim half-widths and seconds.
_RIM_HALF_WIDTH_PER_BODY = 0.125  # without a rim bbox: the rim is 1.5 ft across, a player ~6 ft tall
_HOOP_SIDE_ABOVE, _HOOP_SIDE_BELOW = 1.5, 1.2  # how far to the side of the rim centre still counts
_HOOP_DEPTH = 4.0  # how far above / below the rim plane still counts
_HOOP_NEAR = 3.0  # the ball "reached the rim" within this distance
_HOOP_THROUGH_S = 0.6  # above -> below the rim within this time = through the hoop


@dataclass
class EventConfig:
    """Thresholds (defaults tuned for high-school film at ~15 analysed fps).

    Units: ``*_ft`` feet (approximate feet in pixel-only mode), ``*_s`` seconds, ``*_fps``
    feet per second, ``*_frames`` analysed frames. Values marked "(bbox heights)" are
    multiples of the player's bounding-box height, so they work in pixels for players near
    and far from the camera alike.
    """

    # Ball holder (possession.assign_ball_holders); frame counts are analysed frames.
    holder_acquire_dist: float = 0.25  # (bbox heights) ball this close to a player's hands: he may have it
    holder_keep_dist: float = 0.6  # (bbox heights) the holder keeps control while the ball stays this close
    holder_min_frames: int = 3  # a new holder must persist this long before control switches
    holder_release_frames: int = 4  # control survives the ball being away this long
    keypoint_min_score: float = 0.3  # wrist keypoints scored lower are ignored
    ball_min_conf: float = 0.15  # weaker ball detections are ignored

    # General
    player_height_ft: float = 6.0  # bbox-height ruler for pixel-only mode
    max_gap_s: float = 1.0  # a track is interpolated across gaps up to this long
    speed_window_s: float = 0.5  # speeds come from the displacement across this window
    court_mode_min_share: float = 0.5  # share of observations with court_xy needed to measure motion in feet

    # Court geometry (NFHS; keep in step with config/court.yaml)
    basket_from_baseline_ft: float = 5.25
    ft_line_from_baseline_ft: float = 19.0
    lane_width_ft: float = 12.0

    # enrich_events
    assist_window_s: float = 3.0  # completed pass -> made shot
    assist_max_hold_s: float = 2.0  # the receiver held the ball at most this long before shooting
    rebound_window_s: float = 6.0  # a rebound refers to a miss at most this long before it
    block_window_s: float = 0.5  # the ball must turn sharply this soon after the shot
    block_min_turn_deg: float = 100.0
    block_min_ball_speed: float = 1.0  # (bbox heights per second) slower ball movement is noise
    block_defender_dist: float = 0.4  # (bbox heights) a defender's hands this close to the turning point
    block_rim_clearance: float = 0.6  # (bbox heights) turns this close to a rim are rim bounces, not blocks

    # Free throws (court coordinates required)
    ft_shooter_radius_ft: float = 2.0  # shooter this close to the centre of the free-throw line
    ft_lane_band_ft: float = 3.5  # lane-space players stand up to this far outside a lane line
    ft_lane_tolerance_ft: float = 1.0  # tracking noise: lane spaces may look this much bigger
    ft_min_lane_players: int = 2
    ft_shooter_space_ft: float = 4.0  # nobody else this close to the shooter (free throws are taken alone)
    ft_lineup_gap_s: float = 0.5  # a line-up survives dropouts this long
    ft_setup_s: float = 2.0  # shooter set, players and ball still for this long before the release
    ft_setup_min_share: float = 0.7  # share of the setup where the line-up is seen
    ft_players_max_speed_fps: float = 2.0  # median speed of the players on the floor during the setup
    ft_ball_min_share: float = 0.4  # share of the setup with a ball detection
    ft_ball_still_radius: float = 1.2  # (bbox heights) the ball stays this close to its median and the shooter
    ft_release_above: float = 0.15  # (bbox heights) release = ball this far above the shooter's head ...
    ft_release_lateral: float = 1.0  # (bbox heights) ... and at most this far to the side of him
    ft_release_grace_s: float = 1.5  # the line-up may break up this long before the release is seen
    ft_min_gap_s: float = 3.0  # between two attempts of one trip
    ft_flight_s: float = 2.5  # release -> ball at the rim
    ft_trip_gap_s: float = 45.0  # attempts closer than this at the same basket are one trip
    ft_shot_match_s: float = 1.5  # an existing shot this close to a release is the same attempt
    ft_spot_match_ft: float = 4.0  # ... when its shooter differs, its location must be this close to the line

    # Fouls inferred before a free-throw trip
    foul_lookback_s: float = 60.0  # foul -> first free throw
    foul_max_defender_ft: float = 4.0
    foul_ambiguity_ft: float = 1.0  # a second defender this close to the first: unsure, skip
    foul_conf: float = 0.35  # foul found from a shot (a drive gets 70% of this)
    foul_drive_window_s: float = 2.0
    foul_drive_min_ft: float = 6.0  # a drive gains at least this much ground on the basket ...
    foul_drive_end_ft: float = 12.0  # ... and ends this close to it

    # Screens
    screen_min_hold_s: float = 0.8  # the ball handler holds the ball at least this long
    screen_max_speed_fps: float = 2.0  # the screener is nearly stationary ...
    screen_min_still_s: float = 0.4  # ... for this long
    screen_max_dist_ft: float = 4.0  # the handler passes this close to him
    screen_min_handler_speed_fps: float = 3.0  # while moving (standing next to a teammate is no screen)
    screen_defender_max_ft: float = 6.0  # the handler's defender is this close

    # Jump balls (start of a period)
    jump_ball_search_s: float = 60.0
    jump_ball_player_radius_ft: float = 4.0  # jumpers this close to the centre spot
    jump_ball_rise_s: float = 0.8
    jump_ball_min_rise: float = 0.3  # (bbox heights) the ball rises at least this much
    jump_ball_lateral: float = 1.0  # (bbox heights) ball between the jumpers: this close to their midpoint
    jump_ball_control_s: float = 5.0  # the first holder after the tip decides won_by_team

    # Period boundaries
    period_min_stoppage_s: float = 45.0  # no holder and few players on the floor this long
    period_sure_stoppage_s: float = 300.0  # a stoppage this long is surely a period break (halftime)
    period_max_players: int = 4
    period_merge_gap_s: float = 5.0  # brief activity inside a stoppage (players walking across)
    period_min_length_s: float = 240.0  # a period lasts at least this long (earlier stoppages are timeouts)
    period_first_holder_s: float = 15.0  # the first holder after a period start names the team

    # Dedup windows (against existing and our own events)
    dedup_ft_s: float = 1.5
    dedup_foul_s: float = 3.0
    dedup_screen_s: float = 2.0
    dedup_jump_ball_s: float = 5.0
    dedup_period_s: float = 30.0


# ---------------------------------------------------------------------------
# Hand geometry (also used by possession.assign_ball_holders)
# ---------------------------------------------------------------------------


def wrist_points(obs: TrackObs, min_score: float) -> tuple[float, float, float, float]:
    """(left x, left y, right x, right y) wrist pixels; NaN for a missing or unsure wrist."""
    kps = obs.keypoints
    if not kps or len(kps) <= KP_R_WRIST:
        return _NAN4
    lx, ly, ls = kps[KP_L_WRIST]
    rx, ry, rs = kps[KP_R_WRIST]
    left = (float(lx), float(ly)) if ls >= min_score else _NAN2
    right = (float(rx), float(ry)) if rs >= min_score else _NAN2
    return (*left, *right)


def hand_distance(ball_x: Any, ball_y: Any, bbox: np.ndarray, wrists: np.ndarray) -> np.ndarray:
    """Distance from the ball to each player's hands, in multiples of his bbox height.

    "Hands" are the nearer confident wrist keypoint; without keypoints, the upper half of
    the bounding box (where a held ball sits). ``bbox`` is (n, 4) pixels, ``wrists`` (n, 4)
    from :func:`wrist_points`; the ball may be one point or one per row.
    """
    bbox = np.asarray(bbox, dtype=float).reshape(-1, 4)
    wrists = np.asarray(wrists, dtype=float).reshape(-1, 4)
    bx = np.asarray(ball_x, dtype=float)
    by = np.asarray(ball_y, dtype=float)
    x1, y1, x2, y2 = bbox.T
    h = np.maximum(y2 - y1, 1.0)
    dx = np.maximum(np.maximum(x1 - bx, bx - x2), 0.0)
    dy = np.maximum(np.maximum(y1 - by, by - (y1 + h / 2)), 0.0)
    to_box = np.hypot(dx, dy)
    to_wrist = np.fmin(np.hypot(wrists[:, 0] - bx, wrists[:, 1] - by), np.hypot(wrists[:, 2] - bx, wrists[:, 3] - by))
    return np.where(np.isnan(to_wrist), to_box, to_wrist) / h


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def _as_int(value: Any) -> int | None:
    """Track / team / frame ids from event dicts; None for anything that is not a number."""
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _as_point(value: Any) -> tuple[float, float] | None:
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        return None
    try:
        x, y = float(value[0]), float(value[1])
    except (TypeError, ValueError):
        return None
    return (x, y) if math.isfinite(x) and math.isfinite(y) else None


def _frame_of(event: dict[str, Any]) -> int | None:
    return _as_int(event.get("frame"))


def frame_slots(frames: np.ndarray, step: int) -> np.ndarray:
    """Analysed slot of each original frame number (nearest; halves round up)."""
    return (np.asarray(frames, dtype=np.int64) + step // 2) // step


def _runs(mask: np.ndarray, *, min_len: int = 1, max_gap: int = 0) -> list[tuple[int, int]]:
    """Inclusive (start, end) index pairs of True runs; runs separated by at most ``max_gap``
    False entries are merged, and merged runs shorter than ``min_len`` are dropped."""
    idx = np.flatnonzero(mask)
    if not len(idx):
        return []
    breaks = np.flatnonzero(np.diff(idx) > max_gap + 1)
    starts = np.r_[idx[0], idx[breaks + 1]]
    ends = np.r_[idx[breaks], idx[-1]]
    return [(int(s), int(e)) for s, e in zip(starts, ends, strict=True) if e - s + 1 >= min_len]


def _interpolate(slots: np.ndarray, values: np.ndarray, ks: np.ndarray, max_gap: int) -> np.ndarray:
    """Rows of ``values`` (one per sorted slot) at slots ``ks``: exact rows, linear
    interpolation across gaps of at most ``max_gap`` slots, NaN everywhere else."""
    ks = np.asarray(ks, dtype=np.int64)
    out = np.full((len(ks), values.shape[1]), np.nan)
    n = len(slots)
    if n == 0 or len(ks) == 0:
        return out
    hi = np.searchsorted(slots, ks, side="left")
    exact = (hi < n) & (slots[np.minimum(hi, n - 1)] == ks)
    out[exact] = values[hi[exact]]
    between = ~exact & (hi > 0) & (hi < n)
    if between.any():
        lo, up = hi[between] - 1, hi[between]
        span = slots[up] - slots[lo]
        weight = ((ks[between] - slots[lo]) / span)[:, None]
        rows = np.flatnonzero(between)
        close = span <= max_gap
        out[rows[close]] = (values[lo] + weight * (values[up] - values[lo]))[close]
    return out


def _speeds(slots: np.ndarray, xy: np.ndarray, scale: np.ndarray, half_window: int, dt: float) -> np.ndarray:
    """Speed (ft/s) at every row from the displacement across +-``half_window`` slots; NaN
    when the window is poorly covered or a position is missing."""
    if len(slots) < 2:
        return np.full(len(slots), np.nan)
    j0 = np.searchsorted(slots, slots - half_window, side="left")
    j1 = np.searchsorted(slots, slots + half_window, side="right") - 1
    span = slots[j1] - slots[j0]
    disp = np.hypot(xy[j1, 0] - xy[j0, 0], xy[j1, 1] - xy[j0, 1]) * scale
    speed = disp / (np.maximum(span, 1) * dt)
    speed[span < half_window] = np.nan
    return speed


def _forward_fill(values: np.ndarray, start: int, end: int) -> np.ndarray:
    """``values[start:end + 1]`` with NO_TRACK entries replaced by the last real value."""
    seg = values[start : end + 1]
    idx = np.where(seg >= 0, np.arange(len(seg)), -1)
    np.maximum.accumulate(idx, out=idx)
    return np.where(idx >= 0, seg[np.maximum(idx, 0)], NO_TRACK)


def _rim_covers(rim: RimObs, frame: int) -> bool:
    return rim.frame_start <= frame and (rim.frame_end is None or frame <= rim.frame_end)


# ---------------------------------------------------------------------------
# Array view of the perception
# ---------------------------------------------------------------------------


@dataclass
class _Trajectory:
    """One player track as arrays, one row per analysed slot (sorted)."""

    track_id: int
    team: int | None
    slots: np.ndarray  # int64
    bbox: np.ndarray  # (n, 4) pixels
    court: np.ndarray  # (n, 2) feet, NaN where unmapped
    wrists: np.ndarray  # (n, 4) pixels, NaN where unknown
    # (n, 4): x, y, feet per unit, speed ft/s -- court feet, or bbox foot pixels in pixel-only mode.
    # Filled by the scene once it knows which of the two the film supports.
    motion: np.ndarray = field(default_factory=lambda: np.zeros((0, 4)))

    def at(self, ks: np.ndarray, max_gap: int) -> np.ndarray:
        """``motion`` rows at slots ``ks`` (NaN where the track is not seen)."""
        return _interpolate(self.slots, self.motion, ks, max_gap)

    def nearest_row(self, k: int, max_gap: int) -> int | None:
        """Index of the observation closest to slot ``k``, if within ``max_gap`` slots."""
        n = len(self.slots)
        if not n:
            return None
        i = int(np.searchsorted(self.slots, k))
        best = min((j for j in (i - 1, i) if 0 <= j < n), key=lambda j: abs(int(self.slots[j]) - k))
        return best if abs(int(self.slots[best]) - k) <= max_gap else None


class _Scene:
    """Array view of a Perception shared by the detectors (built once per call).

    * ``tracks``: player trajectories; ``row_*`` + ``rows(k)``: every player observation,
      grouped by slot, for "who is where at slot k" questions.
    * ``ball_px`` / ``ball_ok``: reliable (detected, confident) ball positions per slot;
      ``holder``: the ball holder per slot (NO_TRACK when loose or unknown).
    """

    def __init__(self, perception: Perception, cfg: EventConfig) -> None:
        video = perception.video
        self.cfg = cfg
        self.fps = float(video.fps)
        self.step = max(1, int(video.step))
        self.dt = self.step / self.fps
        self.length_ft = float(perception.court_length_ft)
        self.width_ft = float(perception.court_width_ft)
        self.rims = list(perception.rims)
        self.max_gap = self.slots(cfg.max_gap_s)
        self.track_team = {tid: t.team_id for tid, t in perception.tracks.items()}
        self.referees = {tid for tid, t in perception.tracks.items() if t.role == "referee"}

        trajectories = [self._load(t) for t in perception.player_tracks() if t.obs]
        total = sum(len(t.slots) for t in trajectories)
        mapped = sum(int(np.isfinite(t.court[:, 0]).sum()) for t in trajectories)
        self.has_court = mapped > 0
        self.court_mode = total > 0 and mapped >= cfg.court_mode_min_share * total
        half_window = self.slots(cfg.speed_window_s / 2)
        for t in trajectories:
            t.motion = self._motion(t, half_window)
        self.tracks = {t.track_id: t for t in trajectories}
        self.team = {t.track_id: t.team for t in trajectories}

        last_frame = max(
            video.frame_count - 1,
            max((int(t.slots[-1]) * self.step for t in trajectories), default=0),
            max((b.frame for b in perception.ball), default=0),
        )
        self.n_slots = max(0, self.slot_of(last_frame) + 1)
        self._build_rows(trajectories)
        self._build_ball(perception)

    # -- construction ------------------------------------------------------
    def _load(self, track: TrackData) -> _Trajectory:
        obs = track.obs
        frames = np.fromiter((o.frame for o in obs), dtype=np.int64, count=len(obs))
        slots, first = np.unique(frame_slots(frames, self.step), return_index=True)
        kept = [obs[i] for i in first]
        min_score = self.cfg.keypoint_min_score
        court = [o.court_xy if o.court_xy is not None else _NAN2 for o in kept]
        wrists = [wrist_points(o, min_score) if o.keypoints else _NAN4 for o in kept]
        return _Trajectory(
            track_id=track.track_id,
            team=track.team_id,
            slots=slots,
            bbox=np.array([o.bbox for o in kept], dtype=float).reshape(-1, 4),
            court=np.array(court, dtype=float).reshape(-1, 2),
            wrists=np.array(wrists, dtype=float).reshape(-1, 4),
        )

    def _motion(self, t: _Trajectory, half_window: int) -> np.ndarray:
        if self.court_mode:
            xy, scale = t.court, np.ones(len(t.slots))
        else:
            xy = np.c_[(t.bbox[:, 0] + t.bbox[:, 2]) / 2, t.bbox[:, 3]]
            scale = self.cfg.player_height_ft / np.maximum(t.bbox[:, 3] - t.bbox[:, 1], 1.0)
        return np.c_[xy, scale, _speeds(t.slots, xy, scale, half_window, self.dt)]

    def _build_rows(self, trajectories: list[_Trajectory]) -> None:
        if trajectories:
            slots = np.concatenate([t.slots for t in trajectories])
            order = np.argsort(slots, kind="stable")
            self.row_slot = slots[order]
            tids = [np.full(len(t.slots), t.track_id, dtype=np.int64) for t in trajectories]
            teams = [np.full(len(t.slots), NO_TRACK if t.team is None else t.team) for t in trajectories]
            self.row_tid = np.concatenate(tids)[order]
            self.row_team = np.concatenate(teams)[order]
            self.row_bbox = np.concatenate([t.bbox for t in trajectories])[order]
            self.row_court = np.concatenate([t.court for t in trajectories])[order]
            self.row_wrists = np.concatenate([t.wrists for t in trajectories])[order]
            self.row_motion = np.concatenate([t.motion for t in trajectories])[order]
        else:
            self.row_slot = self.row_tid = self.row_team = np.zeros(0, dtype=np.int64)
            self.row_bbox = self.row_wrists = self.row_motion = np.zeros((0, 4))
            self.row_court = np.zeros((0, 2))
        self.offsets = np.searchsorted(self.row_slot, np.arange(self.n_slots + 1))
        heights = self.row_bbox[:, 3] - self.row_bbox[:, 1]
        self.typical_height = float(np.median(heights)) if len(heights) else 100.0

    def _build_ball(self, perception: Perception) -> None:
        self.ball_px = np.full((self.n_slots, 2), np.nan)
        self.holder = np.full(self.n_slots, NO_TRACK, dtype=np.int64)
        for b in perception.ball:
            k = self.slot_of(b.frame)
            if not 0 <= k < self.n_slots:
                continue
            if b.holder_track_id is not None and b.holder_track_id in self.tracks:
                self.holder[k] = b.holder_track_id
            if not b.interpolated and b.conf >= self.cfg.ball_min_conf:
                self.ball_px[k] = b.xy
        self.ball_ok = np.isfinite(self.ball_px[:, 0])

    # -- time --------------------------------------------------------------
    def slots(self, seconds: float) -> int:
        """Number of analysed slots in ``seconds`` (at least 1)."""
        return max(1, int(round(seconds / self.dt)))

    def slot_of(self, frame: int) -> int:
        """Analysed slot nearest an original frame (same rounding as :func:`frame_slots`)."""
        return (int(frame) + self.step // 2) // self.step

    def frame_of(self, slot: int) -> int:
        return int(slot) * self.step

    # -- who / where ---------------------------------------------------------
    def rows(self, k: int) -> slice:
        """Slice of the ``row_*`` arrays holding the players seen at slot ``k``."""
        if not 0 <= k < self.n_slots:
            return slice(0, 0)
        return slice(int(self.offsets[k]), int(self.offsets[k + 1]))

    def event_team(self, event: dict[str, Any]) -> int | None:
        """The event's team, falling back to its actor's track team."""
        team = _as_int(event.get("team_id"))
        tid = _as_int(event.get("track_id"))
        return team if team is not None or tid is None else self.track_team.get(tid)

    def position(self, tid: int, k: int) -> np.ndarray | None:
        """(x, y, feet per unit, speed) of ``tid`` at slot ``k``, or None."""
        track = self.tracks.get(tid)
        if track is None:
            return None
        row = track.at(np.array([k]), self.max_gap)[0]
        return None if np.isnan(row[0]) else row

    def distance(self, a: int, b: int, k: int) -> float | None:
        pa, pb = self.position(a, k), self.position(b, k)
        if pa is None or pb is None:
            return None
        return float(math.hypot(pa[0] - pb[0], pa[1] - pb[1]) * (pa[2] + pb[2]) / 2)

    def nearest_opponents(self, tid: int, team: int, k: int) -> list[tuple[float, int]]:
        """(distance ft, track) of the opponents seen at slot ``k``, nearest first."""
        me = self.position(tid, k)
        sl = self.rows(k)
        teams = self.row_team[sl]
        rival = (teams >= 0) & (teams != team)
        if me is None or not rival.any():
            return []
        pos = self.row_motion[sl][rival]
        d = np.hypot(pos[:, 0] - me[0], pos[:, 1] - me[1]) * (pos[:, 2] + me[2]) / 2
        tids = self.row_tid[sl][rival]
        ok = np.flatnonzero(np.isfinite(d))
        return [(float(d[i]), int(tids[i])) for i in ok[np.argsort(d[ok])]]

    def teammates(self, tid: int, team: int, a: int, b: int) -> list[int]:
        """Other players of ``team`` seen between slots ``a`` and ``b``."""
        lo, hi = int(self.offsets[max(0, a)]), int(self.offsets[min(self.n_slots, b + 1)])
        tids = self.row_tid[lo:hi][self.row_team[lo:hi] == team]
        return [int(t) for t in np.unique(tids) if t != tid]

    def nearest_hands(self, k: int, bx: float, by: float, *, not_team: int, max_dist: float) -> int | None:
        """Opponent of ``not_team`` whose hands are nearest the ball at slot ``k`` (within ``max_dist``)."""
        sl = self.rows(k)
        teams = self.row_team[sl]
        rival = (teams >= 0) & (teams != not_team)
        if not rival.any():
            return None
        d = hand_distance(bx, by, self.row_bbox[sl][rival], self.row_wrists[sl][rival])
        i = int(np.argmin(d))
        return int(self.row_tid[sl][rival][i]) if d[i] <= max_dist else None

    def bbox_near(self, tid: int, k: int) -> np.ndarray | None:
        """Bbox of ``tid``'s observation nearest slot ``k`` (None when he is not seen near it)."""
        track = self.tracks.get(tid)
        if track is None:
            return None
        i = track.nearest_row(k, self.max_gap)
        return None if i is None else track.bbox[i]

    def body_height(self, tid: int | None, k: int) -> float:
        """Bbox height (px) of ``tid`` near slot ``k``; the film's typical height as fallback."""
        box = self.bbox_near(tid, k) if tid is not None else None
        return float(max(1.0, box[3] - box[1])) if box is not None else self.typical_height

    def court_xy(self, tid: int, k: int) -> np.ndarray | None:
        track = self.tracks.get(tid)
        if track is None:
            return None
        xy = _interpolate(track.slots, track.court, np.array([k]), self.max_gap)[0]
        return None if np.isnan(xy[0]) else xy

    def basket_side_of(self, tid: int | None, k: int) -> str | None:
        """Nearest basket ("left"/"right") to a player, from court coordinates."""
        xy = self.court_xy(tid, k) if tid is not None else None
        if xy is None:
            return None
        return "left" if xy[0] < self.length_ft / 2 else "right"

    def basket(self, side: str) -> tuple[float, float]:
        x = self.cfg.basket_from_baseline_ft
        return (x if side == "left" else self.length_ft - x, self.width_ft / 2)

    def ft_spot(self, side: str) -> tuple[float, float]:
        x = self.cfg.ft_line_from_baseline_ft
        return (x if side == "left" else self.length_ft - x, self.width_ft / 2)

    def half_court(self, xy: np.ndarray, side: str) -> tuple[np.ndarray, np.ndarray]:
        """(feet from that basket's baseline, feet from the court's long axis) of court points."""
        depth = xy[:, 0] if side == "left" else self.length_ft - xy[:, 0]
        return depth, xy[:, 1] - self.width_ft / 2

    def median_speed(self, a: int, b: int) -> float:
        """Median speed (ft/s) of the players on the floor over slots ``a``..``b`` (inf when
        unknown). Players mapped off the court (the benches) do not count."""
        lo, hi = int(self.offsets[max(0, a)]), int(self.offsets[min(self.n_slots, b + 1)])
        x, y = self.row_court[lo:hi, 0], self.row_court[lo:hi, 1]
        off_court = np.isfinite(x) & ((x < 0) | (x > self.length_ft) | (y < 0) | (y > self.width_ft))
        speeds = self.row_motion[lo:hi, 3][~off_court]
        speeds = speeds[np.isfinite(speeds)]
        return float(np.median(speeds)) if len(speeds) else math.inf

    def on_court_counts(self) -> np.ndarray:
        """Players on the floor per slot: court coordinates when the slot has any, else everyone seen."""
        n = self.n_slots
        visible = np.bincount(self.row_slot, minlength=n)[:n]
        x, y = self.row_court[:, 0], self.row_court[:, 1]
        mapped = np.isfinite(x)
        if not mapped.any():
            return visible
        inside = mapped & (x >= 0) & (x <= self.length_ft) & (y >= 0) & (y <= self.width_ft)
        mapped_count = np.bincount(self.row_slot[mapped], minlength=n)[:n]
        inside_count = np.bincount(self.row_slot[inside], minlength=n)[:n]
        return np.where(mapped_count > 0, inside_count, visible)

    # -- ball --------------------------------------------------------------
    def ball_path(self, k0: int, k1: int) -> tuple[np.ndarray, np.ndarray]:
        """Slots and pixel positions of reliable ball detections in [k0, k1]."""
        k0, k1 = max(0, k0), min(self.n_slots - 1, k1)
        if k1 < k0:
            return np.zeros(0, dtype=np.int64), np.zeros((0, 2))
        ks = k0 + np.flatnonzero(self.ball_ok[k0 : k1 + 1])
        return ks, self.ball_px[ks]

    @cached_property
    def holder_runs(self) -> list[tuple[int, int, int]]:
        """(track, first slot, last slot) of uninterrupted ball control."""
        held = np.flatnonzero(self.holder >= 0)
        if not len(held):
            return []
        ids = self.holder[held]
        gap = self.cfg.holder_release_frames + 1
        breaks = np.flatnonzero((np.diff(ids) != 0) | (np.diff(held) > gap))
        starts, ends = np.r_[0, breaks + 1], np.r_[breaks, len(held) - 1]
        return [(int(ids[s]), int(held[s]), int(held[e])) for s, e in zip(starts, ends, strict=True)]

    def first_hold(self, tid: int, k0: int, k1: int) -> int | None:
        """First slot in [k0, k1] where ``tid`` holds the ball."""
        k0, k1 = max(0, k0), min(self.n_slots - 1, k1)
        hits = np.flatnonzero(self.holder[k0 : k1 + 1] == tid) if k1 >= k0 else []
        return k0 + int(hits[0]) if len(hits) else None

    def first_holder_team(self, k0: int, k1: int) -> int | None:
        """Team of the first player to hold the ball in [k0, k1]."""
        k0, k1 = max(0, k0), min(self.n_slots - 1, k1)
        held = np.flatnonzero(self.holder[k0 : k1 + 1] >= 0) if k1 >= k0 else []
        return self.team.get(int(self.holder[k0 + held[0]])) if len(held) else None

    def rim_for(self, side: str, frame: int) -> RimObs | None:
        rims = [r for r in self.rims if r.side == side and _rim_covers(r, frame)]
        return max(rims, key=lambda r: r.frame_start) if rims else None

    def near_rim(self, frame: int, x: float, y: float, radius: float) -> bool:
        return any(_rim_covers(r, frame) and math.hypot(x - r.xy_px[0], y - r.xy_px[1]) <= radius for r in self.rims)


class _Known:
    """Existing events by type, sorted by slot, for context and dedup."""

    def __init__(self, events: Iterable[dict[str, Any]], scene: _Scene) -> None:
        grouped: dict[str, list[tuple[int, dict[str, Any]]]] = {}
        for event in events:
            frame = _frame_of(event)
            if frame is not None:
                grouped.setdefault(str(event.get("type")), []).append((scene.slot_of(frame), event))
        self._slots: dict[str, list[int]] = {}
        self._events: dict[str, list[dict[str, Any]]] = {}
        for kind, items in grouped.items():
            items.sort(key=lambda item: item[0])
            self._slots[kind] = [s for s, _ in items]
            self._events[kind] = [e for _, e in items]

    def of(self, kind: str) -> list[tuple[int, dict[str, Any]]]:
        return list(zip(self._slots.get(kind, []), self._events.get(kind, []), strict=True))

    def between(self, kind: str, lo: int, hi: int) -> list[tuple[int, dict[str, Any]]]:
        """Events of ``kind`` with lo <= slot <= hi."""
        slots = self._slots.get(kind, [])
        i, j = bisect.bisect_left(slots, lo), bisect.bisect_right(slots, hi)
        return list(zip(slots[i:j], self._events[kind][i:j], strict=True)) if j > i else []

    def near(self, kind: str, slot: int, window: int, track_id: int | None = None) -> bool:
        """Is there an event of ``kind`` within ``window`` slots (by ``track_id``, when given)?"""
        nearby = self.between(kind, slot - window, slot + window)
        return any(track_id is None or _as_int(e.get("track_id")) == track_id for _, e in nearby)


def _draft(
    scene: _Scene, kind: str, slot: int, track_id: int | None, team_id: int | None, conf: float, attrs: dict[str, Any]
) -> dict[str, Any]:
    """A new RawEvent dict (``event_id`` is assigned once all events are known)."""
    frame = scene.frame_of(slot)
    return {
        "event_id": "",
        "type": kind,
        "frame": frame,
        "t": round(frame / scene.fps, 3),
        "track_id": None if track_id is None else int(track_id),
        "team_id": None if team_id is None else int(team_id),
        "conf": round(min(1.0, max(0.0, float(conf))), 3),
        "attrs": attrs,
    }


def _event_ids(existing: Iterable[dict[str, Any]]) -> Iterator[str]:
    """"sx00001", "sx00002", ... skipping ids already in use."""
    taken = {str(e.get("event_id")) for e in existing}
    n = 0
    while True:
        n += 1
        candidate = f"{EVENT_ID_PREFIX}{n:05d}"
        if candidate not in taken:
            yield candidate


# ---------------------------------------------------------------------------
# enrich_events: assists, offensive rebounds, blocks
# ---------------------------------------------------------------------------


def enrich_events(
    perception: Perception, existing_events: list[dict[str, Any]], cfg: EventConfig | None = None
) -> list[dict[str, Any]]:
    """Return copies of ``existing_events`` with missing attrs filled in:
    ``shot.assisted_by_track``, ``rebound.offensive``, ``shot.blocked_by_track``.

    * Assist (made shots only): the latest completed pass to the shooter by a teammate
      within ``assist_window_s``, with nothing in between that ends the play, and the
      shooter holding the ball at most ``assist_max_hold_s`` after the catch.
    * Offensive rebound: the rebounder's team equals the team of the preceding miss.
    * Block (shots not marked made): the ball turns sharply within ``block_window_s`` of
      the shot, away from any rim, right at an opponent's hands.

    Values that are already set (not None) are never changed; the order is preserved.
    """
    cfg = cfg or EventConfig()
    events = copy.deepcopy(list(existing_events))
    scene = _Scene(perception, cfg)
    for event in events:
        if not isinstance(event.get("attrs"), dict):
            event["attrs"] = {}
    timeline = sorted((e for e in events if _frame_of(e) is not None), key=lambda e: _frame_of(e) or 0)
    filled: Counter[str] = Counter()
    for pos, event in enumerate(timeline):
        attrs = event["attrs"]
        if event.get("type") == "shot":
            if attrs.get("assisted_by_track") is None and attrs.get("made") is True:
                passer = _assister(scene, timeline, pos, cfg)
                if passer is not None:
                    attrs["assisted_by_track"] = passer
                    filled["assists"] += 1
            if attrs.get("blocked_by_track") is None and attrs.get("made") is not True:
                blocker = _blocker(scene, event, cfg)
                if blocker is not None:
                    attrs["blocked_by_track"] = blocker
                    filled["blocks"] += 1
        elif event.get("type") == "rebound" and attrs.get("offensive") is None:
            offensive = _offensive(scene, timeline, pos, cfg)
            if offensive is not None:
                attrs["offensive"] = offensive
                filled["rebound sides"] += 1
    logger.info("Event enrichment filled %s", dict(filled) or "nothing")
    return events


def _assister(scene: _Scene, timeline: list[dict[str, Any]], pos: int, cfg: EventConfig) -> int | None:
    """Passer of the completed same-team pass that set up the made shot at ``timeline[pos]``."""
    shot = timeline[pos]
    shooter, team, shot_frame = _as_int(shot.get("track_id")), scene.event_team(shot), _frame_of(shot) or 0
    if shooter is None or team is None:
        return None
    for j in range(pos - 1, -1, -1):
        prev = timeline[j]
        frame = _frame_of(prev) or 0
        if shot_frame - frame > cfg.assist_window_s * scene.fps or prev.get("type") in _PLAY_BREAKERS:
            return None
        if prev.get("type") != "pass":
            continue
        passer, attrs = _as_int(prev.get("track_id")), prev.get("attrs") or {}
        if passer == shooter:  # the shooter gave the ball away after any earlier pass to him
            return None
        if _as_int(attrs.get("to_track")) != shooter:
            continue
        if attrs.get("completed", True) is False or passer is None or passer in scene.referees:
            return None
        if scene.event_team(prev) != team:
            return None
        pass_slot, shot_slot = scene.slot_of(frame), scene.slot_of(shot_frame)
        catch = scene.first_hold(shooter, pass_slot, shot_slot)
        held_s = (shot_slot - (pass_slot if catch is None else catch)) * scene.dt
        return passer if held_s <= cfg.assist_max_hold_s else None
    return None


def _offensive(scene: _Scene, timeline: list[dict[str, Any]], pos: int, cfg: EventConfig) -> bool | None:
    """True/False when the rebounder's team and the team of the preceding miss are both known."""
    rebound = timeline[pos]
    team, frame = scene.event_team(rebound), _frame_of(rebound) or 0
    if team is None:
        return None
    for j in range(pos - 1, -1, -1):
        prev = timeline[j]
        if frame - (_frame_of(prev) or 0) > cfg.rebound_window_s * scene.fps:
            return None
        kind = prev.get("type")
        if kind in ("shot", "free_throw"):
            if (prev.get("attrs") or {}).get("made") is True:
                return None
            shooter_team = scene.event_team(prev)
            return None if shooter_team is None else shooter_team == team
        if kind in ("turnover", "jump_ball", "period_start", "period_end"):
            return None
    return None


def _blocker(scene: _Scene, shot: dict[str, Any], cfg: EventConfig) -> int | None:
    """Opponent whose hands were where the ball reversed right after the shot, if any."""
    team, frame = scene.event_team(shot), _frame_of(shot)
    if team is None or frame is None:
        return None
    k0 = scene.slot_of(frame)
    ks, pts = scene.ball_path(k0, k0 + scene.slots(cfg.block_window_s))
    if len(ks) < 3:
        return None
    h = scene.body_height(_as_int(shot.get("track_id")), k0)
    steps = np.diff(pts, axis=0) / np.diff(ks)[:, None]  # pixels per slot
    speed = np.hypot(steps[:, 0], steps[:, 1])
    min_step = cfg.block_min_ball_speed * h * scene.dt
    cos_limit = math.cos(math.radians(cfg.block_min_turn_deg))
    for j in range(1, len(steps)):
        if speed[j - 1] < min_step or speed[j] < min_step:
            continue
        if float(steps[j - 1] @ steps[j]) / (speed[j - 1] * speed[j]) > cos_limit:
            continue
        k, bx, by = int(ks[j]), float(pts[j, 0]), float(pts[j, 1])
        if scene.near_rim(scene.frame_of(k), bx, by, cfg.block_rim_clearance * h):
            continue
        blocker = scene.nearest_hands(k, bx, by, not_team=team, max_dist=cfg.block_defender_dist)
        if blocker is not None:
            return blocker
    return None


# ---------------------------------------------------------------------------
# detect_events
# ---------------------------------------------------------------------------


def detect_events(
    perception: Perception,
    cfg: EventConfig | None = None,
    existing_events: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Return only NEW RawEvent dicts (free_throw, foul, screen, jump_ball, period_start,
    period_end), deduplicated against ``existing_events``. A free throw that coincides
    with an existing ``shot`` carries ``attrs.replaces_event_id`` so the runner can drop it.

    Ids are ``sx00001``, ``sx00002``... in time order, skipping ids already used.
    """
    cfg = cfg or EventConfig()
    existing = list(existing_events or [])
    scene = _Scene(perception, cfg)
    known = _Known(existing, scene)
    drafts: list[dict[str, Any]] = []
    if scene.has_court:
        attempts = _detect_free_throws(scene, known, cfg)
        drafts += [_free_throw_event(scene, a) for a in attempts]
        drafts += _infer_fouls(scene, attempts, known, cfg)
    else:
        logger.info("No court coordinates: free throws, inferred fouls and jump balls are not detected")
    drafts += _detect_screens(scene, known, cfg)
    drafts += _detect_periods(scene, known, cfg)

    drafts.sort(key=lambda d: (d["frame"], _TYPE_ORDER.get(d["type"], 2)))
    ids = _event_ids(existing)
    for draft in drafts:
        draft["event_id"] = next(ids)
    logger.info("Supplementary events: %s", dict(Counter(d["type"] for d in drafts)) or "none")
    return drafts


# -- free throws -------------------------------------------------------------


@dataclass
class _Attempt:
    """A free-throw attempt found here."""

    slot: int  # release
    shooter: int
    team: int | None
    side: str  # basket: "left" / "right"
    setup_start: int
    made: bool | None
    conf: float
    replaces: str | None  # id of the existing shot event that is really this free throw


def _free_throw_event(scene: _Scene, attempt: _Attempt) -> dict[str, Any]:
    attrs: dict[str, Any] = {"made": attempt.made}
    if attempt.replaces:
        attrs["replaces_event_id"] = attempt.replaces
    return _draft(scene, "free_throw", attempt.slot, attempt.shooter, attempt.team, attempt.conf, attrs)


def _detect_free_throws(scene: _Scene, known: _Known, cfg: EventConfig) -> list[_Attempt]:
    """Free-throw attempts at both baskets, oldest first."""
    used: set[str] = set()
    attempts = [a for side in ("left", "right") for a in _free_throws_at(scene, side, known, used, cfg)]
    return sorted(attempts, key=lambda a: a.slot)


def _ft_lineup(scene: _Scene, side: str, cfg: EventConfig) -> tuple[np.ndarray, np.ndarray]:
    """Per slot: the player on this basket's free-throw line (NO_TRACK if none) and the
    number of players lined up along the lane lines."""
    n = scene.n_slots
    shooter = np.full(n, NO_TRACK, dtype=np.int64)
    mapped = np.isfinite(scene.row_court[:, 0])
    if not mapped.any():
        return shooter, np.zeros(n, dtype=np.int64)
    slots, tids = scene.row_slot[mapped], scene.row_tid[mapped]
    depth, lateral = scene.half_court(scene.row_court[mapped], side)
    to_spot = np.hypot(depth - cfg.ft_line_from_baseline_ft, lateral)
    at_line = np.flatnonzero(to_spot <= cfg.ft_shooter_radius_ft)
    if len(at_line):
        order = at_line[np.lexsort((to_spot[at_line], slots[at_line]))]  # nearest first within each slot
        first = order[np.unique(slots[order], return_index=True)[1]]
        shooter[slots[first]] = tids[first]
    # Lane spaces run along both lane lines, outside the lane, from the basket to the free-throw line.
    half_lane, off, tol = cfg.lane_width_ft / 2, np.abs(lateral), cfg.ft_lane_tolerance_ft
    in_band = (
        (off >= half_lane - tol)
        & (off <= half_lane + cfg.ft_lane_band_ft)
        & (depth >= cfg.basket_from_baseline_ft - tol)
        & (depth <= cfg.ft_line_from_baseline_ft + tol)
    )
    return shooter, np.bincount(slots[in_band], minlength=n)[:n]


def _free_throws_at(scene: _Scene, side: str, known: _Known, used: set[str], cfg: EventConfig) -> list[_Attempt]:
    shooter, lane = _ft_lineup(scene, side, cfg)
    lined_up = (shooter >= 0) & (lane >= cfg.ft_min_lane_players)
    setup = scene.slots(cfg.ft_setup_s)
    attempts: list[_Attempt] = []
    runs = _runs(lined_up, min_len=int(setup * cfg.ft_setup_min_share), max_gap=scene.slots(cfg.ft_lineup_gap_s))
    for start, lineup_end in runs:
        end = min(scene.n_slots - 1, lineup_end + scene.slots(cfg.ft_release_grace_s))
        at_line = _forward_fill(shooter, start, end)
        k = start + setup
        while k <= end:
            attempt = _next_attempt(scene, side, at_line, start, k, end, lined_up, lane, known, used, cfg)
            if attempt is None:
                break
            k = attempt.slot + scene.slots(cfg.ft_min_gap_s)
            if not known.near("free_throw", attempt.slot, scene.slots(cfg.dedup_ft_s)):
                attempts.append(attempt)
    return attempts


def _next_attempt(
    scene: _Scene,
    side: str,
    at_line: np.ndarray,
    run_start: int,
    k: int,
    end: int,
    lined_up: np.ndarray,
    lane: np.ndarray,
    known: _Known,
    used: set[str],
    cfg: EventConfig,
) -> _Attempt | None:
    """First verified release in [k, end]: the ball leaving above the shooter's head, or an
    existing shot event that fits, right after a still line-up."""
    released = {
        r
        for r in range(k, end + 1)
        if at_line[r - run_start] >= 0 and _ball_above_head(scene, int(at_line[r - run_start]), r, cfg)
    }
    shots = {s for s, e in known.between("shot", k, end) if e.get("event_id") not in used}
    for r in sorted(released | shots):
        tid = int(at_line[r - run_start])
        if tid < 0 or not _setup_ok(scene, tid, r, lined_up, cfg):
            continue
        shot = _matching_shot(scene, known, used, side, tid, r, cfg)
        if r not in released and shot is None:
            continue  # the shot event that made this a candidate belongs to someone else
        return _make_attempt(scene, side, tid, r, shot, r in released, lane, used, cfg)
    return None


def _ball_above_head(scene: _Scene, tid: int, k: int, cfg: EventConfig) -> bool:
    if not scene.ball_ok[k]:
        return False
    box = scene.bbox_near(tid, k)
    if box is None:
        return False
    h = box[3] - box[1]
    bx, by = scene.ball_px[k]
    above = by < box[1] - cfg.ft_release_above * h
    return bool(above and abs(bx - (box[0] + box[2]) / 2) <= cfg.ft_release_lateral * h)


def _setup_ok(scene: _Scene, tid: int, r: int, lined_up: np.ndarray, cfg: EventConfig) -> bool:
    """Line-up held, everyone on the floor standing still, the shooter alone at the line and
    the ball still with him for ``ft_setup_s`` before ``r``."""
    setup = scene.slots(cfg.ft_setup_s)
    a = r - setup
    if a < 0 or lined_up[a:r].mean() < cfg.ft_setup_min_share:
        return False
    if scene.median_speed(a, r - 1) > cfg.ft_players_max_speed_fps:
        return False
    if _space_around(scene, tid, a, r - 1) < cfg.ft_shooter_space_ft:
        return False
    ks, pts = scene.ball_path(a, r - 1)
    box = scene.bbox_near(tid, r)
    if len(ks) < cfg.ft_ball_min_share * setup or box is None:
        return False
    radius = cfg.ft_ball_still_radius * (box[3] - box[1])
    centre = np.median(pts, axis=0)
    shooter_centre = ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
    still = np.hypot(pts[:, 0] - centre[0], pts[:, 1] - centre[1]).max() <= radius
    return bool(still and math.dist(centre, shooter_centre) <= radius)


def _space_around(scene: _Scene, tid: int, a: int, b: int) -> float:
    """Median (over slots a..b) distance in feet from ``tid`` to the nearest other player."""
    gaps = []
    for k in range(a, b + 1):
        me, sl = scene.position(tid, k), scene.rows(k)
        if me is None:
            continue
        others = scene.row_motion[sl][scene.row_tid[sl] != tid]
        d = np.hypot(others[:, 0] - me[0], others[:, 1] - me[1]) * (others[:, 2] + me[2]) / 2
        d = d[np.isfinite(d)]
        gaps.append(float(d.min()) if len(d) else math.inf)
    return float(np.median(gaps)) if gaps else 0.0


def _matching_shot(
    scene: _Scene, known: _Known, used: set[str], side: str, tid: int, r: int, cfg: EventConfig
) -> dict[str, Any] | None:
    """Unused existing shot event that is really this free throw (nearest in time)."""
    window = scene.slots(cfg.ft_shot_match_s)
    best: tuple[int, dict[str, Any]] | None = None
    for slot, shot in known.between("shot", r - window, r + window):
        if shot.get("event_id") in used or not _shot_fits(scene, shot, tid, side, cfg):
            continue
        if best is None or abs(slot - r) < abs(best[0] - r):
            best = (slot, shot)
    return best[1] if best else None


def _shot_fits(scene: _Scene, shot: dict[str, Any], tid: int, side: str, cfg: EventConfig) -> bool:
    shooter = _as_int(shot.get("track_id"))
    if shooter is None or shooter == tid:
        return True
    xy = _as_point((shot.get("attrs") or {}).get("shot_court_xy"))
    return xy is not None and math.dist(xy, scene.ft_spot(side)) <= cfg.ft_spot_match_ft


def _make_attempt(
    scene: _Scene,
    side: str,
    tid: int,
    r: int,
    shot: dict[str, Any] | None,
    release_seen: bool,
    lane: np.ndarray,
    used: set[str],
    cfg: EventConfig,
) -> _Attempt:
    setup = scene.slots(cfg.ft_setup_s)
    made = _ft_made(scene, side, r, scene.body_height(tid, r), cfg)
    shot_made = (shot.get("attrs") or {}).get("made") if shot else None
    if made is None and isinstance(shot_made, bool):
        made = shot_made
    if shot is not None:
        used.add(str(shot.get("event_id")))
    conf = 0.5 + 0.1 * release_seen + 0.1 * (shot is not None) + 0.1 * (made is not None)
    conf += 0.1 * (float(np.median(lane[r - setup : r])) >= 3)
    return _Attempt(
        slot=r,
        shooter=tid,
        team=scene.team.get(tid),
        side=side,
        setup_start=r - setup,
        made=made,
        conf=min(conf, 0.9),
        replaces=str(shot.get("event_id")) if shot else None,
    )


def _ft_made(scene: _Scene, side: str, r: int, body_h: float, cfg: EventConfig) -> bool | None:
    """Made / missed from the ball trajectory around the rim; None without rim or ball evidence.

    Made: a sample just above the rim inside its width, followed shortly by one just below
    it (through the hoop). Missed: the ball reached the rim but never went through.
    """
    rim = scene.rim_for(side, scene.frame_of(r))
    if rim is None:
        return None
    ks, pts = scene.ball_path(r + 1, r + scene.slots(cfg.ft_flight_s))
    if not len(ks):
        return None
    rx, ry = rim.xy_px
    half = (rim.bbox[2] - rim.bbox[0]) / 2 if rim.bbox else _RIM_HALF_WIDTH_PER_BODY * body_h
    dx, dy = np.abs(pts[:, 0] - rx), pts[:, 1] - ry  # dy < 0: above the rim
    if not (np.hypot(dx, dy) <= _HOOP_NEAR * half).any():
        return None
    above = np.flatnonzero((dx <= _HOOP_SIDE_ABOVE * half) & (dy < 0) & (dy >= -_HOOP_DEPTH * half))
    below = np.flatnonzero((dx <= _HOOP_SIDE_BELOW * half) & (dy > 0) & (dy <= _HOOP_DEPTH * half))
    through = scene.slots(_HOOP_THROUGH_S)
    return bool(any(((ks[below] > ks[i]) & (ks[below] - ks[i] <= through)).any() for i in above))


# -- fouls -------------------------------------------------------------------


@dataclass
class _Line:
    """A free-throw attempt, detected here or already in the event list."""

    slot: int
    shooter: int | None
    team: int | None
    side: str | None
    setup_start: int


def _infer_fouls(scene: _Scene, attempts: list[_Attempt], known: _Known, cfg: EventConfig) -> list[dict[str, Any]]:
    """One shooting foul before each free-throw trip, when the fouled play is clear."""
    lines = [_Line(a.slot, a.shooter, a.team, a.side, a.setup_start) for a in attempts]
    setup = scene.slots(cfg.ft_setup_s)
    for slot, event in known.of("free_throw"):
        tid = _as_int(event.get("track_id"))
        lines.append(_Line(slot, tid, scene.event_team(event), scene.basket_side_of(tid, slot), slot - setup))
    replaced = {a.replaces for a in attempts if a.replaces}
    drafts: list[dict[str, Any]] = []
    previous = -1
    for trip in _trips(lines, scene, cfg):
        foul = _shooting_foul(scene, trip[0], previous, known, replaced, cfg)
        if foul is not None:
            drafts.append(foul)
        previous = trip[-1].slot
    return drafts


def _trips(lines: list[_Line], scene: _Scene, cfg: EventConfig) -> list[list[_Line]]:
    """Group attempts at the same basket by the same team, close in time, into trips."""
    gap = scene.slots(cfg.ft_trip_gap_s)
    trips: list[list[_Line]] = []
    for line in sorted(lines, key=lambda x: x.slot):
        last = trips[-1][-1] if trips else None
        if (
            last is not None
            and line.slot - last.slot <= gap
            and line.side == last.side
            and (line.team is None or last.team is None or line.team == last.team)
        ):
            trips[-1].append(line)
        else:
            trips.append([line])
    return trips


def _shooting_foul(
    scene: _Scene, first: _Line, after: int, known: _Known, replaced: set[str], cfg: EventConfig
) -> dict[str, Any] | None:
    """Foul on the trip's shooter at his last shot (or drive) before the line-up."""
    if first.shooter is None or first.team is None:
        return None
    lo = max(after + 1, first.slot - scene.slots(cfg.foul_lookback_s))
    hi = first.setup_start
    if known.between("foul", lo - scene.slots(cfg.dedup_foul_s), first.slot):
        return None  # the foul is already in the event list
    slot, conf = _fouled_shot(known, replaced, first.shooter, lo, hi), cfg.foul_conf
    if slot is None:
        slot, conf = _fouled_drive(scene, known, replaced, first, lo, hi, cfg), 0.7 * cfg.foul_conf
    if slot is None:
        return None
    fouler = _clear_defender(scene, first.shooter, first.team, slot, cfg)
    if fouler is None:
        return None
    attrs = {"kind": "shooting", "fouled_track": first.shooter}
    return _draft(scene, "foul", slot, fouler, scene.team.get(fouler), conf, attrs)


def _play_continued(known: _Known, replaced: set[str], lo: int, hi: int) -> bool:
    """Any field-goal attempt or turnover in (lo, hi): play went on, so no foul at ``lo``."""
    shots = [e for _, e in known.between("shot", lo + 1, hi - 1) if e.get("event_id") not in replaced]
    return bool(shots or known.between("turnover", lo + 1, hi - 1))


def _fouled_shot(known: _Known, replaced: set[str], shooter: int, lo: int, hi: int) -> int | None:
    """Slot of the last field-goal attempt in [lo, hi) when it was the shooter's and play stopped."""
    shots = [(s, e) for s, e in known.between("shot", lo, hi - 1) if e.get("event_id") not in replaced]
    if not shots or _as_int(shots[-1][1].get("track_id")) != shooter:
        return None
    slot = shots[-1][0]
    return None if _play_continued(known, replaced, slot, hi) else slot


def _fouled_drive(
    scene: _Scene, known: _Known, replaced: set[str], first: _Line, lo: int, hi: int, cfg: EventConfig
) -> int | None:
    """End slot of the shooter's drive to the basket when it was the last ball control in [lo, hi)."""
    runs = [r for r in scene.holder_runs if lo <= r[2] < hi]
    if not runs or first.side is None or runs[-1][0] != first.shooter:
        return None
    _, start, end = runs[-1]
    if _play_continued(known, replaced, end, hi):
        return None
    begin = scene.court_xy(first.shooter, max(start, end - scene.slots(cfg.foul_drive_window_s)))
    stop = scene.court_xy(first.shooter, end)
    if begin is None or stop is None:
        return None
    basket = scene.basket(first.side)
    gained = math.dist(begin, basket) - math.dist(stop, basket)
    return end if gained >= cfg.foul_drive_min_ft and math.dist(stop, basket) <= cfg.foul_drive_end_ft else None


def _clear_defender(scene: _Scene, shooter: int, team: int, slot: int, cfg: EventConfig) -> int | None:
    """The one opponent clearly closest to the shooter (None when nobody is, or two are)."""
    opponents = scene.nearest_opponents(shooter, team, slot)
    if not opponents or opponents[0][0] > cfg.foul_max_defender_ft:
        return None
    if len(opponents) > 1 and opponents[1][0] - opponents[0][0] < cfg.foul_ambiguity_ft:
        return None
    return opponents[0][1]


# -- screens -----------------------------------------------------------------


def _detect_screens(scene: _Scene, known: _Known, cfg: EventConfig) -> list[dict[str, Any]]:
    """On-ball screens: a nearly stationary teammate the moving ball handler brushes past
    while his defender is on him."""
    found: list[tuple[float, int, int, int, int]] = []  # conf, slot, screener, handler, team
    min_hold, min_still = scene.slots(cfg.screen_min_hold_s), scene.slots(cfg.screen_min_still_s)
    for handler, a, b in scene.holder_runs:
        team = scene.team.get(handler)
        if team is None or b - a + 1 < min_hold:
            continue
        ks = np.arange(a, b + 1)
        hand = scene.tracks[handler].at(ks, scene.max_gap)
        for mate in scene.teammates(handler, team, a, b):
            screen = _screen_by(scene, ks, hand, handler, mate, team, min_still, cfg)
            if screen is not None:
                found.append(screen)
    window = scene.slots(cfg.dedup_screen_s)
    kept: list[tuple[float, int, int, int, int]] = []
    for screen in sorted(found, key=lambda s: -s[0]):
        _, k, screener, _, _ = screen
        if known.near("screen", k, window, track_id=screener):
            continue
        if any(other[2] == screener and abs(other[1] - k) <= window for other in kept):
            continue
        kept.append(screen)
    return [
        _draft(scene, "screen", k, screener, team, conf, {"ball_handler_track": handler, "on_ball": True})
        for conf, k, screener, handler, team in kept
    ]


def _screen_by(
    scene: _Scene,
    ks: np.ndarray,
    hand: np.ndarray,
    handler: int,
    mate: int,
    team: int,
    min_still: int,
    cfg: EventConfig,
) -> tuple[float, int, int, int, int] | None:
    """Best screen set by ``mate`` for ``handler`` during the slots ``ks``, if any."""
    other = scene.tracks[mate].at(ks, scene.max_gap)
    with np.errstate(invalid="ignore"):
        still = other[:, 3] < cfg.screen_max_speed_fps
    best: tuple[float, int, int, int, int] | None = None
    for i0, i1 in _runs(still, min_len=min_still):
        seg = slice(i0, i1 + 1)
        d = np.hypot(hand[seg, 0] - other[seg, 0], hand[seg, 1] - other[seg, 1]) * (hand[seg, 2] + other[seg, 2]) / 2
        if not np.isfinite(d).any():
            continue
        j = i0 + int(np.nanargmin(d))
        dist = float(d[j - i0])
        if dist > cfg.screen_max_dist_ft or not hand[j, 3] >= cfg.screen_min_handler_speed_fps:
            continue
        k = int(ks[j])
        opponents = scene.nearest_opponents(handler, team, k)
        if not opponents or opponents[0][0] > cfg.screen_defender_max_ft:
            continue
        defender_to_screener = scene.distance(opponents[0][1], mate, k)
        conf = 0.45
        conf += 0.15 * (dist <= 0.75 * cfg.screen_max_dist_ft)
        conf += 0.1 * (float(np.nanmean(other[seg, 3])) < cfg.screen_max_speed_fps / 2)
        conf += 0.1 * (defender_to_screener is not None and defender_to_screener <= cfg.screen_max_dist_ft)
        conf *= 1.0 if scene.court_mode else 0.8
        if best is None or conf > best[0]:
            best = (conf, k, mate, handler, team)
    return best


# -- periods and jump balls -------------------------------------------------------


def _detect_periods(scene: _Scene, known: _Known, cfg: EventConfig) -> list[dict[str, Any]]:
    """period_start / period_end around long stoppages, plus the jump ball that starts a period.

    The film's first live play starts period 1. Each later stoppage of at least
    ``period_min_stoppage_s`` (no holder, few players on the floor) ends a period and starts
    the next one, unless it comes within ``period_min_length_s`` of the period start (then
    it is taken for a timeout). A stoppage that runs to the end of the film ends the last
    period. Full timeouts can still look like quarter breaks; their conf stays lower.
    """
    quiet = (scene.holder < 0) & (scene.on_court_counts() <= cfg.period_max_players)
    live = np.flatnonzero(~quiet)
    if not len(live):
        return []
    last = scene.n_slots - 1
    stoppages = _stoppages(quiet, scene, cfg)
    first_slot, first_conf = int(live[0]), 0.3
    if stoppages and stoppages[0][0] <= first_slot:  # the film opens with a long stoppage
        first_slot, first_conf = stoppages[0][1] + 1, stoppages[0][2]
        stoppages = stoppages[1:]
    if first_slot > last:
        return []
    starts: list[tuple[int, float]] = [(first_slot, first_conf)]
    ends: list[tuple[int, float]] = []
    for a, b, conf in stoppages:
        if b >= last:
            ends.append((a, conf))
            break
        if (a - starts[-1][0]) * scene.dt >= cfg.period_min_length_s:
            ends.append((a, conf))
            starts.append((b + 1, conf))
    drafts: list[dict[str, Any]] = []
    for number, (slot, conf) in enumerate(starts, start=1):
        jump = _find_jump_ball(scene, slot, cfg) if scene.has_court else None
        if jump is not None:
            slot, team, jump_conf = jump
            conf = max(conf, jump_conf)
            if not known.near("jump_ball", slot, scene.slots(cfg.dedup_jump_ball_s)):
                drafts.append(_draft(scene, "jump_ball", slot, None, team, jump_conf, {"won_by_team": team}))
        else:
            team = scene.first_holder_team(slot, slot + scene.slots(cfg.period_first_holder_s))
        if not known.near("period_start", slot, scene.slots(cfg.dedup_period_s)):
            drafts.append(_draft(scene, "period_start", slot, None, team, conf, {"period": number}))
    for number, (slot, conf) in enumerate(ends, start=1):
        if not known.near("period_end", slot, scene.slots(cfg.dedup_period_s)):
            drafts.append(_draft(scene, "period_end", slot, None, None, conf, {"period": number}))
    return drafts


def _stoppages(quiet: np.ndarray, scene: _Scene, cfg: EventConfig) -> list[tuple[int, int, float]]:
    """(first slot, last slot, conf) of long quiet stretches: 0.4 for one just long enough
    (could be a timeout) up to 0.85 for a halftime-length break."""
    runs = _runs(quiet, min_len=scene.slots(cfg.period_min_stoppage_s), max_gap=scene.slots(cfg.period_merge_gap_s))
    span = max(1.0, cfg.period_sure_stoppage_s - cfg.period_min_stoppage_s)
    out = []
    for a, b in runs:
        extra = (b - a + 1) * scene.dt - cfg.period_min_stoppage_s
        out.append((a, b, 0.4 + 0.45 * min(1.0, max(0.0, extra / span))))
    return out


def _find_jump_ball(scene: _Scene, start: int, cfg: EventConfig) -> tuple[int, int | None, float] | None:
    """(slot of the toss's peak, winning team, conf) of a tip-off soon after ``start``.

    Two opposing players in the centre circle, nobody holding the ball, and the ball rising
    between them.
    """
    end = min(scene.n_slots - 1, start + scene.slots(cfg.jump_ball_search_s))
    rise = scene.slots(cfg.jump_ball_rise_s)
    for k in range(start, end + 1):
        if not scene.ball_ok[k] or scene.holder[k] >= 0:
            continue
        jumpers = _jumpers(scene, k, cfg)
        if jumpers is None:
            continue
        box_a, box_b, farther_ft = jumpers
        mid_x = (box_a[0] + box_a[2] + box_b[0] + box_b[2]) / 4
        h = (box_a[3] - box_a[1] + box_b[3] - box_b[1]) / 2
        bx, by = scene.ball_px[k]
        if abs(bx - mid_x) > cfg.jump_ball_lateral * h:
            continue
        ks, pts = scene.ball_path(k + 1, k + rise)
        if not len(ks) or by - pts[:, 1].min() < cfg.jump_ball_min_rise * h:
            continue
        ks, pts = scene.ball_path(k, k + 3 * rise)  # follow the toss to its highest point
        top = int(np.argmin(pts[:, 1]))
        if abs(pts[top, 0] - mid_x) > cfg.jump_ball_lateral * h:
            continue
        peak = int(ks[top])
        winner = scene.first_holder_team(peak, peak + scene.slots(cfg.jump_ball_control_s))
        conf = 0.5
        conf += 0.15 * (pts[top, 1] < min(box_a[1], box_b[1]))  # tossed above both heads
        conf += 0.15 * (winner is not None)
        conf += 0.1 * (farther_ft <= cfg.jump_ball_player_radius_ft / 2)
        return peak, winner, min(conf, 0.9)
    return None


def _jumpers(scene: _Scene, k: int, cfg: EventConfig) -> tuple[np.ndarray, np.ndarray, float] | None:
    """Bboxes of the nearest player of two teams at the centre spot at slot ``k``, and the
    larger of their distances to it."""
    sl = scene.rows(k)
    court, teams = scene.row_court[sl], scene.row_team[sl]
    d = np.hypot(court[:, 0] - scene.length_ft / 2, court[:, 1] - scene.width_ft / 2)
    inside = np.flatnonzero(np.isfinite(d) & (d <= cfg.jump_ball_player_radius_ft) & (teams >= 0))
    picks: dict[int, int] = {}
    for i in inside[np.argsort(d[inside])]:
        picks.setdefault(int(teams[i]), int(i))
    if len(picks) < 2:
        return None
    i, j = list(picks.values())[:2]
    boxes = scene.row_bbox[sl]
    return boxes[i], boxes[j], float(max(d[i], d[j]))
