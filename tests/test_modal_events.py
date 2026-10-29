"""Supplementary event detection (modal_app.pipeline.events) and the ball-holder fallback
(modal_app.pipeline.possession) on hand-built Perception scenarios.

The fake camera maps court feet to pixels at 20 px/ft everywhere (a 6 ft player is a
120 px bbox), so pixel-only mode measures the same distances as court mode.
"""

from __future__ import annotations

import json
import math
import time
from collections.abc import Callable
from typing import Any

import numpy as np
import pytest

from modal_app.pipeline.events import EventConfig, detect_events, enrich_events
from modal_app.pipeline.possession import assign_ball_holders
from modal_app.pipeline.types import BallObs, Perception, RimObs, TrackData, TrackObs, VideoMeta
from scout.schemas import RawEvent

FPS = 30.0
STEP = 2  # analysed at 15 fps
PX_PER_FT = 20.0
BOX_H = 6 * PX_PER_FT
LENGTH, WIDTH = 84.0, 50.0

XY = tuple[float, float]
XYZ = tuple[float, float, float]


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


def to_px(x: float, y: float, z: float = 0.0) -> XY:
    """Fake camera: far sideline at the top of the image, height straight up."""
    return (60.0 + PX_PER_FT * x, 1060.0 - PX_PER_FT * (y + z))


def make_perception(duration_s: float) -> Perception:
    frames = int(round(duration_s * FPS))
    video = VideoMeta(
        path="film.mp4", filename="film.mp4", fps=FPS, width=1920, height=1080, frame_count=frames,
        duration_s=duration_s, analysis_fps=FPS / STEP, step=STEP,
    )  # fmt: skip
    return Perception(video=video, court_length_ft=LENGTH, court_width_ft=WIDTH)


