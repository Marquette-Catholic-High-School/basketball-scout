"""Synthetic game generator.

Produces a plausible ``TrackingResult`` (tracks, ball, raw events, homography) with
scripted possessions -- pick-and-rolls, isolations, fast breaks, post-ups, handoffs,
zone and man defense, a press -- so that:

* ``SCOUT_PROCESSOR=mock`` can demo the whole app without a GPU, and
* tests can check the transform end to end against known ground truth.

Deterministic for a given ``seed``.

How it works
------------
Team 0 (dark navy) is the scouted team, team 1 wears white. Possessions alternate
the way real ones do (made basket -> inbound, miss -> defensive rebound, steal ->
fast break...). Each possession is scripted in *half-court feet* for the basket being
attacked: the offense follows hand-written choreography (bring the ball up, a short
ball reversal, then one scripted play), and the defense is simulated on a 0.2 s grid
(man: shadow your man; zone: hold a spot and shift with the ball; press: pick up full
court) with a top speed so nobody teleports. Movement is stored as keyframes and
sampled at ``analysis_fps``; pixels come from a fixed 1920x1080 broadcast-style
camera (a court->pixel homography). Raw events follow docs/TRACKING_SCHEMA.md and the
ball holder in every sample matches them.
"""

from __future__ import annotations

import logging
import math
import random
from bisect import bisect_right
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from scout.analysis.geometry import CourtConfig, apply_homography_many, compute_homography, invert_homography, is_three
from scout.schemas import (
    BallSample,
    CourtInfo,
    Homography,
    JerseyRead,
    PipelineInfo,
    PipelineWarning,
    RawEvent,
    RawEventType,
    RimInfo,
    Roster,
    RosterPlayer,
    TeamInfo,
    TeamSide,
    Track,
    TrackingResult,
    TrackSample,
    VideoInfo,
)

logger = logging.getLogger(__name__)

COURT = CourtConfig()  # synthetic games always use the NFHS 84 x 50 ft court
L, W = COURT.length_ft, COURT.width_ft
HXY = tuple[float, float]  # half-court feet: (from the attacked baseline, from the offense's left sideline)

# Jerseys per team. No single-digit number is also a digit of another number on the
# same team, so partial OCR reads ("2" of "23") stay unambiguous.
_JERSEYS = {0: ["0", "5", "11", "12", "14", "23", "32", "44"], 1: ["1", "3", "20", "22", "24", "40", "42", "55"]}
_FIRST = ["Jalen", "Marcus", "Tyler", "Devin", "Andre", "Caleb", "Isaiah", "Noah", "Elijah", "Jordan", "Malik", "Owen",
          "Xavier", "Brandon", "Cole", "Darius"]
_LAST = ["Johnson", "Williams", "Brown", "Miller", "Davis", "Garcia", "Wilson", "Moore", "Taylor", "Anderson", "Thomas",
         "Jackson", "White", "Harris", "Martin", "Thompson"]
_POSITIONS = ["PG", "SG", "SF", "PF", "C", "G", "F", "C"]
_HEIGHTS = ["5-10", "6-1", "6-3", "6-5", "6-7", "6-0", "6-4", "6-8"]
_TEAM_NAMES = {0: "Navy", 1: "White"}
_TEAM_COLORS = {0: ((24, 34, 76), "navy"), 1: ((238, 238, 236), "white")}
_SIDES = {0: TeamSide.SCOUTED, 1: TeamSide.OTHER}

# Camera: where the court corners (0,0), (L,0), (L,W), (0,W) appear in a 1920x1080 frame.
_FRAME_W, _FRAME_H = 1920, 1080
_CORNERS_PX = [(60.0, 1000.0), (1860.0, 1000.0), (1500.0, 330.0), (420.0, 330.0)]

# Offensive spots (half-court feet).
TOP, L_WING, R_WING = (27.0, 25.0), (21.0, 7.0), (21.0, 43.0)
L_CORNER, R_CORNER = (3.5, 3.0), (3.5, 47.0)
L_BLOCK, R_BLOCK = (8.0, 17.5), (8.0, 32.5)
RIM: HXY = (COURT.basket_from_baseline_ft, COURT.mid_y)

# Zone spots per defender role (PG, SG, SF, PF, C), half-court feet.
_ZONES: dict[str, list[HXY]] = {
    "2-3": [(21.5, 17.5), (21.5, 32.5), (8.5, 10.0), (8.5, 40.0), (6.5, 25.0)],
    "1-3-1": [(27.5, 25.0), (17.5, 9.5), (17.5, 40.5), (15.5, 25.0), (5.5, 25.0)],
}
# 1-2-1-1 zone press spots (offense's backcourt), per defender role.
_ZONE_PRESS: list[HXY] = [(64.0, 12.0), (64.0, 38.0), (52.0, 25.0), (74.0, 25.0), (30.0, 25.0)]

_CONFUSE = {"8": "3", "3": "8", "1": "7", "7": "1", "0": "8", "5": "6", "6": "5", "2": "7", "4": "1", "9": "8"}


@dataclass
class SyntheticTruth:
    """Ground truth for tests: what the generator scripted."""

    box: dict[str, dict[str, int]] = field(default_factory=dict)  # jersey key "scouted:#23" -> {"pts":..,"fgm":..}
    # [{"type": "pick_and_roll", "category": "offense", "side": "scouted", "start_t": .., "end_t": .., ...}]
    plays: list[dict] = field(default_factory=list)
    score: dict[str, int] = field(default_factory=dict)  # {"scouted": 41, "other": 37}
    possessions: list[dict] = field(default_factory=list)  # scripted possessions with their defense
    track_players: dict[int, str] = field(default_factory=dict)  # track id -> jersey key (split players: two tracks)


# ---------------------------------------------------------------------------
# Rosters
# ---------------------------------------------------------------------------


def _roster_plan(seed: int) -> dict[int, list[dict[str, str]]]:
    """Per team: 8 players, the first five are the lineup in role order PG, SG, SF, PF, C."""
    plan = {}
    for team in (0, 1):
        rng = random.Random(seed * 1009 + team * 7919)
        jerseys = list(_JERSEYS[team])
        rng.shuffle(jerseys)
        firsts, lasts = rng.sample(_FIRST, 8), rng.sample(_LAST, 8)
        plan[team] = [
            {"jersey": jerseys[i], "first": firsts[i], "last": lasts[i], "position": _POSITIONS[i],
             "height": _HEIGHTS[i], "grade": str(rng.choice([10, 11, 12]))}
            for i in range(8)
        ]
    return plan


def synthetic_rosters(game_id: str, *, seed: int = 7) -> dict[TeamSide, Roster]:
    """Rosters whose jerseys match the players used by ``generate_synthetic_game`` (same seed)."""
    rosters = {}
    for team, players in _roster_plan(seed).items():
        roster_players = [
            RosterPlayer(jersey=p["jersey"], first_name=p["first"], last_name=p["last"], position=p["position"],
                         height=p["height"], grade=p["grade"])
            for p in players
        ]
        side = _SIDES[team]
        rosters[side] = Roster(game_id=game_id, side=side, team_name=_TEAM_NAMES[team], players=roster_players)
    return rosters


# ---------------------------------------------------------------------------
# Movement primitives
# ---------------------------------------------------------------------------


class _Path:
    """Piecewise-linear movement in court feet; keyframe times strictly increase."""

    def __init__(self, t: float, xy: tuple[float, float]) -> None:
        self.ts, self.xs, self.ys = [t], [xy[0]], [xy[1]]

    @property
    def last_t(self) -> float:
        return self.ts[-1]

    def last(self) -> tuple[float, float]:
        return self.xs[-1], self.ys[-1]

    def at(self, t: float) -> tuple[float, float]:
        i = bisect_right(self.ts, t)
        if i == 0:
            return self.xs[0], self.ys[0]
        if i == len(self.ts):
            return self.xs[-1], self.ys[-1]
        t0, t1 = self.ts[i - 1], self.ts[i]
        a = (t - t0) / (t1 - t0)
        return self.xs[i - 1] + a * (self.xs[i] - self.xs[i - 1]), self.ys[i - 1] + a * (self.ys[i] - self.ys[i - 1])

    def go(self, t: float, xy: tuple[float, float]) -> None:
        """Arrive at ``xy`` at time ``t`` (moving in a straight line from the previous keyframe)."""
        t = max(t, self.ts[-1] + 0.1)
        self.ts.append(t)
        self.xs.append(float(xy[0]))
        self.ys.append(float(xy[1]))

    def stay(self, t: float) -> None:
        """Stand still until ``t`` (no-op if already moving past ``t``)."""
        if t > self.ts[-1] + 1e-6:
            self.go(t, self.last())

    def sample(self, ts: np.ndarray) -> np.ndarray:
        return np.column_stack([np.interp(ts, self.ts, self.xs), np.interp(ts, self.ts, self.ys)])


