"""Raw events -> timeline rows, possessions and shot records."""

from __future__ import annotations

import time

import pytest

from scout.analysis.events import build_timeline, player_ref
from scout.analysis.geometry import CourtConfig
from scout.analysis.tracking_index import TrackingIndex
from scout.schemas import (
    EventType,
    PossessionOutcome,
    Roster,
    RosterPlayer,
    ShotZone,
    TeamSide,
    TrackAssignment,
)
from tests import helpers

S, O = TeamSide.SCOUTED, TeamSide.OTHER
CFG = CourtConfig()
TEAM_MAP = {0: S, 1: O}
# track id -> (team id, court position, jersey, roster player id)
PLAYERS = {
    1: (0, (25.5, 25.0), "23", "p23"),  # top of the key, beyond the arc (left basket)
    2: (0, (10.0, 25.0), "5", "p5"),  # in the paint
    3: (0, (20.0, 40.0), "14", None),  # unrostered jersey
    11: (1, (70.0, 25.0), "10", "p10"),
    12: (1, (60.0, 10.0), "3", None),
}
REFEREE = 99


def _rosters() -> dict[TeamSide, Roster]:
    return {
        S: Roster(
            game_id="g",
            side=S,
            team_name="Central",
            players=[
                RosterPlayer(id="p23", jersey="23", first_name="Sam", last_name="Smith"),
                RosterPlayer(id="p5", jersey="5", first_name="Jo", last_name="Jones"),
            ],
        ),
        O: Roster(
            game_id="g", side=O, team_name="North", players=[RosterPlayer(id="p10", jersey="10", last_name="Park")]
        ),
    }


def _assignments(**overrides: TrackAssignment) -> list[TrackAssignment]:
    out = []
    for tid, (team, _, jersey, pid) in PLAYERS.items():
        method = "exact" if pid else "unrostered"
        out.append(TrackAssignment(track_id=tid, team_id=team, side=TEAM_MAP[team], player_id=pid, jersey=jersey,
                                   best_read=jersey, match_score=0.9 if pid else 0.0, method=method, frames=100))
    out.append(TrackAssignment(track_id=REFEREE, role="referee"))
    replaced = {a.track_id: a for a in out}
    replaced.update({int(k[1:]): v for k, v in overrides.items()})
    return list(replaced.values())


def _tracks(duration_s: float, court: bool = True):
    frames = range(0, int(duration_s * 30), 3)
    tracks = [helpers.track(tid, team, [(f, x, y) for f in frames], jersey=j, court=court)
              for tid, (team, (x, y), j, _) in PLAYERS.items()]
    tracks.append(helpers.track(REFEREE, None, [(f, 42.0, 1.0) for f in frames], role="referee", court=court))
    return tracks


def _build(events, *, balls=None, homography=True, court=True, assignments=None, duration_s=120.0):
    tracking = helpers.tracking(_tracks(duration_s, court), balls=balls, events=events, duration_s=duration_s,
                                homography=homography)
    index = TrackingIndex(tracking, CFG)
    return build_timeline(tracking, index, TEAM_MAP, assignments or _assignments(), _rosters(), CFG)


def ev(event_id, type_, second, track_id=None, **attrs):
    team = PLAYERS[track_id][0] if track_id in PLAYERS else attrs.pop("team_id", None)
    return helpers.event(event_id, type_, int(round(second * 30)), track_id=track_id, team_id=team, **attrs)


def rows_of(build, type_):
    return [r for r in build.timeline if r.type == type_]


def by_id(build):
    return {r.id: r for r in build.timeline}


# ---------------------------------------------------------------------------
# player_ref
# ---------------------------------------------------------------------------


def test_player_ref_variants():
    assignments = {a.track_id: a for a in _assignments()}
    rosters = _rosters()
    ref = player_ref(1, assignments, rosters)
    assert (ref.player_id, ref.jersey, ref.name, ref.side, ref.label) == ("p23", "23", "Sam Smith", S, "#23 Sam Smith")
    unrostered = player_ref(3, assignments, rosters)
    assert unrostered.player_id is None and unrostered.jersey == "14" and unrostered.label == "#14"
    assert player_ref(REFEREE, assignments, rosters) is None
    assert player_ref(None, assignments, rosters) is None
    assert player_ref(555, assignments, rosters) is None
    assignments[2] = assignments[2].model_copy(update={"ignored": True})
    assert player_ref(2, assignments, rosters) is None
    assignments[12] = assignments[12].model_copy(update={"jersey": None, "best_read": None})
    assert player_ref(12, assignments, rosters) is None


