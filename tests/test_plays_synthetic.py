"""Play recognition on the synthetic game: recall against the scripted plays.

The timeline/possessions come from a small builder in this file (documented event
semantics, just enough for the detectors) instead of ``scout.analysis.events``, so
these tests measure the detectors alone.
"""

from __future__ import annotations

import time

import pytest

from scout.analysis import geometry
from scout.analysis.geometry import CourtConfig
from scout.analysis.plays import detect_plays, link_plays, load_play_rules, summarize_plays
from scout.analysis.synthetic import generate_synthetic_game
from scout.analysis.tracking_index import TrackingIndex
from scout.schemas import (
    OFFENSIVE_PLAY_TYPES,
    EventType,
    Play,
    PlayerRef,
    PlayType,
    Possession,
    RawEventType,
    TeamSide,
    TimelineEvent,
    TrackAssignment,
    TrackingResult,
)

COURT = CourtConfig()
TEAM_MAP = {0: TeamSide.SCOUTED, 1: TeamSide.OTHER}


def _other(side: TeamSide) -> TeamSide:
    return TeamSide.OTHER if side == TeamSide.SCOUTED else TeamSide.SCOUTED


SIMPLE_ROWS = {
    RawEventType.PASS: EventType.PASS,
    RawEventType.TURNOVER: EventType.TURNOVER,
    RawEventType.FOUL: EventType.FOUL,
    RawEventType.SCREEN: EventType.SCREEN,
    RawEventType.PERIOD_START: EventType.PERIOD_START,
    RawEventType.PERIOD_END: EventType.PERIOD_END,
    RawEventType.JUMP_BALL: EventType.JUMP_BALL,
}


def build_rows(tracking: TrackingResult, court: CourtConfig, players: dict[int, str]) -> list[TimelineEvent]:
    """Raw events -> timeline rows: shots with zone/points, FTs, rebounds, turnovers, fouls, passes, periods."""
    rows: list[TimelineEvent] = []
    last_miss: TeamSide | None = None
    for e in sorted(tracking.events, key=lambda e: e.frame):
        side = TEAM_MAP.get(e.team_id) if e.team_id is not None else None
        player = PlayerRef(jersey=players[e.track_id].split("#")[1], side=side) if e.track_id in players else None
        base = {"id": f"r{len(rows)}", "t": e.t, "frame": e.frame, "side": side, "player": player,
                "source_event_id": e.event_id, "label": e.type.value}
        made = bool(e.attrs.get("made")) and not e.attrs.get("blocked_by_track")
        if e.type == RawEventType.SHOT:
            xy = tuple(e.attrs["shot_court_xy"]) if e.attrs.get("shot_court_xy") else None
            three = geometry.is_three(court, xy) if xy else bool(e.attrs.get("is_three"))
            zone = geometry.classify_shot(court, xy)[0] if xy else None
            points = (3 if three else 2) if made else 0
            row_type = EventType.SHOT_MADE if made else EventType.SHOT_MISSED
            rows.append(TimelineEvent(type=row_type, points=points, is_three=three, zone=zone, court_xy=xy, **base))
        elif e.type == RawEventType.FREE_THROW:
            row_type = EventType.FT_MADE if made else EventType.FT_MISSED
            rows.append(TimelineEvent(type=row_type, points=int(made), **base))
        elif e.type == RawEventType.REBOUND:
            offensive = e.attrs.get("offensive")
            offensive = side == last_miss if offensive is None else offensive
            rows.append(TimelineEvent(type=EventType.OREB if offensive else EventType.DREB, **base))
        elif e.type in SIMPLE_ROWS:
            row = TimelineEvent(type=SIMPLE_ROWS[e.type], **base)
            if e.type == RawEventType.JUMP_BALL:
                row.side = TEAM_MAP.get(e.attrs.get("won_by_team"))
            if e.type == RawEventType.TURNOVER and e.attrs.get("kind") == "steal":
                row.description = "steal"
            rows.append(row)
        if e.type in (RawEventType.SHOT, RawEventType.FREE_THROW) and not made:
            last_miss = side
    return rows