def _to_court(hxy: HXY, basket: str) -> tuple[float, float]:
    """Half-court feet -> court feet (the mapping is its own inverse)."""
    return (hxy[0], hxy[1]) if basket == "left" else (L - hxy[0], W - hxy[1])


def _toward(a: HXY, b: HXY, dist: float) -> HXY:
    """Point ``dist`` feet from ``a`` toward ``b`` (or ``b`` itself when closer)."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    d = math.hypot(dx, dy)
    if d <= dist or d < 1e-9:
        return b
    return a[0] + dx / d * dist, a[1] + dy / d * dist


@dataclass
class _Player:
    key: str
    team: int
    role: int  # 0..4 = PG, SG, SF, PF, C
    jersey: str
    height_ft: float
    tracks: list[tuple[int, float, float]] = field(default_factory=list)  # (track id, from t, to t)

    @property
    def jersey_key(self) -> str:
        return f"{_SIDES[self.team].value}:#{self.jersey}"


@dataclass
class _Start:
    """How a possession begins."""

    t: float
    team: int
    reason: str  # made_basket, made_ft, def_rebound, steal, turnover, jump_ball, period_start
    holder: str | None = None  # player key holding the ball (live starts)
    spot: tuple[float, float] | None = None  # inbound spot in COURT feet (dead balls)


@dataclass
class _Ev:
    t: float
    type: RawEventType
    actor: str | None
    team: int | None
    attrs: dict[str, Any]


# ---------------------------------------------------------------------------
# Possession context
# ---------------------------------------------------------------------------


class _Poss:
    """One possession: who attacks which basket, plus half-court movement helpers."""

    def __init__(self, game: _Game, start: _Start, basket: str) -> None:
        self.g = game
        self.start = start
        self.off, self.dfn = start.team, 1 - start.team
        self.basket = basket
        self.offense = game.lineups[self.off]  # offense player keys, role order
        self.defense = game.lineups[self.dfn]
        self.modes: list[tuple[float, str]] = []  # defense behaviour from time t on
        self.overrides: dict[str, list[tuple[float, float, tuple[float, float]]]] = defaultdict(list)
        self.back: list[str] = []  # transition: defenders sprinting back ahead of the ball

    def court(self, hxy: HXY) -> tuple[float, float]:
        return _to_court(hxy, self.basket)

    def hpos(self, key: str, t: float) -> HXY:
        return _to_court(self.g.paths[key].at(t), self.basket)

    def go(self, key: str, t: float, hxy: HXY) -> None:
        self.g.paths[key].go(t, self.court(hxy))

    def stay(self, key: str, t: float) -> None:
        self.g.paths[key].stay(t)

    def run(self, key: str, t_start: float, hxy: HXY, speed: float) -> float:
        """Stand until ``t_start`` (or until the current move ends), then run to ``hxy``; returns the arrival time."""
        path = self.g.paths[key]
        path.stay(t_start)
        here = _to_court(path.last(), self.basket)
        arrive = path.last_t + max(0.3, math.hypot(hxy[0] - here[0], hxy[1] - here[1]) / speed)
        path.go(arrive, self.court(hxy))
        return arrive

    def mode_at(self, t: float) -> str:
        return next((m for start, m in sorted(self.modes, reverse=True) if start <= t), "man")

    def defender_of(self, attacker: str, t: float) -> str:
        """The defender who would plausibly steal from / block / foul ``attacker`` at ``t``."""
        mode = self.mode_at(t).split(":")[-1]
        if mode == "transition" and self.back:
            return self.back[0]
        if mode in _ZONES:
            here = self.hpos(attacker, t)
            spots = _ZONES[mode]
            return self.defense[min(range(5), key=lambda i: math.hypot(spots[i][0] - here[0], spots[i][1] - here[1]))]
        return self.defense[self.g.players[attacker].role]

    def rebounder(self) -> str:
        if self.mode_at(math.inf) == "transition" and self.back:
            return self.back[0]
        return self.defense[4] if self.g.rng.random() < 0.6 else self.defense[3]

    def send(self, defender: str, t_from: float, t_to: float, hxy: HXY) -> None:
        """Make a defender be at ``hxy`` at ``t_to`` (steal, block, rebound, free-throw line-up)."""
        self.overrides[defender].append((t_from, t_to, self.court(hxy)))


# ---------------------------------------------------------------------------
# The game script
# ---------------------------------------------------------------------------


class _Game:
    """Builds the whole game: keyframed movement, ball states and raw events."""

    def __init__(self, seed: int, duration_s: float, ocr_noise: float) -> None:
        self.rng = random.Random(seed)
        self.seed = seed
        self.duration_s = duration_s
        self.ocr_noise = ocr_noise
        self.players: dict[str, _Player] = {}
        self.lineups: dict[int, list[str]] = {}
        self.paths: dict[str, _Path] = {}
        for team, roster in _roster_plan(seed).items():
            keys = []
            for role, p in enumerate(roster[:5]):
                key = f"{team}:{p['jersey']}"
                feet, inches = (int(v) for v in p["height"].split("-"))
                self.players[key] = _Player(key, team, role, p["jersey"], feet + inches / 12)
                keys.append(key)
            self.lineups[team] = keys
        self.ball_states: list[tuple[float, str, Any]] = []
        self.ball_ts: list[float] = []
        self.events: list[_Ev] = []
        self.truth_plays: list[dict] = []
        self.truth_possessions: list[dict] = []
        self.decks: dict[int, list[str]] = {0: [], 1: []}
        self.presses = {0: 0, 1: 0}
        self.n_periods = 4 if duration_s >= 1500 else (2 if duration_s >= 240 else 1)

    # ------------------------------------------------------------- recording
    def ev(
        self, t: float, type_: RawEventType, actor: str | None = None, team: int | None = None, **attrs: Any
    ) -> None:
        if actor is not None:
            team = self.players[actor].team
        self.events.append(_Ev(t, type_, actor, team, attrs))

    def ball(self, t: float, kind: str, data: Any) -> None:
        """Ball state from ``t`` on: ("held", key) | ("flight", (from, to, t_end, peak_ft)) | ("dead", court_xy)."""
        if self.ball_states and t < self.ball_states[-1][0]:
            t = self.ball_states[-1][0] + 0.01
        self.ball_states.append((t, kind, data))
        self.ball_ts.append(t)

    def key_name(self, key: str) -> str:
        return self.players[key].jersey_key

    def record_play(
        self, poss: _Poss, type_: str, start_t: float, end_t: float, players: dict[str, str], **attrs: Any
    ) -> None:
        self.truth_plays.append(
            {"type": type_, "category": "offense", "side": _SIDES[poss.off].value, "start_t": round(start_t, 2),
             "end_t": round(end_t, 2), "players": {role: self.key_name(k) for role, k in players.items()}, **attrs}
        )

    # ------------------------------------------------------------- basic actions
    def pass_(self, a: str, b: str, t: float, flight: float = 0.45) -> float:
        """Completed pass from ``a`` to ``b`` thrown at ``t``; returns the catch time (b must be there)."""
        self.ev(t, RawEventType.PASS, a, to_track=b, completed=True)
        self.ball(t, "flight", (a, b, t + flight, 4.0))
        self.ball(t + flight, "held", b)
        return t + flight

    def shot(self, poss: _Poss, shooter: str, t: float, made: bool, *, assisted_by: str | None = None,
             blocked_by: str | None = None, putback: bool = False) -> None:
        x, y = self.paths[shooter].at(t)
        three = is_three(COURT, (x, y), poss.basket)  # type: ignore[arg-type]
        self.ev(t, RawEventType.SHOT, shooter, made=made, is_three=three, shot_court_xy=[round(x, 2), round(y, 2)],
                shot_xy_px=None, assisted_by_track=assisted_by if made else None, blocked_by_track=blocked_by,
                putback=putback)
        self.ball(t, "flight", (shooter, poss.court(RIM), t + 1.0, 15.0 if three else 12.0))

    def rebound(self, poss: _Poss, rebounder: str, t: float, offensive: bool, spot: HXY) -> None:
        """Ball comes off the rim to ``spot`` where ``rebounder`` (already sent there) secures it at ``t``."""
        self.ball(t - 0.6, "flight", (poss.court(RIM), poss.court(spot), t, 7.0))
        flag: bool | None = offensive if self.rng.random() > 0.2 else None  # some rows leave it to the server
        self.ev(t, RawEventType.REBOUND, rebounder, offensive=flag)
        self.ball(t, "held", rebounder)

    def made_basket(self, poss: _Poss, t_shot: float) -> _Start:
        self.ball(t_shot + 1.0, "dead", poss.court((1.0, 25.0)))
        # Everyone turns around at once; the inbound comes from behind this baseline.
        return _Start(t_shot + 0.3, poss.dfn, "made_basket", spot=poss.court((-0.8, 21.0)))

    def defensive_rebound(self, poss: _Poss, t_reb: float) -> _Start:
        rebounder = poss.rebounder()
        spot = (6.0 + self.rng.uniform(0, 3), 25.0 + self.rng.choice([-1, 1]) * self.rng.uniform(1, 5))
        poss.send(rebounder, t_reb - 1.6, t_reb, spot)
        self.rebound(poss, rebounder, t_reb, False, spot)
        return _Start(t_reb, poss.dfn, "def_rebound", holder=rebounder)

    def end_action(self, poss: _Poss, shooter: str, t: float, finish: str, *, assisted_by: str | None = None,
                   putback: bool = False) -> _Start:
        """Finish a play with ``shooter`` at time ``t``: made / miss / foul / steal / bad_pass."""
        here = poss.hpos(shooter, t)
        defender = poss.defender_of(shooter, t)
        if finish == "steal":
            poss.send(defender, t - 1.2, t, _toward(here, RIM, 1.5))
            self.ev(t, RawEventType.TURNOVER, shooter, kind="steal", stolen_by_track=defender)
            self.ball(t, "held", defender)
            return _Start(t, poss.dfn, "steal", holder=defender)
        if finish == "bad_pass":
            self.ev(t, RawEventType.TURNOVER, shooter, kind=self.rng.choice(["bad_pass", "travel", "out_of_bounds"]))
            x, y = self.paths[shooter].at(t)
            out = (x, -0.8 if y < W / 2 else W + 0.8)
            self.ball(t, "dead", out)
            return _Start(t + 1.5, poss.dfn, "turnover", spot=out)
        if finish == "foul":
            poss.send(defender, t - 1.2, t + 0.1, _toward(here, RIM, 2.0))
            and_one = self.rng.random() < 0.35
            self.shot(poss, shooter, t, and_one, assisted_by=assisted_by, putback=putback)
            three = bool(self.events[-1].attrs["is_three"])
            self.ev(t + 0.05, RawEventType.FOUL, defender, kind="shooting", fouled_track=shooter)
            n = 1 if and_one else (3 if three else 2)
            return self.free_throws(poss, shooter, t, [self.rng.random() < 0.7 for _ in range(n)])
        made = finish == "made"
        blocker = None
        if not made and math.hypot(here[0] - RIM[0], here[1] - RIM[1]) < 10 and self.rng.random() < 0.3:
            blocker = defender
            poss.send(defender, t - 1.2, t + 0.1, _toward(here, RIM, 2.0))
        self.shot(poss, shooter, t, made, assisted_by=assisted_by, blocked_by=blocker, putback=putback)
        return self.made_basket(poss, t) if made else self.defensive_rebound(poss, t + 1.7)

    def free_throws(self, poss: _Poss, shooter: str, t_shot: float, made: list[bool]) -> _Start:
        """Line up and shoot ``len(made)`` free throws; the first comes 2.6 s after the foul (and-one rule)."""
        times = [t_shot + 2.6 + 2.0 * i for i in range(len(made))]
        poss.go(shooter, times[0] - 0.9, (19.5, 25.0))
        lane_off = [(13.0, 18.0), (13.0, 32.0), (27.0, 14.0), (27.0, 36.0)]
        for key, spot in zip([o for o in poss.offense if o != shooter], lane_off, strict=True):
            poss.go(key, times[0] - 0.7, spot)
        lane_def = [(24.0, 25.0), (10.0, 18.0), (10.0, 32.0), (7.0, 18.0), (7.0, 32.0)]
        for key, spot in zip(poss.defense, lane_def, strict=True):
            poss.send(key, t_shot + 0.3, times[-1] + 0.3, spot)
        self.ball(t_shot + 1.05, "dead", poss.court((3.0, 25.0)))
        for i, (t_ft, ok) in enumerate(zip(times, made, strict=True)):
            self.ball(t_ft - 0.8, "held", shooter)
            self.ev(t_ft, RawEventType.FREE_THROW, shooter, made=ok)
            self.ball(t_ft, "flight", (shooter, poss.court(RIM), t_ft + 0.8, 12.0))
            if i < len(made) - 1 or ok:
                self.ball(t_ft + 0.8, "dead", poss.court((1.0, 25.0)))
        last = times[-1]
        if made[-1]:
            return _Start(last + 0.5, poss.dfn, "made_ft", spot=poss.court((-0.8, 21.0)))
        return self.defensive_rebound(poss, last + 1.5)

    # ------------------------------------------------------------- game flow
    def build(self) -> None:
        """Script every period: jump ball / inbound, then possessions until the period clock runs out."""
        period_len = self.duration_s / self.n_periods
        self.period = 1
        start = self._jump_ball(1.0)
        arrow = 1 - start.team
        for period in range(1, self.n_periods + 1):
            self.period = period
            t0 = (period - 1) * period_len
            t_end = period * period_len - 1.5
            if period > 1:
                start = _Start(max(t0, start.t) + 1.0, arrow, "period_start", spot=(L / 2, -0.8))
                arrow = 1 - arrow
            self.ev(max(t0, start.t - 0.8) + 0.1, RawEventType.PERIOD_START, period=period)
            while start.t < t_end - 24.0:
                start = self._possession(start)
            t_stop = min(max(t_end, start.t + 0.5), self.duration_s - 0.2)
            self.ball(t_stop, "dead", (L / 2, W / 2))
            self.ev(t_stop, RawEventType.PERIOD_END, period=period)
            start = _Start(t_stop, start.team, start.reason)

    def _basket(self, team: int) -> str:
        """Team 0 attacks the right basket in the first half, the left one after half time."""
        first_half = self.period <= max(1, self.n_periods // 2)
        return ("right" if first_half else "left") if team == 0 else ("left" if first_half else "right")

    def _jump_ball(self, t: float) -> _Start:
        formation = [(36.0, 20.0), (36.0, 31.0), (48.0, 12.0), (48.0, 38.0), (42.6, 25.0)]  # PG, SG, SF, PF, C
        for team in (0, 1):
            basket = self._basket(team)
            for key, spot in zip(self.lineups[team], formation, strict=True):
                self.paths[key] = _Path(0.0, _to_court(spot, basket))
        winner = self.rng.choice([0, 1])
        pg = self.lineups[winner][0]
        self.ball(0.0, "dead", (L / 2, W / 2))
        self.ev(t, RawEventType.JUMP_BALL, won_by_team=winner)
        self.ball(t, "flight", ((L / 2, W / 2), pg, t + 0.6, 9.0))
        self.ball(t + 0.6, "held", pg)
        return _Start(t + 0.6, winner, "jump_ball", holder=pg)

    def _possession(self, s: _Start) -> _Start:
        poss = _Poss(self, s, self._basket(s.team))
        first_event = len(self.events)
        if s.reason in ("def_rebound", "steal") and s.holder is not None and self.rng.random() < 0.55:
            end = self._fast_break(poss)
            self._finish_possession(poss, end.t)
            self._log_possession(poss, end, "fast_break", "transition", None, None, first_event)
            return end
        scheme = "2-3" if poss.dfn == 0 else "1-3-1"
        scheme = scheme if self.rng.random() < 0.4 else "man"
        press = self._press_kind(poss) if s.reason in ("made_basket", "made_ft") else None
        play = self._next_play(poss.off, scheme)
        t_set, t_cross = self._bring_up(poss, press, scheme)
        t_play = self._setup(poss, t_set)
        end = getattr(self, f"_{play}")(poss, t_play, self._pick_finish())
        self._finish_possession(poss, end.t)
        self._log_possession(poss, end, play, scheme, press, t_cross, first_event)
        return end

    def _finish_possession(self, poss: _Poss, t_end: float) -> None:
        """Simulate the defense, and keep attackers where they are until the next possession moves them."""
        self._defend(poss, t_end)
        for key in poss.offense:
            self.paths[key].stay(t_end)

    def _press_kind(self, poss: _Poss) -> str | None:
        """The scouted team presses its first two chances (man, then zone), later now and then."""
        team = poss.dfn
        if team == 0 and self.presses[0] < 2 and poss.start.t > 10.0:
            kind = ("press_man", "press_zone")[self.presses[0]]
        elif self.rng.random() < (0.12 if team == 0 else 0.06):
            kind = self.rng.choice(["press_man", "press_zone"])
        else:
            return None
        self.presses[team] += 1
        return kind

    _HALF_COURT_PLAYS = ("pick_and_roll", "spot_up", "isolation", "pick_and_pop", "post_up", "handoff", "putback")
    _MAN_ONLY = frozenset({"isolation", "post_up"})

    def _next_play(self, team: int, scheme: str) -> str:
        deck = self.decks[team]
        if not deck:
            deck.extend(self.rng.sample(self._HALF_COURT_PLAYS, len(self._HALF_COURT_PLAYS)))
        for i, play in enumerate(deck):
            if scheme == "man" or play not in self._MAN_ONLY:
                return deck.pop(i)
        return "pick_and_roll"  # only man-only plays left: keep them for a man possession

    def _pick_finish(self) -> str:
        r = self.rng.random()
        for finish, cumulative in (("made", 0.47), ("miss", 0.80), ("foul", 0.89), ("steal", 0.95)):
            if r < cumulative:
                return finish
        return "bad_pass"

    def _log_possession(self, poss: _Poss, end: _Start, play: str, defense: str, press: str | None,
                        t_cross: float | None, first_event: int) -> None:
        finish_types = (RawEventType.SHOT, RawEventType.TURNOVER, RawEventType.FOUL)
        t_finish = next((e.t for e in self.events[first_event:] if e.type in finish_types), end.t)
        zone = defense if defense in _ZONES else None
        defending = _SIDES[poss.dfn].value
        self.truth_possessions.append(
            {"index": len(self.truth_possessions), "side": _SIDES[poss.off].value, "start_t": round(poss.start.t, 2),
             "end_t": round(end.t, 2), "start_reason": poss.start.reason, "play": play, "defense": defense,
             "zone_shape": zone, "press": press, "half_court_t": None if t_cross is None else round(t_cross, 2)}
        )
        if t_cross is not None:
            self.truth_plays.append(
                {"type": "zone_defense" if zone else "man_defense", "category": "defense", "side": defending,
                 "zone_shape": zone, "start_t": round(t_cross, 2), "end_t": round(t_finish, 2)}
            )
        if press and t_cross is not None:
            self.truth_plays.append(
                {"type": "press", "category": "defense", "side": defending, "press_type": press.split("_")[1],
                 "start_t": round(poss.start.t, 2), "end_t": round(t_cross, 2)}
            )

    # ------------------------------------------------------------- bring-up and setup
    def _bring_up(self, poss: _Poss, press: str | None, scheme: str) -> tuple[float, float]:
        """Inbound / outlet, then the point guard brings the ball to the top; others run to their spots."""
        s, (pg, sg, sf, pf, c) = poss.start, poss.offense
        t = s.t
        inbounder = None
        if s.holder is None:
            inbounder = c if press else pf
            spot = _to_court(s.spot, poss.basket) if s.spot else (L + 0.8, 25.0)  # court -> half-court feet
            t_ready = max(t + 1.0, poss.run(inbounder, t, spot, 16.0))
            self.ball(t_ready, "held", inbounder)
            receive = _toward(spot, (spot[0] - 14.0 if spot[0] > 60 else spot[0], W / 2), 12.0 if press else 9.5)
            t_pass = max(t_ready + 0.4, poss.run(pg, t, receive, 15.0) - 0.45)
            catch = self.pass_(inbounder, pg, t_pass)
        elif s.holder != pg:
            hx, hy = poss.hpos(s.holder, t)
            outlet = (min(max(hx - 9.0, 45.0), 80.0), 14.0 if hy < W / 2 else 36.0)
            t_pass = max(t + 0.6, poss.run(pg, t, outlet, 16.0) - 0.45)
            catch = self.pass_(s.holder, pg, t_pass)
        else:
            catch = t + 0.2
        if press == "press_zone":
            side_y = 9.0 if poss.hpos(pg, catch)[1] < W / 2 else 41.0
            t_trap = poss.run(pg, catch, (60.0, side_y), 8.0)
            poss.stay(pg, t_trap + 1.0)
            t_top = poss.run(pg, t_trap + 1.0, TOP, 9.0)
        else:
            t_top = poss.run(pg, catch, TOP, 7.5 if press == "press_man" else 11.0)
        t_cross = self._crossing(poss, pg, catch, t_top)
        arrivals = []
        for key, spot in ((sg, L_WING), (sf, R_WING), (pf, R_CORNER), (c, L_BLOCK)):
            leave = catch + (2.0 if press else 0.3) if key == inbounder else t + 0.2
            arrivals.append(poss.run(key, leave, spot, 15.0))
        poss.modes = [(t, press or f"retreat:{scheme}"), (t_cross, scheme)]
        t_set = max(t_top, max(arrivals) - 0.5)
        poss.stay(pg, t_set)
        return t_set, t_cross

    def _crossing(self, poss: _Poss, key: str, t0: float, t1: float) -> float:
        """When ``key`` (dribbling up) crosses half court."""
        for t in np.arange(t0, t1 + 0.05, 0.05):
            if poss.hpos(key, float(t))[0] < L / 2:
                return float(t)
        return t1

    def _setup(self, poss: _Poss, t_a: float) -> float:
        """Ball reversal (PG -> SG -> PG) while the bigs and the wing swap spots; returns the play start."""
        pg, sg, sf, pf, c = poss.offense
        catch = self.pass_(pg, sg, t_a + 0.3)
        for key, via, spot in ((c, None, R_BLOCK), (sf, (12.0, 40.5), R_CORNER), (pf, (13.0, 48.0), R_WING)):
            poss.stay(key, t_a + 0.3)
            if via is not None:
                poss.go(key, t_a + 1.3, via)
            poss.go(key, t_a + 2.3, spot)
        poss.go(sg, catch + 0.5, (L_WING[0] + 1.0, L_WING[1] + 1.0))
        back = self.pass_(sg, pg, catch + 1.0)
        poss.stay(pg, back + 0.3)
        return back + 0.3

    # ------------------------------------------------------------- scripted plays (ball with the PG at the top)
    def _pick_and_roll(self, poss: _Poss, t: float, finish: str) -> _Start:
        return self._ball_screen(poss, t, finish, pop=False)

    def _pick_and_pop(self, poss: _Poss, t: float, finish: str) -> _Start:
        return self._ball_screen(poss, t, finish, pop=True)

    def _ball_screen(self, poss: _Poss, t: float, finish: str, *, pop: bool) -> _Start:
        """A big sets a ball screen at the top, then rolls to the rim or pops beyond the arc."""
        pg, sg, sf, pf, c = poss.offense
        screener = c if not pop and self.rng.random() < 0.65 else pf
        s = self.rng.choice([-1.0, 1.0])  # screen on the handler's left (-1) or right (+1)
        t_set = max(t + 0.8, poss.run(screener, t - 0.2, (TOP[0] + 0.5, TOP[1] + 3.2 * s), 12.0))
        self.ev(t_set + 0.2, RawEventType.SCREEN, screener, ball_handler_track=pg, on_ball=True)
        t_go = t_set + 0.9
        poss.stay(pg, t_go)
        poss.stay(screener, t_set + 1.1)
        poss.go(pg, t_go + 0.9, (TOP[0] - 7.0, TOP[1] + 9.0 * s))
        shooter, assist = pg, None
        if pop:
            poss.go(screener, t_set + 2.2, (24.0, 25.0 - 9.0 * s))
            t_shot = self.pass_(pg, screener, t_go + 1.0) + 0.6
            shooter, assist = screener, pg
        else:
            poss.go(screener, t_set + 2.5, (8.0, 25.0 - 1.5 * s))
            if self.rng.random() < 0.6:
                catch = self.pass_(pg, screener, t_go + 1.3, 0.35)
                poss.go(screener, catch + 0.4, (6.5, 25.0 - 1.0 * s))
                t_shot, shooter, assist = catch + 0.45, screener, pg
            else:
                poss.go(pg, t_go + 1.5, (15.0, 25.0 + 5.0 * s))
                t_shot = t_go + 1.6
        side = "left" if s < 0 else "right"
        self.record_play(poss, "pick_and_pop" if pop else "pick_and_roll", t_set - 0.5, t_shot,
                         {"ball_handler": pg, "screener": screener}, screen_side=side)
        return self.end_action(poss, shooter, t_shot, finish, assisted_by=assist)

    def _isolation(self, poss: _Poss, t: float, finish: str) -> _Start:
        """Clear-out for the shooting guard on the left wing: jab steps, then a drive or a pull-up."""
        pg, sg, sf, pf, c = poss.offense
        catch = self.pass_(pg, sg, t + 0.2)
        poss.go(pg, catch + 1.0, (26.0, 36.0))
        poss.go(c, catch + 1.2, (6.0, 41.0))
        bx, by = poss.hpos(sg, catch)
        for i, dt in enumerate((0.8, 1.6, 2.4, 3.2)):
            poss.go(sg, catch + dt, (bx + (0.8 if i % 2 else -0.6), by + (-0.5 if i % 2 else 0.9)))
        t_drive = catch + 3.4
        if self.rng.random() < 0.7:
            poss.go(sg, t_drive + 1.0, (6.5, 21.0))
            t_shot = t_drive + 1.05
        else:
            poss.go(sg, t_drive + 0.6, (13.0, 13.0))
            t_shot = t_drive + 0.7
        self.record_play(poss, "isolation", catch, t_shot, {"ball_handler": sg})
        return self.end_action(poss, sg, t_shot, finish)

    def _post_up(self, poss: _Poss, t: float, finish: str) -> _Start:
        """Entry pass from the wing to the center on the right block; he backs down and scores (or kicks out)."""
        pg, sg, sf, pf, c = poss.offense
        t_entry = self.pass_(pg, pf, t + 0.2) + 0.6
        poss.stay(c, t_entry)
        catch = self.pass_(pf, c, t_entry, 0.4)
        poss.go(c, catch + 1.0, (7.4, 30.8))
        poss.go(c, catch + 2.0, (6.8, 29.5))
        t_shot, shooter, assist = catch + 2.3, c, None
        if self.rng.random() < 0.25:
            t_shot, shooter, assist = self.pass_(c, sf, t_shot - 0.2, 0.5) + 0.6, sf, c
        self.record_play(poss, "post_up", t_entry - 0.3, t_shot, {"post_player": c, "passer": pf})
        return self.end_action(poss, shooter, t_shot, finish, assisted_by=assist)

    def _handoff(self, poss: _Poss, t: float, finish: str) -> _Start:
        """The center catches at the right slot and hands the ball off to the forward running past him."""
        pg, sg, sf, pf, c = poss.offense
        poss.go(c, t + 1.5, (25.0, 35.0))
        t_x = self.pass_(pg, c, t + 1.6) + 1.3
        poss.stay(pf, t_x - 1.0)
        poss.go(pf, t_x, (25.6, 33.4))
        self.ev(t_x, RawEventType.PASS, c, to_track=pf, completed=True)
        self.ball(t_x, "held", pf)
        poss.stay(c, t_x + 0.6)
        poss.go(c, t_x + 2.0, (8.0, 30.0))
        if self.rng.random() < 0.6:
            poss.go(pf, t_x + 1.0, (17.0, 27.0))
            t_shot = t_x + 1.15
        else:
            poss.go(pf, t_x + 1.5, (6.5, 26.5))
            t_shot = t_x + 1.55
        self.record_play(poss, "handoff", t_x - 1.0, t_shot, {"ball_handler": pf, "passer": c})
        return self.end_action(poss, pf, t_shot, finish, assisted_by=c)

    def _spot_up(self, poss: _Poss, t: float, finish: str) -> _Start:
        """The point guard drives into the paint and kicks out to a stationary shooter."""
        pg, sg, sf, pf, c = poss.offense
        shooter = sf if self.rng.random() < 0.5 else sg
        poss.go(pg, t + 1.4, (13.0, 24.0))
        t_shot = self.pass_(pg, shooter, t + 1.45, 0.5) + 0.6
        self.record_play(poss, "spot_up", t + 1.45, t_shot, {"shooter": shooter, "passer": pg})
        finish = finish if finish in ("made", "miss", "foul") else "miss"  # a catch-and-shoot always gets a shot up
        return self.end_action(poss, shooter, t_shot, finish, assisted_by=pg)

    def _putback(self, poss: _Poss, t: float, finish: str) -> _Start:
        """Wing jumper misses, the center grabs the offensive rebound and puts it back up."""
        pg, sg, sf, pf, c = poss.offense
        catch = self.pass_(pg, sg, t + 0.2)
        poss.go(sg, catch + 0.9, (20.0, 9.0))
        t_miss = catch + 1.8
        self.shot(poss, sg, t_miss, False)
        spot = (6.0, 27.5)
        t_reb = t_miss + 1.7
        poss.go(c, t_reb - 0.3, spot)
        poss.stay(c, t_reb)
        self.rebound(poss, c, t_reb, True, spot)
        t_put = t_reb + 0.9
        poss.go(c, t_put, (5.6, 26.4))
        self.record_play(poss, "putback", t_reb - 0.3, t_put, {"shooter": c})
        return self.end_action(poss, c, t_put, finish if finish in ("made", "miss", "foul") else "miss", putback=True)

    def _fast_break(self, poss: _Poss) -> _Start:
        """Outlet, point guard pushes up the middle with one or two wings running the lanes."""
        s, (pg, sg, sf, pf, c) = poss.start, poss.offense
        t0, holder = s.t, s.holder or pg
        poss.modes = [(t0, "transition")]
        if holder == pg:
            catch = t0 + 0.2
        else:
            hx, hy = poss.hpos(holder, t0)
            outlet = (min(max(hx - 9.0, 45.0), 80.0), 14.0 if hy < W / 2 else 36.0)
            catch = self.pass_(holder, pg, max(t0 + 0.5, poss.run(pg, t0, outlet, 18.0) - 0.45))
        wings = [w for w in (sg, sf) if w != holder][: self.rng.choice([1, 2])]
        lane_y = {sg: 7.0, sf: 43.0}
        arrive = {}
        for wing in wings:
            poss.run(wing, t0 + 0.2, (38.0, lane_y[wing]), 19.0)
            arrive[wing] = poss.run(wing, self.paths[wing].last_t, (10.0, lane_y[wing]), 16.0)
        for i, key in enumerate(k for k in poss.offense if k not in wings and k != pg):
            poss.run(key, t0 + 0.5, (30.0 + 4.0 * i, 18.0 + 7.0 * i), 11.0)
        t_mid = poss.run(pg, catch, (44.0, 24.0), 18.0)
        t_top = poss.run(pg, t_mid, (22.0, 25.0), 16.0)
        poss.back = poss.defense[: 2 if len(wings) == 2 and self.rng.random() < 0.6 else 1]
        if wings and self.rng.random() < 0.6:
            wing = wings[0]
            catch2 = self.pass_(pg, wing, max(t_top + 0.1, arrive[wing] - 0.4), 0.4)
            poss.go(wing, catch2 + 0.85, (6.0, 21.0 if lane_y[wing] < W / 2 else 29.0))
            t_shot, shooter, assist = catch2 + 0.9, wing, pg
        else:
            poss.go(pg, t_top + 1.0, (6.5, 24.0))
            t_shot, shooter, assist = t_top + 1.05, pg, None
        r = self.rng.random()
        finish = "made" if r < 0.62 else "miss" if r < 0.87 else "foul"
        self.record_play(poss, "fast_break", t0, t_shot, {"ball_handler": pg, "shooter": shooter},
                         numbers=f"{1 + len(wings)}v{len(poss.back)}")
        return self.end_action(poss, shooter, t_shot, finish, assisted_by=assist)

    # ------------------------------------------------------------- ball lookups
    def ball_state(self, t: float) -> tuple[float, str, Any]:
        i = bisect_right(self.ball_ts, t) - 1
        return self.ball_states[i] if i >= 0 else (0.0, "dead", (L / 2, W / 2))

    def spec_xy(self, spec: Any, t: float) -> tuple[float, float]:
        return self.paths[spec].at(t) if isinstance(spec, str) else (float(spec[0]), float(spec[1]))

    def ball_court(self, t: float) -> tuple[float, float]:
        """Ball ground position (court feet) from the scripted ball states."""
        t0, kind, data = self.ball_state(t)
        if kind == "held":
            return self.paths[data].at(t)
        if kind == "dead":
            return data
        a, b, t1, _peak = data
        (ax, ay), (bx, by) = self.spec_xy(a, t0), self.spec_xy(b, t1)
        f = min(1.0, max(0.0, (t - t0) / max(t1 - t0, 1e-6)))
        return ax + f * (bx - ax), ay + f * (by - ay)

    def holder(self, t: float) -> str | None:
        _t0, kind, data = self.ball_state(t)
        return data if kind == "held" else None

    # ------------------------------------------------------------- defense simulation
    def _defend(self, poss: _Poss, t_end: float) -> None:
        """Move the defenders on a 0.2 s grid toward their targets, at most ~19 ft/s (22 when sent somewhere)."""
        t0 = poss.start.t
        ends = {round(t_to, 3) for ovs in poss.overrides.values() for _f, t_to, _xy in ovs if t0 < t_to <= t_end}
        grid = [round(float(t), 3) for t in np.arange(t0 + 0.2, t_end, 0.2) if all(abs(t - e) >= 0.1 for e in ends)]
        grid = sorted(set(grid) | ends | {round(t_end, 3)})
        modes = sorted(poss.modes or [(t0, "man")])
        prev = t0
        for t in grid:
            dt = t - prev
            if dt <= 1e-6:
                continue
            mode = next((m for start, m in reversed(modes) if start <= t), modes[0][1])
            targets, speeds = self._defense_targets(poss, mode, t, _to_court(self.ball_court(t), poss.basket))
            for d in poss.defense:
                path = self.paths[d]
                if t <= path.last_t + 0.05:  # still finishing a move from the previous possession
                    continue
                active = [ov for ov in poss.overrides.get(d, []) if ov[0] <= t <= ov[1] + 1e-6]
                if active:
                    _f, t_to, target = active[-1]
                    vmax, exact = 22.0, abs(t_to - t) < 1e-3
                else:
                    target, vmax, exact = poss.court(targets[d]), speeds.get(d, 19.0), False
                x, y = path.last()
                gap = math.hypot(target[0] - x, target[1] - y)
                step = vmax * (t - path.last_t)
                if gap <= step or (exact and gap <= 3.0):
                    path.go(t, target)
                else:
                    path.go(t, (x + (target[0] - x) / gap * step, y + (target[1] - y) / gap * step))
            prev = t

    def _defense_targets(self, poss: _Poss, mode: str, t: float, ball: HXY) -> tuple[dict[str, HXY], dict[str, float]]:
        """Where each defender wants to be (half-court feet) for the current defensive mode."""
        if mode == "transition":
            return self._transition_targets(poss, t, ball)
        if mode == "press_zone":
            return self._zone_press_targets(poss, ball), {}
        scheme = mode.split(":")[-1]
        if mode != "press_man" and scheme in _ZONES:
            return self._zone_targets(poss, scheme, ball), {}
        holder = self.holder(t)
        out = {}
        for d, a in zip(poss.defense, poss.offense, strict=True):
            ah = poss.hpos(a, t - 0.2)
            gap = 3.0 if (a == holder or mode == "press_man") else 4.5
            target = _toward(ah, RIM, min(gap, 0.5 * math.hypot(ah[0] - RIM[0], ah[1] - RIM[1])))
            if mode.startswith("retreat") and target[0] > 30.0:
                target = (30.0, target[1])  # wait for your man at the top of the key
            out[d] = target
        return out, {}

    def _zone_targets(self, poss: _Poss, scheme: str, ball: HXY) -> dict[str, HXY]:
        """Zone spots shifted toward the ball side; the closest defender steps up to the ball."""
        shift = max(-5.0, min(5.0, 0.25 * (ball[1] - W / 2)))
        spots = [(x, y + shift) for x, y in _ZONES[scheme]]
        out = dict(zip(poss.defense, spots, strict=True))
        if ball[0] < L / 2 + 4.0:
            i = min(range(5), key=lambda j: math.hypot(spots[j][0] - ball[0], spots[j][1] - ball[1]))
            if math.hypot(spots[i][0] - ball[0], spots[i][1] - ball[1]) <= 16.0:
                out[poss.defense[i]] = _toward(spots[i], _toward(ball, RIM, 4.0), 7.0)
        return out

    def _zone_press_targets(self, poss: _Poss, ball: HXY) -> dict[str, HXY]:
        """1-2-1-1: backcourt spots shaded toward the ball, the two closest defenders trap it."""
        spots = zip(poss.defense, _ZONE_PRESS, strict=True)
        out = {d: (x + 0.3 * (ball[0] - x), y + 0.3 * (ball[1] - y)) for d, (x, y) in spots}
        if ball[0] > L / 2 + 6.0:
            nearest = sorted(poss.defense, key=lambda d: math.hypot(out[d][0] - ball[0], out[d][1] - ball[1]))[:2]
            for d, side in zip(nearest, (-1.0, 1.0), strict=True):
                out[d] = (ball[0] - 2.0, ball[1] + 3.2 * side)
        return out

    def _transition_targets(self, poss: _Poss, t: float, ball: HXY) -> tuple[dict[str, HXY], dict[str, float]]:
        """Fast break defense: the guards sprint back ahead of the ball, the rest trail the play."""
        out: dict[str, HXY] = {}
        speeds: dict[str, float] = {}
        for j, d in enumerate(poss.back):
            out[d] = (max(5.0, ball[0] - 12.0 - 4.0 * j), W / 2 + (-5.0 if j == 0 else 5.0))
        for d in poss.defense:
            if d not in out:
                out[d] = (max(8.0, ball[0] + 6.0), poss.hpos(d, t)[1])
                speeds[d] = 12.0
        return out, speeds

    # ------------------------------------------------------------- output
    def assign_tracks(self) -> int:
        """Shuffle track ids; one player per team is split into two tracks mid-game. Returns the next free id."""
        rng = random.Random(self.seed + 101)  # independent of the game script: same ids for any duration
        keys = list(self.players)
        ids = list(range(1, len(keys) + 1))
        rng.shuffle(ids)
        for key, tid in zip(keys, ids, strict=True):
            self.players[key].tracks = [(tid, 0.0, math.inf)]
        next_id = len(keys) + 1
        for team, share in ((0, 0.42), (1, 0.63)):
            key = rng.choice(self.lineups[team][1:])
            t_split = self._quiet_time(key, share * self.duration_s)
            first = self.players[key].tracks[0][0]
            self.players[key].tracks = [(first, 0.0, t_split), (next_id, t_split + 0.6, math.inf)]
            next_id += 1
        return next_id

    def _quiet_time(self, key: str, t: float) -> float:
        """First time from ``t`` on when ``key`` stays away from the ball for a moment (clean track split)."""
        while t < self.duration_s - 5.0:
            if all(self.holder(t + dt) != key for dt in np.arange(-0.4, 1.3, 0.1)):
                return t
            t += 1.0
        return t

    def track_of(self, key: str, t: float) -> int:
        tracks = self.players[key].tracks
        for tid, t0, t1 in tracks:
            if t0 <= t <= t1:
                return tid
        return next((tid for tid, t0, _ in tracks if t0 > t), tracks[-1][0])  # inside a split gap: the new track

    def to_tracking(
        self, fps: float, analysis_fps: float, with_homography: bool, filename: str
    ) -> tuple[TrackingResult, SyntheticTruth]:
        """Sample the script at ``analysis_fps`` and package it as a TrackingResult plus ground truth."""
        frame_count = int(round(self.duration_s * fps))
        frames = np.arange(0, frame_count, max(1, int(round(fps / analysis_fps))))
        ts = frames / fps
        h_c2p, _err = compute_homography([(0.0, 0.0), (L, 0.0), (L, W), (0.0, W)], _CORNERS_PX)
        camera = _Camera(np.asarray(h_c2p), with_homography)
        ref_id = self.assign_tracks()
        noise = np.random.default_rng(self.seed)
        positions = {key: self.paths[key].sample(ts) + _jitter(noise, ts) for key in self.players}
        tracks = self._player_tracks(frames, positions, camera, fps)
        ball_xy = np.array([self.ball_court(float(t)) for t in ts]).reshape(-1, 2)
        for j, xy in enumerate(_referee_paths(ball_xy)):
            tracks.append(camera.track(ref_id + j, None, "referee", frames, xy, 6.0, []))
        events = self._raw_events(fps, camera)
        homographies = [Homography(matrix=invert_homography(h_c2p), reprojection_error_px=0.0, source="model")]
        warning = PipelineWarning(code="NO_COURT_HOMOGRAPHY", message="Synthetic film without a court mapping.")
        options = {"seed": self.seed, "with_homography": with_homography, "ocr_noise": self.ocr_noise}
        tracking = TrackingResult(
            video=VideoInfo(filename=filename, fps=fps, width=_FRAME_W, height=_FRAME_H, frame_count=frame_count,
                            duration_s=self.duration_s, analysis_fps=analysis_fps, codec="h264"),
            pipeline=PipelineInfo(name="synthetic", version="1.0", models={"generator": "scout.analysis.synthetic"},
                                  options=options),
            court=CourtInfo(length_ft=L, width_ft=W, homographies=homographies if with_homography else []),
            teams=[self._team_info(team) for team in (0, 1)],
            tracks=tracks,
            ball=self._ball_samples(frames, ts, positions, ball_xy, camera, noise),
            events=events,
            rims=[RimInfo(side=side, xy_px=camera.rim(side)) for side in ("left", "right")],
            warnings=[] if with_homography else [warning],
        )
        return tracking, self._truth(events)

    def _player_tracks(
        self, frames: np.ndarray, positions: dict[str, np.ndarray], camera: _Camera, fps: float
    ) -> list[Track]:
        tracks = []
        ts = frames / fps
        for key, player in self.players.items():
            for tid, t0, t1 in player.tracks:
                keep = (ts >= t0) & (ts <= t1)
                reads = self._reads(player.jersey, frames[keep], fps)
                xy = positions[key][keep]
                tracks.append(camera.track(tid, player.team, "player", frames[keep], xy, player.height_ft, reads))
        return tracks

    def _team_info(self, team: int) -> TeamInfo:
        rgb, name = _TEAM_COLORS[team]
        count = sum(len(p.tracks) for p in self.players.values() if p.team == team)
        return TeamInfo(team_id=team, color_rgb=rgb, color_name=name, track_count=count)

    def _truth(self, events: list[RawEvent]) -> SyntheticTruth:
        track_players = {tid: p.jersey_key for p in self.players.values() for tid, _t0, _t1 in p.tracks}
        box, score = _tally(events, track_players)
        lines = {p.jersey_key: box.get(p.jersey_key, _empty_line()) for p in self.players.values()}
        plays = sorted(self.truth_plays, key=lambda p: p["start_t"])
        return SyntheticTruth(
            box=lines, plays=plays, score=score, possessions=self.truth_possessions, track_players=track_players
        )

    def _reads(self, jersey: str, frames: np.ndarray, fps: float) -> list[JerseyRead]:
        """A jersey read every few seconds; ``ocr_noise`` of them are confused or partial."""
        reads: list[JerseyRead] = []
        if not len(frames):
            return reads
        t, end = frames[0] / fps + self.rng.uniform(0.3, 2.0), frames[-1] / fps
        while t < end:
            f = int(frames[min(len(frames) - 1, int(np.searchsorted(frames, t * fps)))])
            if self.rng.random() < self.ocr_noise:
                text, conf = _noisy_read(jersey, self.rng), self.rng.uniform(0.3, 0.7)
            else:
                text, conf = jersey, self.rng.uniform(0.6, 0.97)
            reads.append(JerseyRead(frame=f, text=text, conf=round(conf, 2)))
            t += self.rng.uniform(1.5, 4.5)
        return reads

    def _ball_samples(
        self,
        frames: np.ndarray,
        ts: np.ndarray,
        positions: dict[str, np.ndarray],
        ball_xy: np.ndarray,
        camera: _Camera,
        noise: np.random.Generator,
    ) -> list[BallSample]:
        """One ball sample per analysed frame (2% detection dropouts); holder ids match the script."""
        ground, height = ball_xy.copy(), np.full(len(ts), 0.4)
        holders: list[int | None] = [None] * len(ts)
        for i, t in enumerate(ts.tolist()):
            t0, kind, data = self.ball_state(t)
            if kind == "held":
                ground[i] = positions[data][i] + (0.4, 0.3)
                height[i] = 3.5
                holders[i] = self.track_of(data, t)
            elif kind == "flight":
                f = min(1.0, max(0.0, (t - t0) / max(data[2] - t0, 1e-6)))
                height[i] = 6.0 + 4.0 * f + 4.0 * data[3] * f * (1.0 - f) * 0.5
        px = camera.lift(ground, height)
        keep = noise.random(len(ts)) >= 0.02
        keep[1:] |= ~keep[:-1]  # never two dropouts in a row
        conf = np.round(noise.uniform(0.7, 0.98, len(ts)), 2)
        samples = []
        for i in np.flatnonzero(keep).tolist():
            court_xy = (round(float(ground[i, 0]), 2), round(float(ground[i, 1]), 2)) if camera.with_court else None
            xy = (round(float(px[i, 0]), 1), round(float(px[i, 1]), 1))
            samples.append(
                BallSample(f=int(frames[i]), xy=xy, court_xy=court_xy, conf=float(conf[i]), holder_track_id=holders[i])
            )
        return samples

    def _track_ref(self, key: str, value: Any, t: float) -> Any:
        """``*_track`` attributes name players while scripting; the output needs track ids."""
        return self.track_of(value, t) if key.endswith("_track") and isinstance(value, str) else value

    def _raw_events(self, fps: float, camera: _Camera) -> list[RawEvent]:
        out = []
        for i, e in enumerate(sorted(self.events, key=lambda e: e.t)):
            frame = int(round(e.t * fps))
            attrs = {k: self._track_ref(k, v, e.t) for k, v in e.attrs.items()}
            if e.type == RawEventType.SHOT:
                spot = np.asarray([attrs["shot_court_xy"]], dtype=float)
                px = camera.lift(spot, np.zeros(1))[0]
                attrs["shot_xy_px"] = [round(float(px[0]), 1), round(float(px[1]), 1)]
                if not camera.with_court:
                    attrs["shot_court_xy"] = None
            out.append(
                RawEvent(event_id=f"ev_{i + 1:05d}", type=e.type, frame=frame, t=frame / fps,
                         track_id=self.track_of(e.actor, e.t) if e.actor else None, team_id=e.team,
                         conf=round(self.rng.uniform(0.72, 0.97), 2), attrs=attrs)
            )
        return out


# ---------------------------------------------------------------------------
# Camera, noise and bookkeeping helpers
# ---------------------------------------------------------------------------


@dataclass
class _Camera:
    """Fixed broadcast-style camera: court feet -> 1920x1080 pixels."""

    h_c2p: np.ndarray
    with_court: bool

    def px_per_ft(self, xy: np.ndarray) -> np.ndarray:
        a = apply_homography_many(self.h_c2p, xy - (0.5, 0.0))
        b = apply_homography_many(self.h_c2p, xy + (0.5, 0.0))
        return np.hypot(*(b - a).T)

    def lift(self, ground: np.ndarray, height_ft: np.ndarray) -> np.ndarray:
        """Pixel position of a point ``height_ft`` above the floor point ``ground``."""
        px = apply_homography_many(self.h_c2p, ground)
        px[:, 1] -= height_ft * self.px_per_ft(ground) * 0.9
        return px

    def rim(self, side: str) -> tuple[float, float]:
        x = COURT.basket_from_baseline_ft if side == "left" else L - COURT.basket_from_baseline_ft
        px = self.lift(np.array([[x, W / 2]]), np.array([COURT.rim_height_ft]))[0]
        return round(float(px[0]), 1), round(float(px[1]), 1)

    def track(self, tid: int, team: int | None, role: str, frames: np.ndarray, xy: np.ndarray, height_ft: float,
              reads: list[JerseyRead]) -> Track:
        samples = []
        if len(frames):
            foot = apply_homography_many(self.h_c2p, xy)
            h = height_ft * self.px_per_ft(xy)
            x1 = np.clip(foot[:, 0] - 0.21 * h, 0, _FRAME_W - 1)
            x2 = np.clip(foot[:, 0] + 0.21 * h, 0, _FRAME_W - 1)
            y1 = np.clip(foot[:, 1] - h, 0, _FRAME_H - 1)
            y2 = np.clip(foot[:, 1], 0, _FRAME_H - 1)
            for i in range(len(frames)):
                bbox = (round(float(x1[i]), 1), round(float(y1[i]), 1), round(float(x2[i]), 1), round(float(y2[i]), 1))
                court_xy = (round(float(xy[i, 0]), 2), round(float(xy[i, 1]), 2)) if self.with_court else None
                samples.append(TrackSample(f=int(frames[i]), bbox=bbox, court_xy=court_xy, conf=0.9))
        return Track(track_id=tid, team_id=team, role=role, jersey_reads=reads, samples=samples)


def _jitter(noise: np.random.Generator, ts: np.ndarray, amp: float = 0.25) -> np.ndarray:
    """Smooth per-player wobble (well below walking speed) so positions are not perfectly clean."""
    phase = noise.uniform(0, 2 * math.pi, 4)
    x = 0.6 * np.sin(2 * math.pi * ts / 2.3 + phase[0]) + 0.4 * np.sin(2 * math.pi * ts / 0.9 + phase[1])
    y = 0.6 * np.sin(2 * math.pi * ts / 2.7 + phase[2]) + 0.4 * np.sin(2 * math.pi * ts / 1.1 + phase[3])
    return amp * np.column_stack([x, y])


def _referee_paths(ball_xy: np.ndarray, dt: float = 0.1, vmax: float = 16.0) -> list[np.ndarray]:
    """Trail (near sideline), lead (far sideline) and baseline officials following the ball."""
    out = []
    for j in range(3):
        cur = np.array([L / 2 - 10.0 + 10.0 * j, -1.5 if j == 0 else W + 1.5])
        path = np.empty_like(ball_xy)
        for i, (bx, by) in enumerate(ball_xy.tolist()):
            if j == 0:
                target = (min(max(bx - 8.0, 3.0), L - 3.0), -1.5)
            elif j == 1:
                target = (min(max(bx + 10.0, 3.0), L - 3.0), W + 1.5)
            else:
                target = (1.5 if bx < L / 2 else L - 1.5, min(max(by, 6.0), W - 6.0))
            move = np.asarray(target) - cur
            dist = float(np.hypot(*move))
            if dist > vmax * dt:
                move *= vmax * dt / dist
            cur = cur + move
            path[i] = cur
        out.append(path)
    return out


def _noisy_read(jersey: str, rng: random.Random) -> str:
    """Typical OCR mistakes: one digit of a two-digit number, or a confused digit (8/3, 1/7...)."""
    if len(jersey) == 2 and rng.random() < 0.5:
        return jersey[rng.randrange(2)]
    i = rng.randrange(len(jersey))
    return jersey[:i] + _CONFUSE.get(jersey[i], jersey[i]) + jersey[i + 1 :]


_STATS = ("pts", "fgm", "fga", "tpm", "tpa", "ftm", "fta", "oreb", "dreb", "ast", "stl", "blk", "tov", "pf")


def _empty_line() -> dict[str, int]:
    return dict.fromkeys(_STATS, 0)


def _tally(events: list[RawEvent], track_players: dict[int, str]) -> tuple[dict[str, dict[str, int]], dict[str, int]]:
    """Box score lines and score from raw events, following ARCHITECTURE "Event semantics"."""
    box: dict[str, dict[str, int]] = defaultdict(_empty_line)
    score = {"scouted": 0, "other": 0}
    last_miss_side: str | None = None
    for e in events:
        key = track_players.get(e.track_id) if e.track_id is not None else None
        side = _SIDES[e.team_id].value if e.team_id in _SIDES else None
        line = box[key] if key else _empty_line()
        if e.type == RawEventType.SHOT:
            made = bool(e.attrs.get("made")) and not e.attrs.get("blocked_by_track")
            three = bool(e.attrs.get("is_three"))
            line["fga"] += 1
            line["tpa"] += three
            if made:
                points = 3 if three else 2
                line["fgm"] += 1
                line["tpm"] += three
                line["pts"] += points
                score[side or "other"] += points
                if e.attrs.get("assisted_by_track") in track_players:
                    box[track_players[e.attrs["assisted_by_track"]]]["ast"] += 1
            else:
                last_miss_side = side
            if e.attrs.get("blocked_by_track") in track_players:
                box[track_players[e.attrs["blocked_by_track"]]]["blk"] += 1
        elif e.type == RawEventType.FREE_THROW:
            line["fta"] += 1
            if e.attrs.get("made"):
                line["ftm"] += 1
                line["pts"] += 1
                score[side or "other"] += 1
            else:
                last_miss_side = side
        elif e.type == RawEventType.REBOUND:
            offensive = e.attrs.get("offensive")
            if offensive is None:
                offensive = side is not None and side == last_miss_side
            line["oreb" if offensive else "dreb"] += 1
        elif e.type == RawEventType.TURNOVER:
            line["tov"] += 1
            stealer = e.attrs.get("stolen_by_track")
            if stealer in track_players:
                box[track_players[stealer]]["stl"] += 1
        elif e.type == RawEventType.FOUL:
            line["pf"] += 1
    return dict(box), score


def generate_synthetic_game(
    *,
    seed: int = 7,
    duration_s: float = 600.0,
    fps: float = 30.0,
    analysis_fps: float = 10.0,
    with_homography: bool = True,
    ocr_noise: float = 0.15,
    filename: str = "synthetic.mp4",
) -> tuple[TrackingResult, SyntheticTruth]:
    """Return ``(tracking, truth)``. ``ocr_noise`` = share of jersey reads that are wrong/confused."""
    if duration_s <= 0 or fps <= 0 or analysis_fps <= 0:
        raise ValueError("duration_s, fps and analysis_fps must be positive")
    game = _Game(seed, float(duration_s), min(1.0, max(0.0, float(ocr_noise))))
    game.build()
    tracking, truth = game.to_tracking(float(fps), float(analysis_fps), with_homography, filename)
    logger.info("Synthetic game (seed %d, %.0f s): %d possessions, %d events, score %s",
                seed, duration_s, len(truth.possessions), len(tracking.events), truth.score)
    return tracking, truth