# ---------------------------------------------------------------------------
# Shots
# ---------------------------------------------------------------------------


def test_shot_zones_points_and_location_priority():
    events = [
        ev("s1", "shot", 1, track_id=1, made=True, shot_court_xy=[25.5, 25.0]),  # top 3
        ev("s2", "shot", 30, track_id=11, made=True, shot_court_xy=[78.0, 25.0]),  # right basket, rim
        ev("s3", "shot", 60, track_id=1, made=True, shot_xy_px=[6.0, 25.0]),  # projected (identity H)
        ev("s4", "shot", 90, track_id=11, made=False, is_three=True, shot_court_xy=[64.0, 25.0]),  # geometry wins
        ev("s5", "shot", 95, track_id=2, made=True, shot_court_xy=[900.0, 900.0]),  # off court -> shooter pos
    ]
    build = _build(events)
    rows = by_id(build)
    s1 = rows["s1"]
    assert (s1.label, s1.points, s1.zone, s1.subzone) == ("3PT Make", 3, ShotZone.THREE, "top_3")
    assert rows["s1"].description == "#23 Sam Smith 3PT make (top 3)"
    assert (rows["s2"].label, rows["s2"].points, rows["s2"].subzone) == ("2PT Make", 2, "restricted_area")
    assert rows["s3"].court_xy == pytest.approx((6.0, 25.0)) and rows["s3"].zone == ShotZone.PAINT
    assert rows["s4"].is_three is False and rows["s4"].label == "2PT Miss" and rows["s4"].zone == ShotZone.MID
    assert rows["s5"].court_xy == pytest.approx((10.0, 25.0)) and rows["s5"].zone == ShotZone.PAINT
    shots = {s.event_id: s for s in build.shots}
    assert shots["s2"].half_court_xy == pytest.approx((6.0, 25.0))  # mirrored for the right basket
    assert shots["s1"].half_court_xy == pytest.approx((25.5, 25.0))
    assert build.score == {S: 7, O: 2}


def test_shot_without_court_mapping_uses_pipeline_three():
    events = [
        ev("a", "shot", 1, track_id=1, made=True, is_three=True, shot_xy_px=[900.0, 500.0]),
        ev("b", "shot", 30, track_id=11, made=True),
        ev("c", "shot", 60, track_id=1, made=None),
    ]
    build = _build(events, homography=False, court=False)
    rows = by_id(build)
    assert rows["a"].zone == ShotZone.UNKNOWN and rows["a"].is_three and rows["a"].points == 3
    assert rows["b"].is_three is False and rows["b"].points == 2 and rows["b"].court_xy is None
    # Unknown result: counted as a miss with halved confidence.
    assert rows["c"].type == EventType.SHOT_MISSED and rows["c"].confidence == pytest.approx(0.45)
    assert build.score == {S: 3, O: 2}