class _PossessionBuilder:
    """Possessions change on a made FG / last made FT, defensive rebound, turnover, jump ball, period start."""

    def __init__(self, rows: list[TimelineEvent], fps: float) -> None:
        self.rows, self.fps = rows, fps
        self.out: list[Possession] = []
        self.cur: dict | None = None

    def close(self, frame: int) -> None:
        if self.cur is not None:
            start, end = self.cur["frame"], max(frame, self.cur["frame"] + 1)
            self.out.append(Possession(id=len(self.out), side=self.cur["side"], start_frame=start, end_frame=end,
                                       start_t=start / self.fps, end_t=end / self.fps, start_reason=self.cur["reason"],
                                       points=self.cur["points"]))
        self.cur = None

    def open(self, side: TeamSide, frame: int, reason: str) -> None:
        self.close(frame)
        self.cur = {"side": side, "frame": frame, "reason": reason, "points": 0}

    def free_throw_follows(self, i: int, side: TeamSide) -> bool:
        limit = self.rows[i].frame + 3 * self.fps
        free_throws = (EventType.FT_MADE, EventType.FT_MISSED)
        return any(r.type in free_throws and r.side == side and r.frame <= limit for r in self.rows[i + 1 :])

    def build(self) -> list[Possession]:
        for i, r in enumerate(self.rows):
            if r.type in (EventType.PERIOD_START, EventType.PERIOD_END):
                self.close(r.frame)
            elif r.type == EventType.JUMP_BALL and r.side is not None:
                self.open(r.side, r.frame, "jump_ball")
            elif r.side is not None:
                self.step(i, r)
        if self.rows:
            self.close(self.rows[-1].frame)
        return self.out

    def step(self, i: int, r: TimelineEvent) -> None:
        if self.cur is None:
            if r.type == EventType.FOUL:
                return
            self.open(r.side, r.frame, "period_start")
        if r.type in (EventType.SHOT_MADE, EventType.FT_MADE):
            self.cur["points"] += r.points
            if not self.free_throw_follows(i, r.side):
                self.open(_other(r.side), r.frame, "made_basket")
        elif r.type == EventType.DREB and r.side != self.cur["side"]:
            self.open(r.side, r.frame, "def_rebound")
        elif r.type == EventType.TURNOVER:
            self.open(_other(r.side), r.frame, "steal" if r.description == "steal" else "turnover")


def build_possessions(rows: list[TimelineEvent], fps: float) -> list[Possession]:
    return _PossessionBuilder(rows, fps).build()


def overlaps(a0: float, a1: float, b0: float, b1: float, slack: float = 0.5) -> bool:
    return a0 <= b1 + slack and b0 <= a1 + slack


def run_detection(
    seed: int = 7, *, duration_s: float = 600.0, with_homography: bool = True, analysis_fps: float = 10.0
):
    """Synthetic game -> minimal timeline/possessions -> detect_plays (plus the time detection took)."""
    tracking, truth = generate_synthetic_game(
        seed=seed, duration_s=duration_s, with_homography=with_homography, analysis_fps=analysis_fps
    )
    index = TrackingIndex(tracking, COURT)
    rows = build_rows(tracking, COURT, truth.track_players)
    possessions = build_possessions(rows, tracking.video.fps)
    assignments = [TrackAssignment(track_id=t.track_id, team_id=t.team_id, side=TEAM_MAP.get(t.team_id), role=t.role)
                   for t in tracking.tracks]
    started = time.perf_counter()
    plays = detect_plays(index, rows, possessions, assignments, TEAM_MAP, COURT, load_play_rules())
    return plays, truth, rows, possessions, time.perf_counter() - started


def found(plays: list[Play], scripted: dict, *, slack: float = 0.5) -> list[Play]:
    """Detected plays of the scripted side overlapping the scripted time window."""
    return [p for p in plays if p.side is not None and p.side.value == scripted["side"]
            and overlaps(p.start_t, p.end_t, scripted["start_t"], scripted["end_t"], slack)]


@pytest.fixture(scope="module", params=[7, 11])
def detected(request):
    return run_detection(request.param)