def analysed(p: Perception) -> list[tuple[int, float]]:
    """(frame, t) of every analysed frame."""
    return [(k * STEP, k * STEP / FPS) for k in range(p.video.frame_count // STEP)]


def keyframes(*keys: tuple[float, ...]) -> Callable[[float], tuple[float, ...]]:
    """Piecewise-linear path through (t, values...) keys; holds still outside them."""
    ts = [k[0] for k in keys]
    columns = list(zip(*(k[1:] for k in keys), strict=True))
    return lambda t: tuple(float(np.interp(t, ts, col)) for col in columns)


def still(x: float, y: float) -> Callable[[float], XY]:
    return lambda t: (x, y)


def add_player(
    p: Perception,
    tid: int,
    team: int | None,
    path: Callable[[float], Any],
    *,
    role: str = "player",
    court: bool = True,
    wrists: Callable[[float], XY | None] | None = None,
) -> None:
    """A track following ``path(t) -> (x, y) | None`` (court feet); optional wrist pixels."""
    obs = []
    for frame, t in analysed(p):
        xy = path(t)
        if xy is None:
            continue
        fx, fy = to_px(*xy)
        keypoints = None
        if wrists is not None and (w := wrists(t)) is not None:
            keypoints = [(fx, fy - 60.0, 0.9)] * 17
            keypoints[9] = keypoints[10] = (w[0], w[1], 0.9)
        bbox = (fx - 20, fy - BOX_H, fx + 20, fy)
        court_xy = tuple(xy) if court else None
        obs.append(TrackObs(frame=frame, bbox=bbox, conf=0.9, court_xy=court_xy, keypoints=keypoints))
    p.tracks[tid] = TrackData(track_id=tid, obs=obs, team_id=team, role=role)


def add_ball(
    p: Perception,
    path: Callable[[float], XYZ | None],
    holder: Callable[[float], int | None] = lambda t: None,
    *,
    court: bool = True,
) -> None:
    """Ball detections from ``path(t) -> (x, y, z) | None`` (feet, z = height)."""
    for frame, t in analysed(p):
        pos = path(t)
        if pos is None:
            continue
        x, y, z = pos
        court_xy = (x, y) if court else None
        p.ball.append(BallObs(frame=frame, xy=to_px(x, y, z), conf=0.9, court_xy=court_xy, holder_track_id=holder(t)))


def ev(
    event_id: str, type_: str, t: float, track: int | None = None, team: int | None = None, **attrs: Any
) -> dict[str, Any]:
    """A RawEvent dict as the OHV adapter would produce it."""
    frame = int(round(t * FPS))
    return {
        "event_id": event_id, "type": type_, "frame": frame, "t": frame / FPS,
        "track_id": track, "team_id": team, "conf": 0.8, "attrs": attrs,
    }  # fmt: skip


def of_type(events: list[dict[str, Any]], kind: str) -> list[dict[str, Any]]:
    return [e for e in events if e["type"] == kind]


def right_rim() -> RimObs:
    rx, ry = to_px(LENGTH - 5.25, WIDTH / 2, 10.0)
    return RimObs(side="right", xy_px=(rx, ry), bbox=(rx - 15, ry - 5, rx + 15, ry + 5))


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------


def free_throw_trip(*, court: bool = True, guarded: bool = False) -> Perception:
    """Track 1 (team 0) drives and shoots at t=10 with track 11 draped on him, everyone walks
    to a free-throw line-up at the right basket, then two free throws: made at t=26, missed at t=34.

    ``guarded`` puts track 13 right next to the shooter instead (live play at the high post)."""
    p = make_perception(40.0)
    paths: dict[int, tuple[int, list[tuple[float, float]]]] = {
        # tid: (team, [(x, y) at t=0, 10, 20 (line-up), 40])
        1: (0, [(50, 25), (72, 26), (65, 25), (70, 32)]),  # shooter
        11: (1, [(51, 26), (73, 27), (77, 17.5), (74, 22)]),  # his defender
        12: (1, [(60, 40), (70, 38), (77, 32.5), (75, 30)]),
        2: (0, [(62, 8), (74, 12), (73, 17.5), (70, 20)]),
        3: (0, [(62, 44), (70, 42), (73, 32.5), (72, 35)]),
        4: (0, [(45, 10), (55, 8), (55, 10), (60, 12)]),
        5: (0, [(45, 40), (55, 42), (55, 40), (60, 38)]),
        13: (1, [(55, 25), (66, 20), (63.5, 25.5) if guarded else (52, 25), (58, 25)]),
        14: (1, [(50, 12), (62, 10), (58, 5), (62, 10)]),
        15: (1, [(50, 38), (62, 36), (58, 45), (62, 40)]),
    }
    for tid, (team, (p0, p10, p20, p40)) in paths.items():
        add_player(p, tid, team, keyframes((0, *p0), (10, *p10), (20, *p20), (35.5, *p20), (40, *p40)), court=court)
    add_player(p, 90, None, keyframes((0, 50, 2), (40, 70, 2)), role="referee", court=court)
    drive = keyframes((0, 50, 25), (10, 72, 26))
    made_flight = keyframes((26, 65, 25, 7), (26.5, 71.9, 25, 12.5), (27, 78.75, 25, 10), (27.4, 78.75, 25, 4))
    miss_flight = keyframes(  # off the front of the rim and back out
        (34, 65, 25, 7), (34.5, 71.5, 25, 12.6), (35, 78, 25, 10.2), (35.3, 75.5, 25, 12), (35.6, 73, 25, 6)
    )

    def ball(t: float) -> XYZ | None:
        if t < 10:
            return (*drive(t), 3.5)
        if 22.5 <= t < 26 or 31 <= t < 34:
            return (65.0, 25.0, 4.0)  # still, at the shooter's chest
        if 26 <= t <= 27.4:
            return made_flight(t)  # type: ignore[return-value]
        if 34 <= t <= 35.6:
            return miss_flight(t)  # type: ignore[return-value]
        return None

    add_ball(p, ball, lambda t: 1 if t < 10 or 22.5 <= t < 26 or 31 <= t < 34 else None, court=court)
    p.rims.append(right_rim())
    return p


def screen_play(*, screener_moves: bool = False, court: bool = True) -> Perception:
    """Track 1 dribbles up the floor at 8 ft/s, guarded by track 11, past teammate track 2."""
    p = make_perception(6.0)
    add_player(p, 1, 0, keyframes((1, 60, 12), (4.5, 60, 40)), court=court)
    add_player(p, 11, 1, keyframes((1, 60.5, 9.5), (4.5, 60.5, 37.5)), court=court)
    if screener_moves:  # jogs past the handler the other way: players merely passing each other
        add_player(p, 2, 0, keyframes((1, 61.5, 40), (4.5, 61.5, 12)), court=court)
    else:
        add_player(p, 2, 0, still(61.5, 27), court=court)
    add_player(p, 3, 0, still(66, 27), court=court)  # stationary, but 6 ft from the handler's path
    add_player(p, 4, 0, still(45, 5), court=court)
    add_player(p, 5, 0, still(45, 45), court=court)
    for tid, xy in {12: (50, 8), 13: (50, 42), 14: (72, 30), 15: (40, 25)}.items():
        add_player(p, tid, 1, still(*xy), court=court)
    handler = keyframes((1, 60, 12), (4.5, 60, 40))
    add_ball(p, lambda t: (*handler(t), 3.5), lambda t: 1, court=court)  # type: ignore[arg-type]
    return p


def tip_off() -> Perception:
    """Jump ball at centre court: the referee tosses at t=1, peak at t=1.5, tipped to track 12 (team 1)."""
    p = make_perception(10.0)
    add_player(p, 1, 0, keyframes((1.5, 41, 25), (3, 35, 30)))
    add_player(p, 11, 1, keyframes((1.5, 43, 25), (3, 50, 20)))
    for tid, xy in {2: (35, 18), 3: (35, 32), 4: (30, 25), 5: (42, 12)}.items():
        add_player(p, tid, 0, still(*xy))
    for tid, xy in {12: (49, 18), 13: (49, 32), 14: (54, 25), 15: (42, 38)}.items():
        add_player(p, tid, 1, still(*xy))
    add_player(p, 90, None, still(42, 23), role="referee")
    tap = keyframes((1.5, 42, 25, 13), (2, 49, 18, 4))

    def ball(t: float) -> XYZ:
        if t < 1:
            return (42.0, 25.0, 4.0)  # in the referee's hands
        if t <= 1.5:
            return (42.0, 25.0, 4 + 18 * (t - 1))
        if t < 2:
            return tap(t)  # type: ignore[return-value]
        return (49.0, 18.0, 3.5)

    add_ball(p, ball, lambda t: 12 if t >= 2 else None)
    return p


def game_with_breaks() -> Perception:
    """500 s of play with everyone at the benches during 300-370 s (a 70 s stoppage) and
    420-450 s (30 s: too short to count as a stoppage)."""
    p = make_perception(500.0)

    def at_bench(t: float) -> bool:
        return 300 <= t < 370 or 420 <= t < 450

    def path(i: int) -> Callable[[float], XY]:
        def where(t: float) -> XY:
            if at_bench(t):
                return (30.0 + 2 * i, -5.0)
            return (20.0 + 6 * i + 3 * math.sin(t / 7 + i), 10.0 + 3 * i + 3 * math.cos(t / 5 + i))

        return where

    for i, tid in enumerate([1, 2, 3, 4, 5, 11, 12, 13, 14, 15]):
        add_player(p, tid, 0 if tid < 10 else 1, path(i))
    handler = path(0)
    add_ball(p, lambda t: None if at_bench(t) else (*handler(t), 3.5), lambda t: None if at_bench(t) else 1)
    return p


# ---------------------------------------------------------------------------
# Free throws and fouls
# ---------------------------------------------------------------------------


def test_two_shot_free_throw_trip_with_inferred_shooting_foul():
    p = free_throw_trip()
    existing = [ev("e1", "shot", 10.0, track=1, team=0, made=False)]
    extra = detect_events(p, existing_events=existing)

    fts = of_type(extra, "free_throw")
    assert [ft["track_id"] for ft in fts] == [1, 1]
    assert [ft["team_id"] for ft in fts] == [0, 0]
    assert [ft["attrs"]["made"] for ft in fts] == [True, False]
    assert fts[0]["t"] == pytest.approx(26.0, abs=0.2)
    assert fts[1]["t"] == pytest.approx(34.0, abs=0.2)
    assert all("replaces_event_id" not in ft["attrs"] for ft in fts)

    (foul,) = of_type(extra, "foul")
    assert foul["track_id"] == 11 and foul["team_id"] == 1
    assert foul["attrs"] == {"kind": "shooting", "fouled_track": 1}
    assert foul["frame"] == existing[0]["frame"]
    assert foul["conf"] <= 0.35


def test_free_throw_replaces_coinciding_shot_event():
    p = free_throw_trip()
    existing = [
        ev("e1", "shot", 10.0, track=1, team=0, made=False),
        ev("e7", "shot", 26.1, track=1, team=0, made=True),  # OHV saw the first free throw as a jump shot
    ]
    extra = detect_events(p, existing_events=existing)
    first, second = of_type(extra, "free_throw")
    assert first["attrs"]["replaces_event_id"] == "e7"
    assert "replaces_event_id" not in second["attrs"]
    (foul,) = of_type(extra, "foul")  # still inferred from the real field-goal attempt
    assert foul["frame"] == existing[0]["frame"]


def test_free_throw_without_rim_evidence_takes_made_from_the_replaced_shot():
    p = free_throw_trip()
    p.rims.clear()
    existing = [ev("e7", "shot", 26.0, track=1, team=0, made=True), ev("e8", "shot", 34.0, track=1, team=0)]
    first, second = of_type(detect_events(p, existing_events=existing), "free_throw")
    assert first["attrs"] == {"made": True, "replaces_event_id": "e7"}
    assert second["attrs"] == {"made": None, "replaces_event_id": "e8"}


def test_no_foul_when_play_continued_after_the_shot():
    p = free_throw_trip()
    existing = [
        ev("e1", "shot", 10.0, track=1, team=0, made=False),
        ev("e2", "turnover", 14.0, track=13, team=1, kind="other"),
    ]
    extra = detect_events(p, existing_events=existing)
    assert len(of_type(extra, "free_throw")) == 2
    assert of_type(extra, "foul") == []


def test_no_foul_when_two_defenders_are_equally_close():
    p = free_throw_trip()
    for o in p.tracks[13].obs:
        if o.frame == 300:  # at the shot, as close to the shooter as track 11
            o.court_xy = (71.0, 27.0)
    extra = detect_events(p, existing_events=[ev("e1", "shot", 10.0, track=1, team=0, made=False)])
    assert of_type(extra, "foul") == []


def test_no_free_throw_when_the_shooter_is_guarded():
    existing = [ev("e1", "shot", 10.0, track=1, team=0, made=False)]
    extra = detect_events(free_throw_trip(guarded=True), existing_events=existing)
    assert of_type(extra, "free_throw") == [] and of_type(extra, "foul") == []


def test_pixel_only_mode_skips_free_throws():
    p = free_throw_trip(court=False)
    extra = detect_events(p, existing_events=[ev("e1", "shot", 10.0, track=1, team=0, made=False)])
    assert of_type(extra, "free_throw") == [] and of_type(extra, "foul") == [] and of_type(extra, "jump_ball") == []


def test_existing_free_throws_are_not_detected_again():
    p = free_throw_trip()
    existing = [
        ev("f1", "free_throw", 26.0, track=1, team=0, made=True),
        ev("sx00001", "shot", 10.0, track=1, team=0, made=False),
    ]
    extra = detect_events(p, existing_events=existing)
    fts = of_type(extra, "free_throw")
    assert [round(ft["t"]) for ft in fts] == [34]
    assert of_type(extra, "foul")  # the trip (existing + new attempt) still gets its foul
    ids = [e["event_id"] for e in extra]
    assert len(set(ids)) == len(ids) and "sx00001" not in ids and all(i.startswith("sx") for i in ids)


# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------


def test_on_ball_screen_detected():
    (screen,) = of_type(detect_events(screen_play()), "screen")
    assert screen["track_id"] == 2 and screen["team_id"] == 0
    assert screen["attrs"] == {"ball_handler_track": 1, "on_ball": True}
    assert screen["t"] == pytest.approx(2.875, abs=0.2)  # when the handler brushes past at y=27
    assert 0.5 <= screen["conf"] <= 1


def test_no_screen_when_players_merely_pass_each_other():
    assert of_type(detect_events(screen_play(screener_moves=True)), "screen") == []


def test_screen_in_pixel_only_mode():
    (screen,) = of_type(detect_events(screen_play(court=False)), "screen")
    assert screen["track_id"] == 2 and screen["attrs"]["ball_handler_track"] == 1


def test_screen_survives_track_gaps_and_never_uses_referees():
    p = screen_play()
    screener = p.tracks[2]
    screener.obs = [o for o in screener.obs if not 2.6 <= o.frame / FPS <= 2.9]  # 0.3 s dropout at the screen
    assert [s["track_id"] for s in of_type(detect_events(p), "screen")] == [2]
    screener.role = "referee"
    assert of_type(detect_events(p), "screen") == []


def test_existing_screen_is_not_duplicated():
    p = screen_play()
    existing = [ev("o1", "screen", 2.8, track=2, team=0, ball_handler_track=1, on_ball=True)]
    assert of_type(detect_events(p, existing_events=existing), "screen") == []


# ---------------------------------------------------------------------------
# Jump balls and periods
# ---------------------------------------------------------------------------


def test_jump_ball_at_the_start():
    extra = detect_events(tip_off())
    (jump,) = of_type(extra, "jump_ball")
    assert jump["attrs"] == {"won_by_team": 1}
    assert jump["team_id"] == 1 and jump["track_id"] is None
    assert jump["t"] == pytest.approx(1.5, abs=0.1)
    assert jump["conf"] >= 0.8
    (start,) = of_type(extra, "period_start")
    assert start["attrs"] == {"period": 1} and start["frame"] == jump["frame"] and start["team_id"] == 1
    assert extra.index(start) < extra.index(jump)


def test_period_boundary_after_long_stoppage_only():
    # A quarter break needs 7 minutes of live play on both sides; with less it is a timeout.
    cfg = EventConfig(period_min_live_s=90.0, period_quarter_max_share=0.8)  # 300 s | 70 s | 100 s of play
    extra = detect_events(game_with_breaks(), cfg)
    starts, ends = of_type(extra, "period_start"), of_type(extra, "period_end")
    assert [(s["attrs"]["period"], round(s["t"])) for s in starts] == [(1, 0), (2, 370)]
    assert [(e["attrs"]["period"], round(e["t"])) for e in ends] == [(1, 300)]
    assert starts[1]["team_id"] == 0  # first holder after the break
    assert 0.4 <= ends[0]["conf"] < 0.6  # a 70 s break could still be a timeout
    assert of_type(extra, "jump_ball") == [] and of_type(extra, "timeout") == []


def test_stoppage_without_enough_play_around_it_is_a_timeout():
    extra = detect_events(game_with_breaks())
    assert of_type(extra, "period_end") == [] and len(of_type(extra, "period_start")) == 1
    (timeout,) = of_type(extra, "timeout")  # the 30 s break is too short to be one
    assert round(timeout["t"]) == 300 and timeout["attrs"] == {"inferred": True} and timeout["team_id"] is None


# ---------------------------------------------------------------------------
# enrich_events
# ---------------------------------------------------------------------------


def passing_play() -> Perception:
    """Track 1 holds until t=10, passes to track 2 who catches at t=10.4 and keeps it to t=13."""
    p = make_perception(20.0)
    add_player(p, 1, 0, still(60, 20))
    add_player(p, 2, 0, still(70, 30))
    add_player(p, 11, 1, still(62, 22))
    add_player(p, 90, None, still(60, 2), role="referee")
    add_ball(p, lambda t: (60.0, 20.0, 3.5), lambda t: 1 if 9 <= t < 10 else (2 if 10.4 <= t < 13 else None))
    return p


@pytest.mark.parametrize(
    ("pass_event", "shot_t", "made", "expected"),
    [
        (ev("p", "pass", 10.0, track=1, team=0, to_track=2), 11.8, True, 1),
        (ev("p", "pass", 10.0, track=1, team=0, to_track=2, completed=False), 11.8, True, None),
        (ev("p", "pass", 10.0, track=11, team=1, to_track=2), 11.8, True, None),  # from the other team
        (ev("p", "pass", 10.0, track=90, to_track=2), 11.8, True, None),  # referee
        (ev("p", "pass", 10.0, track=1, team=0, to_track=2), 12.6, True, None),  # held 2.2 s after the catch
        (ev("p", "pass", 10.0, track=1, team=0, to_track=2), 13.5, True, None),  # outside the 3 s window
        (ev("p", "pass", 10.0, track=1, team=0, to_track=2), 11.8, False, None),  # missed shots get no assist
        (ev("p", "pass", 10.0, track=1, to_track=2), 11.8, True, 1),  # passer's team from his track
    ],
)
def test_assist_only_for_completed_same_team_pass_in_window(pass_event, shot_t, made, expected):
    events = [pass_event, ev("s", "shot", shot_t, track=2, team=0, made=made)]
    out = enrich_events(passing_play(), events)
    assert out[1]["attrs"].get("assisted_by_track") == expected
    assert events[1]["attrs"].get("assisted_by_track") is None  # inputs are not modified


def test_no_assist_across_a_rebound_or_when_the_shooter_passed_it_on():
    p = passing_play()
    rebound = [
        ev("p", "pass", 10.0, track=1, team=0, to_track=2),
        ev("r", "rebound", 11.0, track=2, team=0),
        ev("s", "shot", 11.8, track=2, team=0, made=True),
    ]
    assert enrich_events(p, rebound)[2]["attrs"].get("assisted_by_track") is None
    passed_on = [
        ev("p1", "pass", 10.0, track=1, team=0, to_track=2),
        ev("p2", "pass", 10.8, track=2, team=0, to_track=1),
        ev("s", "shot", 11.8, track=2, team=0, made=True),
    ]
    assert enrich_events(p, passed_on)[2]["attrs"].get("assisted_by_track") is None


def test_rebound_side_inferred_from_the_preceding_miss():
    p = passing_play()
    events = [
        ev("s1", "shot", 5.0, track=1, team=0, made=False),
        ev("r1", "rebound", 6.0, track=2, team=0),  # shooter's team: offensive
        ev("s2", "shot", 8.0, track=2, team=0, made=None),
        ev("r2", "rebound", 9.0, track=11),  # other team (from its track): defensive
        ev("s3", "shot", 14.0, track=1, team=0, made=True),
        ev("r3", "rebound", 14.5, track=2, team=0),  # after a make: cannot tell
        ev("s4", "shot", 16.0, track=1, team=0, made=False),
        ev("r4", "rebound", 17.0, track=2, team=0, offensive=False),  # already set: kept
    ]
    out = {e["event_id"]: e for e in enrich_events(p, events)}
    assert out["r1"]["attrs"]["offensive"] is True
    assert out["r2"]["attrs"]["offensive"] is False
    assert out["r3"]["attrs"].get("offensive") is None
    assert out["r4"]["attrs"]["offensive"] is False


def block_play(*, blocked: bool) -> Perception:
    """Track 1 (team 0) shoots at t=20 from (70, 25); track 11 (team 1) stands at (72, 25) with
    his hands up where the ball goes; when ``blocked`` the ball comes straight back off them."""
    p = make_perception(25.0)
    contact = to_px(71.5, 25, 8.9)
    add_player(p, 1, 0, still(70, 25))
    add_player(p, 11, 1, still(72, 25), wrists=lambda t: contact)
    add_player(p, 2, 0, still(71, 27))  # a teammate's hands nearby must not count
    up = [(20.0, 70.3, 25, 7), (20.0667, 70.9, 25, 8.0), (20.1333, 71.5, 25, 8.9)]
    down = [(20.2, 70.9, 25, 7.6), (20.2667, 70.3, 25, 6.0), (20.4, 69.0, 25, 3.0)]
    arc = [(20.2, 72.1, 25, 9.7), (20.2667, 72.7, 25, 10.4), (20.4, 73.9, 25, 11.6)]
    flight = keyframes(*(up + (down if blocked else arc)))
    add_ball(p, lambda t: flight(t) if 20 <= t <= 20.4 else None)  # type: ignore[arg-type,return-value]
    p.rims.append(right_rim())
    return p


def test_block_from_sharp_ball_reversal_at_defender_hands():
    shot = ev("s", "shot", 20.0, track=1, team=0, made=False)
    assert enrich_events(block_play(blocked=True), [shot])[0]["attrs"]["blocked_by_track"] == 11
    assert enrich_events(block_play(blocked=False), [shot])[0]["attrs"].get("blocked_by_track") is None
    made = ev("s", "shot", 20.0, track=1, team=0, made=True)
    assert enrich_events(block_play(blocked=True), [made])[0]["attrs"].get("blocked_by_track") is None


def test_enrich_never_overwrites_existing_values():
    p = block_play(blocked=True)
    events = [
        ev("p", "pass", 18.5, track=2, team=0, to_track=1),
        ev("s", "shot", 20.0, track=1, team=0, made=False, blocked_by_track=5),
        ev("s2", "shot", 20.0, track=1, team=0, made=True, assisted_by_track=99),
        ev("r", "rebound", 21.0, track=2, team=0, offensive=False),
    ]
    out = enrich_events(p, events)
    assert out[1]["attrs"]["blocked_by_track"] == 5
    assert out[2]["attrs"]["assisted_by_track"] == 99
    assert out[3]["attrs"]["offensive"] is False
    assert [e["event_id"] for e in out] == ["p", "s", "s2", "r"]


# ---------------------------------------------------------------------------
# assign_ball_holders
# ---------------------------------------------------------------------------

A_BOX = (100.0, 100.0, 140.0, 220.0)  # bbox height 120 px
B_BOX = (400.0, 100.0, 440.0, 220.0)
REF_BOX = (700.0, 100.0, 740.0, 220.0)


def holder_scene(ball: list[XY | None], *, a_wrists: XY | None = None) -> Perception:
    """Pixel-only perception: players 1 (A) and 2 (B), referee 9, and a ball path (one entry per analysed frame)."""
    p = make_perception(len(ball) * STEP / FPS)
    players = {1: (A_BOX, a_wrists, "player"), 2: (B_BOX, None, "player"), 9: (REF_BOX, None, "referee")}
    for tid, (box, wrist, role) in players.items():
        keypoints = None
        if wrist is not None:
            keypoints = [((box[0] + box[2]) / 2, box[1] + 20, 0.9)] * 17
            keypoints[9] = keypoints[10] = (wrist[0], wrist[1], 0.9)
        obs = [TrackObs(frame=k * STEP, bbox=box, conf=0.9, keypoints=keypoints) for k in range(len(ball))]
        p.tracks[tid] = TrackData(track_id=tid, obs=obs, team_id=0 if tid == 1 else 1, role=role)
    p.ball = [BallObs(frame=k * STEP, xy=xy, conf=0.9) for k, xy in enumerate(ball) if xy is not None]
    return p


def holders(p: Perception) -> list[int | None]:
    assign_ball_holders(p)
    return [b.holder_track_id for b in p.ball]


AT_A, AT_B, AT_REF, MID_AIR = (150.0, 160.0), (420.0, 140.0), (720.0, 140.0), (270.0, 40.0)


def test_holder_from_wrist_keypoints_and_bbox():
    assert holders(holder_scene([(155.0, 160.0)] * 6, a_wrists=(150.0, 160.0))) == [1] * 6
    assert holders(holder_scene([AT_A] * 6)) == [1] * 6  # no keypoints: upper half of the bbox
    # Keypoints win: the ball crosses A's face while his hands are down at his hips.
    assert holders(holder_scene([(120.0, 110.0)] * 6, a_wrists=(110.0, 210.0))) == [None] * 6


def test_holder_hysteresis():
    path = [AT_A] * 10 + [AT_B] * 2 + [AT_A] * 9 + [AT_B] * 7
    assert holders(holder_scene(path)) == [1] * 21 + [2] * 7
    assert holders(holder_scene([AT_B] * 2 + [None] * 8)) == [None] * 2  # never held long enough


def test_holder_none_in_flight_and_gaps_bridged():
    path = [AT_A] * 10 + [MID_AIR] * 6 + [AT_B] * 10
    assert holders(holder_scene(path)) == [1] * 10 + [None] * 6 + [2] * 10
    with_dropout = [AT_A] * 10 + [None] * 3 + [AT_A] * 5  # ball not detected for 3 frames
    assert holders(holder_scene(with_dropout)) == [1] * 15


def test_referee_never_holds_the_ball():
    assert holders(holder_scene([AT_REF] * 10)) == [None] * 10


def test_low_confidence_ball_is_ignored():
    p = holder_scene([AT_B] * 8)
    for b in p.ball:
        b.conf = 0.05
    assert holders(p) == [None] * 8


# ---------------------------------------------------------------------------
# Robustness, output contract, speed
# ---------------------------------------------------------------------------


def test_short_and_empty_clips():
    empty = make_perception(0.0)
    assert detect_events(empty) == [] and enrich_events(empty, []) == []
    assign_ball_holders(empty)
    tiny = make_perception(0.2)
    add_player(tiny, 1, 0, still(40, 25))
    add_ball(tiny, lambda t: (40.0, 25.0, 3.5))
    assign_ball_holders(tiny)
    assert isinstance(detect_events(tiny, existing_events=[ev("s", "shot", 0.1, track=1, made=True)]), list)


def test_new_events_follow_the_raw_event_contract():
    p = free_throw_trip()
    existing = [ev("e1", "shot", 10.0, track=1, team=0, made=False)]
    extra = detect_events(p, existing_events=existing)
    assert {e["type"] for e in extra} >= {"free_throw", "foul", "period_start"}
    json.dumps(extra)  # plain JSON types only (no numpy scalars)
    for event in extra:
        RawEvent.model_validate(event)
        assert set(event) == {"event_id", "type", "frame", "t", "track_id", "team_id", "conf", "attrs"}
        assert 0 <= event["conf"] <= 1 and event["t"] == pytest.approx(event["frame"] / FPS, abs=1e-3)
    assert [e["frame"] for e in extra] == sorted(e["frame"] for e in extra)


def synthetic_game(duration_s: float, *, seed: int = 3) -> tuple[Perception, list[dict[str, Any]]]:
    """Ten players moving smoothly, three referees, keypoints on every third frame, the ball
    passed every 2 s (with flights in between), and OHV-style shots, passes and rebounds."""
    rng = np.random.default_rng(seed)
    p = make_perception(duration_s)
    times = np.array([t for _, t in analysed(p)])
    tids = [1, 2, 3, 4, 5, 11, 12, 13, 14, 15, 90, 91, 92]
    phase = rng.uniform(0, 2 * math.pi, (len(tids), 4))
    xs = 42 + 30 * np.sin(times[None, :] / 9 + phase[:, :1]) + 4 * np.sin(times[None, :] / 2 + phase[:, 1:2])
    ys = 25 + 18 * np.sin(times[None, :] / 7 + phase[:, 2:3]) + 3 * np.sin(times[None, :] / 3 + phase[:, 3:4])
    events: list[dict[str, Any]] = []
    holder_of = [tids[int(t // 2) % 5 + (5 if int(t // 20) % 2 else 0)] for t in times]
    for i, tid in enumerate(tids):
        team = None if tid >= 90 else (0 if tid < 10 else 1)
        obs = []
        for k, (x, y) in enumerate(zip(xs[i], ys[i], strict=True)):
            fx, fy = to_px(x, y)
            kps = [(fx, fy - 70, 0.8)] * 17 if k % 3 == 0 else None
            bbox = (fx - 20, fy - BOX_H, fx + 20, fy)
            obs.append(TrackObs(frame=k * STEP, bbox=bbox, conf=0.9, court_xy=(float(x), float(y)), keypoints=kps))
        p.tracks[tid] = TrackData(track_id=tid, obs=obs, team_id=team, role="referee" if tid >= 90 else "player")
    index = {tid: i for i, tid in enumerate(tids)}
    for k, t in enumerate(times):
        h = index[holder_of[k]]
        in_flight = (t % 2) > 1.6
        if in_flight:
            nxt = index[holder_of[min(k + 8, len(times) - 1)]]
            w = ((t % 2) - 1.6) / 0.4
            x, y, z = xs[h, k] + w * (xs[nxt, k] - xs[h, k]), ys[h, k] + w * (ys[nxt, k] - ys[h, k]), 6.0
        else:
            x, y, z = xs[h, k], ys[h, k], 3.5
        p.ball.append(BallObs(frame=k * STEP, xy=to_px(x, y, z), conf=0.8, court_xy=(float(x), float(y))))
        if abs(t % 2 - 1.6) < 1e-6:
            events.append(ev(f"p{k}", "pass", t, track=holder_of[k], to_track=holder_of[min(k + 8, len(times) - 1)]))
        if k % 300 == 150:
            events.append(ev(f"s{k}", "shot", t, track=holder_of[k], made=bool(k % 600 == 150)))
            events.append(ev(f"r{k}", "rebound", t + 1.0, track=holder_of[min(k + 15, len(times) - 1)]))
    return p, events


def test_ten_minute_game_runs_fast():
    p, events = synthetic_game(600.0)
    start = time.perf_counter()
    assign_ball_holders(p)
    enriched = enrich_events(p, events)
    extra = detect_events(p, existing_events=enriched)
    elapsed = time.perf_counter() - start
    assert elapsed < 5.0, f"took {elapsed:.1f} s"
    assert sum(b.holder_track_id is not None for b in p.ball) > 0.5 * len(p.ball)
    assert all(b.holder_track_id not in (90, 91, 92) for b in p.ball)
    assert len({e["event_id"] for e in enriched + extra}) == len(enriched) + len(extra)