def test_assist_block_and_steal_rows():
    events = [
        ev("s1", "shot", 1, track_id=1, made=True, shot_court_xy=[25.5, 25.0], assisted_by_track=2),
        ev("s2", "shot", 10, track_id=11, made=True, shot_court_xy=[78.0, 25.0], blocked_by_track=2),
        ev("t1", "turnover", 20, track_id=1, kind="bad_pass", stolen_by_track=12),
        ev("s3", "shot", 30, track_id=12, made=True, shot_court_xy=[78.0, 25.0], assisted_by_track=REFEREE),
    ]
    build = _build(events)
    rows = by_id(build)
    ast = rows["s1:ast"]
    assert (ast.type, ast.label, ast.side, ast.player.player_id, ast.secondary_player.player_id) == (
        EventType.ASSIST, "Assist", S, "p5", "p23")
    assert rows["s1"].description == "#23 Sam Smith 3PT make (top 3), assist #5 Jo Jones"
    assert rows["s2"].type == EventType.SHOT_MISSED and rows["s2"].points == 0  # blocked shot is a miss
    blk = rows["s2:blk"]
    assert (blk.type, blk.side, blk.player.jersey, blk.secondary_player.jersey) == (EventType.BLOCK, S, "5", "10")
    stl = rows["t1:stl"]
    assert (stl.type, stl.side, stl.player.jersey, stl.secondary_player.jersey) == (EventType.STEAL, O, "3", "23")
    assert rows["t1"].description == "#23 Sam Smith turnover (bad pass), stolen by #3"
    assert "s3:ast" not in rows  # referees never get credit
    assert [r.id for r in build.timeline if r.source_event_id == "s1"] == ["s1", "s1:ast"]
    assert next(s for s in build.shots if s.event_id == "s2").blocked


# ---------------------------------------------------------------------------
# Rebounds and possessions
# ---------------------------------------------------------------------------


def test_rebound_inference_and_possession_flips():
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("m1", "shot", 5, track_id=1, made=False, shot_court_xy=[25.5, 25.0]),
        ev("r1", "rebound", 6, track_id=2),  # same team as the miss -> offensive
        ev("m2", "shot", 8, track_id=2, made=False, shot_court_xy=[6.0, 25.0]),
        ev("r2", "rebound", 9, track_id=11),  # other team -> defensive, ball changes hands
        ev("m3", "shot", 20, track_id=11, made=False, shot_court_xy=[78.0, 25.0]),
        ev("r3", "rebound", 21, track_id=12, offensive=False),  # explicit flag wins over inference
    ]
    build = _build(events)
    rows = by_id(build)
    assert rows["r1"].type == EventType.OREB and rows["r1"].label == "Off. Rebound"
    assert rows["r2"].type == EventType.DREB and rows["r2"].label == "Def. Rebound"
    assert rows["r3"].type == EventType.DREB
    poss = build.possessions
    assert [(p.side, p.start_reason, p.outcome) for p in poss] == [
        (S, "jump_ball", PossessionOutcome.MISSED_FG),
        (O, "def_rebound", PossessionOutcome.MISSED_FG),  # r3 is Other's own rebound: no flip
    ]
    # The OREB continued possession 1; the DREB row ends it and the change row follows.
    assert rows["r1"].possession_id == 1 and rows["r2"].possession_id == 1
    assert [r.id for r in build.timeline][-4:] == ["r2", "poss2", "m3", "r3"]
    assert rows["poss2"].type == EventType.POSSESSION_CHANGE and rows["poss2"].label == "Possession: North"
    assert rows["m3"].possession_side == O and rows["m3"].possession_id == 2


def test_made_basket_and_one_and_free_throw_trips():
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("a1", "shot", 5, track_id=1, made=True, shot_court_xy=[10.0, 25.0]),  # and-one, FT 30 s later
        ev("f0", "foul", 5.2, track_id=11, kind="shooting", fouled_track=1),
        ev("a1ft", "free_throw", 35, track_id=1, made=True),
        ev("b1", "shot", 50, track_id=11, made=True, shot_court_xy=[78.0, 25.0]),  # and-one within 3 s
        ev("b1ft", "free_throw", 52, track_id=11, made=False),
        ev("r", "rebound", 53, track_id=2),
        ev("ft1", "free_throw", 70, track_id=1, made=True),  # 2-shot trip (inferred possession: no shot)
        ev("ft2", "free_throw", 80, track_id=1, made=False),
        ev("r2", "rebound", 81, track_id=2),  # offensive rebound after a missed last FT
        ev("a2", "shot", 85, track_id=2, made=True, shot_court_xy=[6.0, 25.0]),
    ]
    build = _build(events)
    sides = [(p.side, p.start_reason, p.outcome, p.points) for p in build.possessions]
    assert sides == [
        (S, "jump_ball", PossessionOutcome.MADE_FG, 3),  # basket + and-one FT in ONE possession
        (O, "made_basket", PossessionOutcome.MADE_FG, 2),  # missed and-one FT, then DREB
        (S, "def_rebound", PossessionOutcome.MADE_FG, 3),  # FT trip, OREB, putback
        (O, "made_basket", PossessionOutcome.UNKNOWN, 0),
    ]
    rows = by_id(build)
    assert rows["a1ft"].possession_id == 1 and rows["ft2"].possession_id == 3
    changes = [r.id for r in build.timeline if r.type == EventType.POSSESSION_CHANGE]
    assert changes == ["poss1", "poss2", "poss3", "poss4"]
    assert build.score == {S: 6, O: 2}