def test_offensive_recall(detected):
    plays, truth, *_ = detected
    scripted = [p for p in truth.plays if p["category"] == "offense"]
    hits = [any(p.type.value == s["type"] for p in found(plays, s)) for s in scripted]
    assert len(scripted) >= 30 and sum(hits) / len(scripted) >= 0.7, (sum(hits), len(scripted))
    for play_type in {s["type"] for s in scripted}:  # every scripted kind is recognised at least once
        assert any(h for h, s in zip(hits, scripted, strict=True) if s["type"] == play_type), play_type


def test_man_zone_labels_shapes_and_press(detected):
    plays, truth, *_ = detected
    looks = [p for p in truth.plays if p["type"] in ("man_defense", "zone_defense")]
    defense = (PlayType.MAN_DEFENSE, PlayType.ZONE_DEFENSE)
    labels = [[p for p in found(plays, s, slack=0.0) if p.type in defense] for s in looks]
    right = sum(any(p.type.value == s["type"] for p in got) for s, got in zip(looks, labels, strict=True))
    assert len(looks) >= 20 and right / len(looks) >= 0.7, (right, len(looks))
    zones = [(s, got) for s, got in zip(looks, labels, strict=True) if s["type"] == "zone_defense"]
    shapes = sum(any(p.attrs.get("zone_shape") == s["zone_shape"] for p in got) for s, got in zones)
    assert zones and shapes / len(zones) >= 0.7
    presses = [p for p in truth.plays if p["type"] == "press"]
    assert all(any(p.type == PlayType.PRESS for p in found(plays, s, slack=1.0)) for s in presses)
    assert sum(p.type == PlayType.PRESS for p in plays) <= len(presses) + 1


def test_plays_are_well_formed_and_link(detected):
    plays, _truth, rows, possessions, _elapsed = detected
    assert [p.id for p in plays] == [f"pl_{i}" for i in range(1, len(plays) + 1)]
    assert [p.start_t for p in plays] == sorted(p.start_t for p in plays)
    assert all(p.start_t <= p.end_t and 0 < p.confidence <= 1 and p.description for p in plays)
    assert all(p.category == ("offense" if p.type in OFFENSIVE_PLAY_TYPES else "defense") for p in plays)
    link_plays(rows, possessions, plays)
    shots = [r for r in rows if r.type in (EventType.SHOT_MADE, EventType.SHOT_MISSED)]
    assert sum(r.play_id is not None for r in shots) / len(shots) >= 0.8  # misses before a putback stay unlinked
    assert sum(bool(p.play_ids) for p in possessions) / len(possessions) >= 0.8
    summary = summarize_plays(plays, possessions)
    assert summary[0].side == TeamSide.SCOUTED
    assert all(s.possessions_pct is None or 0 < s.possessions_pct <= 1 for s in summary)


def test_pixel_mode_on_the_synthetic_game():
    plays, truth, *_ = run_detection(7, with_homography=False)
    court_only = {PlayType.PICK_AND_ROLL, PlayType.PICK_AND_POP, PlayType.ISOLATION, PlayType.POST_UP, PlayType.CUT,
                  PlayType.PRESS}
    assert plays and not {p.type for p in plays} & court_only
    assert max(p.confidence for p in plays) <= 0.8 * 0.6 + 1e-9
    looks = [p for p in truth.plays if p["type"] in ("man_defense", "zone_defense")]
    right = sum(any(p.type.value == s["type"] for p in found(plays, s, slack=0.0)) for s in looks)
    assert right / len(looks) >= 0.7
    breaks = [p for p in truth.plays if p["type"] == "fast_break"]
    assert sum(any(p.type == PlayType.FAST_BREAK for p in found(plays, s)) for s in breaks) / len(breaks) >= 0.7


def test_sixty_minute_game_runs_well_under_a_minute():
    plays, truth, _rows, possessions, elapsed = run_detection(3, duration_s=3600.0, analysis_fps=15.0)
    assert len(possessions) > 200 and len(plays) > 300
    assert elapsed < 20.0, f"detection took {elapsed:.1f} s"