def test_last_free_throw_made_flips_possession():
    events = [
        ev("j", "jump_ball", 0, won_by_team=1),
        ev("f", "foul", 4, track_id=1, kind="personal", fouled_track=11),
        ev("ft1", "free_throw", 10, track_id=11, made=True),
        ev("to", "timeout", 12, team_id=0),
        ev("ft2", "free_throw", 70, track_id=11, made=True),
    ]
    build = _build(events)
    assert [(p.side, p.outcome, p.points) for p in build.possessions] == [
        (O, PossessionOutcome.FREE_THROWS, 2),
        (S, PossessionOutcome.UNKNOWN, 0),
    ]
    assert by_id(build)["to"].label == "Timeout" and by_id(build)["to"].side == S


def test_turnovers_and_transition_flag():
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("t1", "turnover", 5, track_id=1, kind="steal", stolen_by_track=11),  # live: transition chance
        ev("b1", "shot", 9, track_id=11, made=True, shot_court_xy=[78.0, 25.0]),  # 4 s later -> transition
        ev("t2", "turnover", 30, track_id=2, kind="travel"),  # dead ball: never transition
        ev("b2", "shot", 33, track_id=12, made=False, shot_court_xy=[78.0, 25.0]),
        ev("r", "rebound", 34, track_id=1),  # defensive rebound
        ev("a1", "shot", 60, track_id=1, made=False, shot_court_xy=[25.5, 25.0]),  # 26 s later: half court
    ]
    build = _build(events)
    got = [(p.side, p.start_reason, p.outcome, p.transition) for p in build.possessions]
    assert got == [
        (S, "jump_ball", PossessionOutcome.TURNOVER, False),
        (O, "steal", PossessionOutcome.MADE_FG, True),
        (S, "made_basket", PossessionOutcome.TURNOVER, False),
        (O, "turnover", PossessionOutcome.MISSED_FG, False),
        (S, "def_rebound", PossessionOutcome.MISSED_FG, False),
    ]
    assert rows_of(build, EventType.STEAL)[0].id == "t1:stl"


def test_inferred_possession_from_holder_segments():
    # Scouted misses, nobody detected the rebound, Other holds the ball for 3 s.
    balls = helpers.ball([(f, 70.0, 25.0, 11) for f in range(450, 541, 3)])
    # A 1-second touch by Scouted later is too short to count.
    balls += helpers.ball([(f, 25.0, 25.0, 1) for f in range(900, 931, 3)])
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("m1", "shot", 5, track_id=1, made=False, shot_court_xy=[25.5, 25.0]),
        ev("p", "pass", 40, track_id=11, to_track=12),
    ]
    build = _build(events, balls=balls)
    assert [(p.side, p.start_reason) for p in build.possessions] == [(S, "jump_ball"), (O, "inferred")]
    change = by_id(build)["poss2"]
    assert change.frame == 450 and change.confidence == pytest.approx(0.4)
    assert by_id(build)["p"].possession_side == O
    assert build.possessions[0].outcome == PossessionOutcome.MISSED_FG


def test_shot_by_team_without_ball_starts_inferred_possession():
    events = [ev("a", "shot", 3, track_id=11, made=False), ev("b", "shot", 10, track_id=1, made=True)]
    build = _build(events)
    got = [(p.side, p.start_reason) for p in build.possessions]
    assert got == [(O, "inferred"), (S, "inferred"), (O, "made_basket")]


def test_periods_and_breaks():
    balls = helpers.ball([(f, 25.0, 25.0, 1) for f in range(1890, 2010, 3)])  # warm-up dribbling in the break
    events = [
        ev("ps1", "period_start", 0, period=1),
        ev("j", "jump_ball", 1, won_by_team=1),
        ev("pe1", "period_end", 60, period=1),
        ev("ps2", "period_start", 70, period=2, team_id=0),
        ev("a", "shot", 75, track_id=1, made=True, shot_court_xy=[6.0, 25.0]),
        ev("pe2", "period_end", 100, period=2),
    ]
    build = _build(events, balls=balls)
    rows = by_id(build)
    assert rows["ps1"].label == "Start of Period 1" and rows["pe2"].label == "End of Period 2"
    assert rows["ps1"].possession_id is None and rows["ps2"].possession_id is None
    assert [(p.side, p.start_reason, p.outcome) for p in build.possessions] == [
        (O, "jump_ball", PossessionOutcome.END_OF_PERIOD),
        (S, "period_start", PossessionOutcome.MADE_FG),
        (O, "made_basket", PossessionOutcome.END_OF_PERIOD),
    ]


def test_ignored_and_referee_events_are_dropped_and_overrides_win():
    manual = TrackAssignment(track_id=3, team_id=0, side=O, jersey="14", method="manual", frames=100)
    ignored = TrackAssignment(track_id=12, team_id=1, side=O, ignored=True, method="manual", frames=100)
    events = [
        ev("x", "shot", 1, track_id=REFEREE, made=True, team_id=None),
        ev("y", "shot", 2, track_id=12, made=True, shot_court_xy=[78.0, 25.0]),
        ev("z", "shot", 3, track_id=3, made=True, shot_court_xy=[78.0, 25.0]),  # coach moved #14 to Other
    ]
    build = _build(events, assignments=_assignments(t3=manual, t12=ignored))
    rows = by_id(build)
    assert "x" not in rows and "y" not in rows
    assert rows["z"].side == O and rows["z"].player.jersey == "14"
    assert build.score == {S: 0, O: 2}


def test_running_score_possession_indicator_and_order():
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("a", "shot", 5, track_id=1, made=True, shot_court_xy=[25.5, 25.0]),
        ev("b", "shot", 20, track_id=11, made=True, shot_court_xy=[78.0, 25.0]),
        ev("s", "screen", 30, track_id=2, ball_handler_track=1, on_ball=True),
        ev("c", "shot", 32, track_id=1, made=True, shot_court_xy=[10.0, 25.0], assisted_by_track=2),
    ]
    build = _build(events)
    assert [r.frame for r in build.timeline] == sorted(r.frame for r in build.timeline)
    scores = [(r.id, r.score_scouted, r.score_other) for r in build.timeline if r.points]
    assert scores == [("a", 3, 0), ("b", 3, 2), ("c", 5, 2)]
    assert build.timeline[0].id == "j" and build.timeline[0].possession_side is None  # nobody had it before the tip
    assert all(r.possession_side is not None for r in build.timeline[1:])
    last = build.timeline[-1]
    assert (last.score_scouted, last.score_other) == (5, 2)
    assert by_id(build)["s"].description == "#5 Jo Jones on-ball screen for #23 Sam Smith"
    for poss in build.possessions:
        assert poss.event_ids == [r.id for r in build.timeline if r.possession_id == poss.id]


def test_long_game_is_fast():
    events, balls = [], []
    for i in range(3000):  # ~ a 60-minute film's worth of events
        tid = 1 if i % 2 == 0 else 11
        events.append(ev(f"e{i}", "shot", 1 + i * 1.1, track_id=tid, made=i % 3 == 0,
                         shot_court_xy=[25.5, 25.0] if tid == 1 else [78.0, 25.0]))
    balls = helpers.ball([(f, 40.0, 25.0, 1 if (f // 300) % 2 == 0 else 11) for f in range(0, 108000, 3)])
    tracking = helpers.tracking(_tracks(60.0), balls=balls, events=events, duration_s=3600.0)
    index = TrackingIndex(tracking, CFG)
    start = time.perf_counter()
    build = build_timeline(tracking, index, TEAM_MAP, _assignments(), _rosters(), CFG)
    assert time.perf_counter() - start < 3.0
    assert len(build.shots) == 3000
