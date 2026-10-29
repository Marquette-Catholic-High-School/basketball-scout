"""Regression tests from the review of the server-side transform (teams, events,
possessions, box score, geometry, tracking index, pipeline)."""

from __future__ import annotations

import pytest

from scout.analysis import geometry, pipeline
from scout.analysis.boxscore import build_box_scores
from scout.analysis.events import build_timeline
from scout.analysis.geometry import CourtConfig
from scout.analysis.plays import PlayRules
from scout.analysis.tracking_index import TrackingIndex
from scout.errors import ErrorCode, ScoutError
from scout.schemas import (
    BallSample,
    CourtCalibration,
    CourtInfo,
    EventType,
    Game,
    Homography,
    PipelineWarning,
    PlayerRef,
    PossessionOutcome,
    Roster,
    RosterPlayer,
    ShotZone,
    TeamSide,
    TimelineEvent,
    TrackAssignment,
    TrackingResult,
    TrackSample,
)
from tests import helpers

S, O = TeamSide.SCOUTED, TeamSide.OTHER
CFG = CourtConfig()
TEAM_MAP = {0: S, 1: O}
FPS = 30
NAMES = {S: "Central", O: "North"}
# track id -> (team id, court position, jersey)
PLAYERS = {1: (0, (25.5, 25.0), "23"), 2: (0, (10.0, 25.0), "5"), 11: (1, (70.0, 25.0), "10"), 12: (1, (60.0, 10.0), "3")}


def _rosters() -> dict[TeamSide, Roster]:
    return {
        S: Roster(game_id="g", side=S, team_name="Central",
                  players=[RosterPlayer(id="p23", jersey="23", last_name="Smith")]),
        O: Roster(game_id="g", side=O, team_name="North"),
    }


def _assignments() -> list[TrackAssignment]:
    return [
        TrackAssignment(track_id=tid, team_id=team, side=TEAM_MAP[team], jersey=j, best_read=j,
                        player_id="p23" if j == "23" else None, method="exact" if j == "23" else "unrostered",
                        frames=100)
        for tid, (team, _, j) in PLAYERS.items()
    ]


def _build(events, *, balls=None, duration_s=120.0):
    frames = range(0, int(duration_s * FPS), 3)
    tracks = [helpers.track(tid, team, [(f, x, y) for f in frames], jersey=j)
              for tid, (team, (x, y), j) in PLAYERS.items()]
    tracking = helpers.tracking(tracks, balls=balls, events=events, duration_s=duration_s)
    index = TrackingIndex(tracking, CFG)
    return build_timeline(tracking, index, TEAM_MAP, _assignments(), _rosters(), CFG)


def ev(event_id, type_, second, track_id=None, **attrs):
    team = PLAYERS[track_id][0] if track_id in PLAYERS else attrs.pop("team_id", None)
    return helpers.event(event_id, type_, int(round(second * FPS)), track_id=track_id, team_id=team, **attrs)


def hold(track_id, start_s, end_s, xy=(19.0, 25.0)):
    """Ball samples: ``track_id`` holds the ball from ``start_s`` to ``end_s``."""
    return helpers.ball([(f, xy[0], xy[1], track_id) for f in range(int(start_s * FPS), int(end_s * FPS) + 1, 3)])


def _possessions(build):
    return [(p.side, p.start_reason, p.outcome, p.points) for p in build.possessions]


def _rebound_ids(build):
    return [r.id for r in build.timeline if r.type in (EventType.OREB, EventType.DREB)]


# ---------------------------------------------------------------------------
# Possessions: and-ones and dead balls
# ---------------------------------------------------------------------------


def test_and_one_free_throw_shooter_holding_the_ball_keeps_one_possession():
    # Real film: the official hands the shooter the ball and he holds it for several seconds
    # at the line before the and-one free throw. That hold is not a change of possession.
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("a1", "shot", 5, track_id=1, made=True, shot_court_xy=[10.0, 25.0]),
        ev("f", "foul", 5, track_id=11, kind="shooting", fouled_track=1),
        ev("a1ft", "free_throw", 35, track_id=1, made=True),
        ev("b1", "shot", 50, track_id=11, made=True, shot_court_xy=[78.0, 25.0]),
    ]
    build = _build(events, balls=hold(1, 28, 34.5))
    assert _possessions(build) == [
        (S, "jump_ball", PossessionOutcome.MADE_FG, 3),
        (O, "made_basket", PossessionOutcome.MADE_FG, 2),
        (S, "made_basket", PossessionOutcome.UNKNOWN, 0),
    ]
    rows = {r.id: r for r in build.timeline}
    assert rows["a1ft"].possession_id == 1 and rows["a1ft"].possession_side == S


def test_scoring_team_holding_the_ball_after_its_basket_is_not_a_possession():
    # After a made basket a scorer may hold the ball before handing it to the official.
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("a1", "shot", 5, track_id=1, made=True, shot_court_xy=[10.0, 25.0]),
        ev("b1", "shot", 25, track_id=11, made=False, shot_court_xy=[78.0, 25.0]),
    ]
    build = _build(events, balls=hold(2, 6, 9, xy=(3.0, 25.0)))
    assert [(p.side, p.start_reason) for p in build.possessions] == [(S, "jump_ball"), (O, "made_basket")]


def test_ball_picked_up_after_a_shooting_foul_is_not_a_rebound():
    # Fouled on a missed shot: the whistle has gone, a defender picks the ball up, holds it
    # and hands it to the official; the shooter then takes his two free throws.
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("m", "shot", 5, track_id=1, made=False, shot_court_xy=[10.0, 25.0]),
        ev("f", "foul", 5, track_id=11, kind="shooting", fouled_track=1),
        ev("r", "rebound", 6, track_id=12),
        ev("ft1", "free_throw", 30, track_id=1, made=True),
        ev("ft2", "free_throw", 33, track_id=1, made=True),
        ev("b", "shot", 50, track_id=11, made=False, shot_court_xy=[78.0, 25.0]),
        ev("r2", "rebound", 51, track_id=2),  # a live rebound again
    ]
    build = _build(events, balls=hold(12, 6, 10, xy=(8.0, 20.0)))
    assert _possessions(build) == [
        (S, "jump_ball", PossessionOutcome.FREE_THROWS, 2),
        (O, "made_basket", PossessionOutcome.MISSED_FG, 0),
        (S, "def_rebound", PossessionOutcome.UNKNOWN, 0),
    ]
    assert _rebound_ids(build) == ["r2"]


def test_free_throw_trip_after_a_shooting_foul_still_counts_a_later_rebound_of_the_last_miss():
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("m", "shot", 5, track_id=1, made=False, shot_court_xy=[10.0, 25.0]),
        ev("f", "foul", 5, track_id=11, kind="shooting", fouled_track=1),
        ev("ft1", "free_throw", 30, track_id=1, made=True),
        ev("ft2", "free_throw", 33, track_id=1, made=False),
        ev("r", "rebound", 34, track_id=12),
    ]
    build = _build(events)
    assert [r.id for r in build.timeline if r.type == EventType.DREB] == ["r"]
    assert [(p.side, p.start_reason) for p in build.possessions] == [(S, "jump_ball"), (O, "def_rebound")]


def test_ball_caught_after_a_missed_first_free_throw_is_not_a_rebound():
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("f", "foul", 5, track_id=11, kind="personal", fouled_track=1),  # in the bonus
        ev("ft1", "free_throw", 30, track_id=1, made=False),
        ev("r", "rebound", 31, track_id=12),  # a defender catches the dead ball for the official
        ev("ft2", "free_throw", 35, track_id=1, made=True),
        ev("b", "shot", 50, track_id=11, made=False, shot_court_xy=[78.0, 25.0]),
        ev("r2", "rebound", 51, track_id=2),
    ]
    build = _build(events)
    assert _possessions(build) == [
        (S, "jump_ball", PossessionOutcome.FREE_THROWS, 1),
        (O, "made_basket", PossessionOutcome.MISSED_FG, 0),
        (S, "def_rebound", PossessionOutcome.UNKNOWN, 0),
    ]
    assert _rebound_ids(build) == ["r2"]


def test_offensive_rebound_of_a_missed_last_free_throw_then_a_new_trip_still_counts():
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("ft1", "free_throw", 30, track_id=1, made=False),
        ev("r", "rebound", 31, track_id=2),  # live: the last free throw was missed
        ev("f", "foul", 32, track_id=11, kind="personal", fouled_track=2),
        ev("ft2", "free_throw", 60, track_id=2, made=True),
    ]
    build = _build(events)
    assert [r.id for r in build.timeline if r.type == EventType.OREB] == ["r"]


def test_technical_foul_free_throws_do_not_give_the_ball_away():
    # NFHS: after technical-foul free throws the shooting team inbounds at the division line.
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("t", "foul", 10, track_id=11, kind="technical"),
        ev("ft1", "free_throw", 20, track_id=1, made=True),
        ev("ft2", "free_throw", 25, track_id=1, made=True),
        ev("a", "shot", 40, track_id=2, made=True, shot_court_xy=[10.0, 25.0]),
    ]
    build = _build(events)
    assert _possessions(build) == [
        (S, "jump_ball", PossessionOutcome.MADE_FG, 4),
        (O, "made_basket", PossessionOutcome.UNKNOWN, 0),
    ]
    assert build.score == {S: 4, O: 0}


# ---------------------------------------------------------------------------
# Possessions: transition (ends within 10 s, no stoppage)
# ---------------------------------------------------------------------------


def _after_def_rebound(*events):
    """Scouted misses, Other rebounds at 6 s (a live start), then ``events``."""
    return [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("m", "shot", 5, track_id=1, made=False, shot_court_xy=[25.5, 25.0]),
        ev("r", "rebound", 6, track_id=11),
        *events,
    ]


def _transition_of_rebound_possession(events) -> bool:
    poss = _build(events).possessions[1]
    assert (poss.side, poss.start_reason) == (O, "def_rebound")
    return poss.transition


def test_transition_needs_no_stoppage_before_the_end():
    quick_shot = ev("b", "shot", 12, track_id=11, made=True, shot_court_xy=[78.0, 25.0])  # 6 s after the rebound
    assert _transition_of_rebound_possession(_after_def_rebound(quick_shot))
    timeout = ev("to", "timeout", 8, team_id=1)
    assert not _transition_of_rebound_possession(_after_def_rebound(timeout, quick_shot))
    common_foul = ev("f", "foul", 9, track_id=2, kind="personal", fouled_track=11)  # side-out, then the shot
    assert not _transition_of_rebound_possession(_after_def_rebound(common_foul, quick_shot))


def test_transition_possession_must_end_within_ten_seconds():
    # A quick miss, offensive rebound, then a half-court reset: the possession ends at 30 s.
    reset = _after_def_rebound(
        ev("b1", "shot", 9, track_id=11, made=False, shot_court_xy=[78.0, 25.0]),
        ev("r2", "rebound", 10, track_id=12),
        ev("b2", "shot", 30, track_id=12, made=True, shot_court_xy=[78.0, 25.0]),
    )
    assert not _transition_of_rebound_possession(reset)
    # Miss, offensive rebound and putback all inside 10 s: still transition.
    putback = _after_def_rebound(
        ev("b1", "shot", 9, track_id=11, made=False, shot_court_xy=[78.0, 25.0]),
        ev("r2", "rebound", 10, track_id=12),
        ev("b2", "shot", 11, track_id=12, made=True, shot_court_xy=[78.0, 25.0]),
    )
    assert _transition_of_rebound_possession(putback)


def test_fouled_drive_ends_a_transition_possession():
    # Fouled on the break 3 s after the rebound; the free throws come much later.
    events = _after_def_rebound(
        ev("f", "foul", 9, track_id=2, kind="shooting", fouled_track=11),
        ev("ft1", "free_throw", 40, track_id=11, made=True),
        ev("ft2", "free_throw", 43, track_id=11, made=True),
    )
    assert _transition_of_rebound_possession(events)
    # Free throws with no foul seen are judged from the first free throw: not transition.
    no_foul = _after_def_rebound(ev("ft1", "free_throw", 40, track_id=11, made=True))
    assert not _transition_of_rebound_possession(no_foul)


# ---------------------------------------------------------------------------
# Event side and credits
# ---------------------------------------------------------------------------


def test_event_side_follows_the_actors_track_not_a_one_frame_team_label():
    # Similar jerseys: the pipeline labelled Other's #10 as team 0 for the frame of his shot,
    # while his track (hundreds of frames) and his roster match say Other.
    flicker = helpers.event("b1", "shot", 300, track_id=11, team_id=0, made=True, shot_court_xy=[78.0, 25.0])
    build = _build([ev("j", "jump_ball", 0, won_by_team=0), flicker])
    row = next(r for r in build.timeline if r.id == "b1")
    assert row.side == O and row.player.side == O
    assert build.score == {S: 0, O: 2}
    boxes = build_box_scores(build.timeline, build.possessions, _assignments(), _rosters(), NAMES)
    scouted = next(b for b in boxes if b.side == S)
    assert [line.player.jersey for line in scouted.players if line.pts] == [] and scouted.totals.pts == 0
    # A team event (no actor) still uses the event's team id.
    timeout = _build([ev("to", "timeout", 3, team_id=1)])
    assert timeout.timeline[0].side == O


def test_assist_by_an_opponent_is_not_credited():
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("a1", "shot", 5, track_id=1, made=True, shot_court_xy=[10.0, 25.0], assisted_by_track=11),
        ev("a2", "shot", 30, track_id=1, made=True, shot_court_xy=[10.0, 25.0], assisted_by_track=2),
    ]
    build = _build(events)
    assists = [r for r in build.timeline if r.type == EventType.ASSIST]
    assert [(r.id, r.side, r.player.jersey) for r in assists] == [("a2:ast", S, "5")]
    assert not next(s for s in build.shots if s.event_id == "a1").assisted


# ---------------------------------------------------------------------------
# Box score: minutes and plus-minus are on-floor presence
# ---------------------------------------------------------------------------


def test_minutes_and_plus_minus_exclude_time_tracked_on_the_bench():
    on_floor = [(f, 30.0, 20.0) for f in range(0, 1800, 3)]  # first minute on the court
    bench = [(f, 40.0, -12.0) for f in range(1800, 3600, 3)]  # second minute: sitting 12 ft off the sideline
    tracking = helpers.tracking([helpers.track(1, 0, on_floor + bench, jersey="23")], duration_s=120.0)
    index = TrackingIndex(tracking, CFG)
    assignment = TrackAssignment(track_id=1, team_id=0, side=S, player_id="p23", jersey="23", method="exact")
    basket = TimelineEvent(id="b", t=90.0, frame=2700, type=EventType.SHOT_MADE, label="2PT Make", side=O,
                           player=PlayerRef(jersey="10", side=O), points=2, is_three=False)
    boxes = build_box_scores([basket], [], [assignment], _rosters(), NAMES, index=index)
    smith = next(b for b in boxes if b.side == S).players[0]
    assert smith.minutes_est == pytest.approx(1.0) and smith.plus_minus == 0


# ---------------------------------------------------------------------------
# Geometry and court config
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("xy", [(-0.8, 24.0), (-3.0, 25.0), (85.0, 26.0)])
def test_shot_projected_just_behind_the_baseline_under_the_basket_is_a_paint_two(xy):
    zone, subzone = geometry.classify_shot(CFG, xy)
    assert (zone, subzone) == (ShotZone.PAINT, "paint") and not geometry.is_three(CFG, xy)


def test_shot_zone_regions_follow_nfhs_lines():
    cases = {
        (5.25 + 19.6, 25.0): (ShotZone.MID, "top_mid"),  # just inside the 19'9" arc
        (5.25 + 19.9, 25.0): (ShotZone.THREE, "top_3"),
        (2.0, 25.0 - 19.6): (ShotZone.MID, "left_baseline_mid"),  # straight corner segment
        (2.0, 25.0 - 19.9): (ShotZone.THREE, "left_corner_3"),
        (18.9, 30.9): (ShotZone.PAINT, "paint"),  # 12 ft lane up to the free-throw line
        (19.1, 25.0): (ShotZone.MID, "top_mid"),
        (84.0 - 5.25, 25.0): (ShotZone.PAINT, "restricted_area"),
        (84.0 - 2.0, 25.0 + 19.9): (ShotZone.THREE, "left_corner_3"),  # offense's left at the right basket
    }
    for xy, expected in cases.items():
        assert geometry.classify_shot(CFG, xy) == expected, xy
        assert geometry.is_three(CFG, xy) == (expected[0] == ShotZone.THREE), xy


@pytest.mark.parametrize(
    ("text", "needle"),
    [
        ("length_ft: eighty-four\n", "length_ft"),
        ("width_ft: -50\n", "width_ft"),
        ("length_ft: [84\n", "court.yaml"),  # YAML syntax error
        ("- 84\n- 50\n", "court.yaml"),  # not a mapping
    ],
)
def test_bad_court_yaml_is_a_config_error_naming_the_setting(tmp_path, text, needle):
    path = tmp_path / "court.yaml"
    path.write_text(text)
    with pytest.raises(ScoutError) as exc:
        geometry.load_court_config(path)
    assert exc.value.code == ErrorCode.CONFIG_INVALID and needle in exc.value.message
    assert not exc.value.retryable


def test_court_yaml_numbers_load(tmp_path):
    path = tmp_path / "court.yaml"
    path.write_text("length_ft: 74\nwidth_ft: '42'\nunknown_key: 3\nrim_height_ft:\n")
    cfg = geometry.load_court_config(path)
    assert (cfg.length_ft, cfg.width_ft, cfg.rim_height_ft) == (74.0, 42.0, 10.0)


# ---------------------------------------------------------------------------
# Tracking index: court or pixel coordinates
# ---------------------------------------------------------------------------


def _partly_mapped_tracking(mapped_from: int, mapped_to: int, n: int = 600) -> TrackingResult:
    """Two whole-game tracks whose samples mapped_from..mapped_to carry court positions."""
    tracks = []
    for tid, x in ((1, 30.0), (11, 60.0)):
        samples = [
            TrackSample(f=i * 3, bbox=(500.0, 400.0, 540.0, 520.0),
                        court_xy=(x, 25.0) if mapped_from <= i < mapped_to else None)
            for i in range(n)
        ]
        tracks.append(helpers.track(tid, 0 if tid == 1 else 1, []).model_copy(update={"samples": samples}))
    return helpers.tracking(tracks, homography=False, duration_s=60.0)


def test_coord_mode_uses_the_whole_film_not_the_first_seconds_of_each_track():
    # The court lines were found from 6 s on (the camera was still settling before the tip).
    index = TrackingIndex(_partly_mapped_tracking(60, 600), CFG)
    assert index.coord_mode == "court"
    assert index.position(1, 900) == pytest.approx((30.0, 25.0))


def test_coord_mode_stays_pixel_when_only_a_few_seconds_were_mapped():
    # Court positions for the first 3 s only: feet for 5% of the film would leave the
    # tracks almost empty, so pixels are used (as the GPU pipeline does below 50%).
    index = TrackingIndex(_partly_mapped_tracking(0, 30), CFG)
    assert index.coord_mode == "pixel"
    assert index.position(1, 900) is not None


# ---------------------------------------------------------------------------
# analyze_game: court mapping, the coach's calibration and data-quality notes
# ---------------------------------------------------------------------------

PX_PER_FT = 20.0
CALIBRATION = [[1 / PX_PER_FT, 0.0, 0.0], [0.0, 1 / PX_PER_FT, 0.0], [0.0, 0.0, 1.0]]  # 20 px = 1 ft
OLD_CALIBRATION = [[0.1, 0.0, 0.0], [0.0, 0.1, 0.0], [0.0, 0.0, 1.0]]  # an earlier calibration: 10 px = 1 ft


def _analyze(tracking, game):
    return pipeline.analyze_game(tracking, game, {}, rules=PlayRules())


def _calibrated(matrix) -> Game:
    return Game(scouted_team="Central", other_team="North",
                calibration=CourtCalibration(points=[], matrix=matrix, reprojection_error_ft=0.3))


def _unmapped_film() -> TrackingResult:
    """GPU result for film whose court lines were not found: pixels only, plus the warning."""
    frames = range(0, 1800, 3)
    tracks = [
        helpers.track(1, 0, [(f, 10.0 * PX_PER_FT, 25.0 * PX_PER_FT) for f in frames], jersey="23", court=False),
        helpers.track(11, 1, [(f, 70.0 * PX_PER_FT, 25.0 * PX_PER_FT) for f in frames], jersey="10", court=False),
    ]
    events = [
        helpers.event("j", "jump_ball", 0, won_by_team=0),
        helpers.event("s1", "shot", 150, track_id=1, team_id=0, made=True, shot_xy_px=[6.0 * PX_PER_FT, 500.0]),
    ]
    warning = PipelineWarning(code="NO_COURT_HOMOGRAPHY", message="The court lines could not be mapped.")
    tracking = helpers.tracking(tracks, events=events, homography=False, duration_s=60.0)
    return tracking.model_copy(update={"warnings": [warning]})


def _film_mapped_with_old_calibration() -> TrackingResult:
    """GPU result of a run that was given OLD_CALIBRATION: like the GPU adapter, it bakes in a
    manual homography and the court positions projected with it (None when off the floor)."""

    def project(px):
        x, y = px[0] * 0.1, px[1] * 0.1
        return (x, y) if 0 <= x <= 84 and 0 <= y <= 50 else None

    tracking = _unmapped_film()  # players' feet at (200, 500) and (1400, 500) px
    tracks = [
        t.model_copy(update={"samples": [
            TrackSample(f=s.f, bbox=s.bbox, court_xy=project(((s.bbox[0] + s.bbox[2]) / 2, s.bbox[3])))
            for s in t.samples
        ]})
        for t in tracking.tracks
    ]
    ball = [BallSample(f=0, xy=(300.0, 250.0), court_xy=project((300.0, 250.0)))]
    court = CourtInfo(homographies=[Homography(matrix=OLD_CALIBRATION, source="manual")])
    return tracking.model_copy(update={"tracks": tracks, "ball": ball, "court": court, "warnings": []})


def test_calibrated_reanalysis_drops_the_stale_no_court_warning():
    analysis = _analyze(_unmapped_film(), _calibrated(CALIBRATION))
    dq = analysis.data_quality
    assert dq.homography_available and dq.coord_mode == "court"
    assert analysis.shots[0].zone == ShotZone.PAINT  # the calibration mapped the shot
    codes = [w.code for w in dq.warnings]
    assert "NO_COURT_HOMOGRAPHY" not in codes and "COURT_NOT_MAPPED" not in codes
    # Without a calibration the pipeline's warning still tells the coach what to do.
    plain = _analyze(_unmapped_film(), Game(scouted_team="Central"))
    assert "NO_COURT_HOMOGRAPHY" in [w.code for w in plain.data_quality.warnings]


def test_recalibrating_after_a_calibrated_gpu_run_uses_the_new_calibration():
    tracking = _film_mapped_with_old_calibration()
    shot = tracking.events[1]  # feet at 120/500 px: (12, 50) ft with the old mapping, (6, 25) ft with the new
    analysis = _analyze(tracking, _calibrated(CALIBRATION))
    first = analysis.shots[0]
    assert first.event_id == shot.event_id
    assert first.court_xy == pytest.approx((6.0, 25.0)) and first.zone == ShotZone.PAINT and first.points == 2
    assert analysis.team(TeamSide.SCOUTED).score == 2
    # The same calibration the GPU run used: nothing changes.
    assert _analyze(tracking, _calibrated(OLD_CALIBRATION)).shots[0].court_xy == pytest.approx((12.0, 50.0))


def test_removing_the_calibration_after_a_calibrated_gpu_run_stops_using_it():
    analysis = _analyze(_film_mapped_with_old_calibration(), Game(scouted_team="Central"))
    dq = analysis.data_quality
    assert not dq.homography_available and dq.coord_mode == "pixel"
    assert analysis.shots[0].zone == ShotZone.UNKNOWN and analysis.shots[0].court_xy is None
    assert "COURT_NOT_MAPPED" in [w.code for w in dq.warnings]


def test_stale_calibration_positions_are_dropped_but_court_model_positions_kept():
    tracking = _film_mapped_with_old_calibration()
    model_track = helpers.track(12, 1, [(f, 40.0, 20.0) for f in range(0, 1800, 3)], jersey="3")  # court model
    holder_xy = tracking.tracks[0].samples[10].court_xy  # the ball in track 1's hands takes his position
    ball = tracking.ball + [
        BallSample(f=30, xy=(210.0, 450.0), court_xy=holder_xy, holder_track_id=1),
        BallSample(f=33, xy=(800.0, 400.0), court_xy=(40.0, 20.0), holder_track_id=12),
    ]
    tracking = tracking.model_copy(update={"tracks": tracking.tracks + [model_track], "ball": ball})
    remapped, matrix = pipeline._court_mapping(_calibrated(CALIBRATION), tracking)
    assert matrix == CALIBRATION and remapped.court.homographies == []
    by_id = {t.track_id: t for t in remapped.tracks}
    assert all(s.court_xy is None for s in by_id[1].samples)
    assert all(s.court_xy == (40.0, 20.0) for s in by_id[12].samples)
    assert [b.court_xy for b in remapped.ball] == [None, None, (40.0, 20.0)]
    assert tracking.tracks[0].samples[0].court_xy is not None  # the caller's tracking is untouched


def test_court_not_mapped_note_does_not_claim_located_shots_have_no_zone():
    tracking = _partly_mapped_tracking(0, 30)  # pixel mode, but the pipeline located the shot
    shot = helpers.event("s1", "shot", 300, track_id=1, team_id=0, made=True, shot_court_xy=[6.0, 25.0])
    analysis = _analyze(tracking.model_copy(update={"events": [shot]}), Game(scouted_team="Central"))
    assert analysis.data_quality.coord_mode == "pixel" and analysis.shots[0].zone == ShotZone.PAINT
    note = next(w for w in analysis.data_quality.warnings if w.code == "COURT_NOT_MAPPED")
    assert "shot zones are unknown" not in note.message and "calibrate the court" in note.message


# ---------------------------------------------------------------------------
# Second review: OpenHoopVision-shaped input
# ---------------------------------------------------------------------------


def test_rebound_type_follows_the_teams_on_the_rows_not_the_pipelines_flag():
    # OpenHoopVision re-derives a shot's team from the jersey colour at the release and flags a
    # rebound offensive when the rebounder's team equals that label. It called Other's #10
    # "team 0" for his miss, so Scouted's rebound came flagged offensive, while the rows credit
    # the miss to Other (his track) and the rebound to Scouted.
    events = [
        ev("j", "jump_ball", 0, won_by_team=1),
        helpers.event("m", "shot", 150, track_id=11, team_id=0, made=False, shot_court_xy=[78.0, 25.0]),
        ev("r", "rebound", 6, track_id=1, offensive=True),
        ev("m2", "shot", 10, track_id=1, made=False, shot_court_xy=[25.5, 25.0]),
        ev("r2", "rebound", 11, track_id=2, offensive=False),  # Scouted's own miss and rebound
    ]
    build = _build(events)
    rows = {r.id: r for r in build.timeline}
    assert (rows["r"].type, rows["r"].side) == (EventType.DREB, S)
    assert (rows["r2"].type, rows["r2"].side) == (EventType.OREB, S)
    assert [(p.side, p.start_reason) for p in build.possessions] == [(O, "jump_ball"), (S, "def_rebound")]
    assert build.possessions[1].transition


def test_rebound_flag_still_decides_when_the_miss_was_not_seen():
    # The film starts at the rebound: there is no missed shot to compare sides with.
    build = _build([ev("r", "rebound", 2, track_id=11, offensive=True)])
    assert [r.type for r in build.timeline if r.source_event_id == "r"] == [EventType.OREB]


def test_block_by_a_teammate_is_not_credited():
    # The GPU looks for the blocker among the opponents of the shot's team label, which can be the
    # wrong team; a "block" by the shooter's teammate must not erase or flag the shot.
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("m", "shot", 5, track_id=1, made=False, shot_court_xy=[25.5, 25.0], blocked_by_track=2),
        ev("a", "shot", 30, track_id=1, made=True, shot_court_xy=[10.0, 25.0], blocked_by_track=2),
        ev("b", "shot", 60, track_id=11, made=False, shot_court_xy=[78.0, 25.0], blocked_by_track=2),
    ]
    build = _build(events)
    assert [(r.id, r.side) for r in build.timeline if r.type == EventType.BLOCK] == [("b:blk", S)]
    shots = {s.event_id: s for s in build.shots}
    assert not shots["m"].blocked and (shots["a"].made, shots["a"].points) == (True, 2) and shots["b"].blocked
    assert build.score == {S: 2, O: 0}


def test_court_positions_from_the_court_model_count_as_a_mapped_court():
    # OpenHoopVision sends court positions but never homography matrices (only a manual calibration
    # becomes one): "Court mapped" on the Data tab and in the report must follow the positions.
    frames = range(0, 1800, 3)
    tracks = [helpers.track(1, 0, [(f, 10.0, 25.0) for f in frames], jersey="23"),
              helpers.track(11, 1, [(f, 70.0, 25.0) for f in frames], jersey="10")]
    events = [helpers.event("s1", "shot", 150, track_id=1, team_id=0, made=True, shot_court_xy=[6.0, 25.0])]
    tracking = helpers.tracking(tracks, events=events, homography=False, duration_s=60.0)
    analysis = _analyze(tracking, Game(scouted_team="Central"))
    dq = analysis.data_quality
    assert dq.coord_mode == "court" and dq.homography_available
    assert analysis.shots[0].zone == ShotZone.PAINT and "COURT_NOT_MAPPED" not in [w.code for w in dq.warnings]


def test_coord_mode_share_counts_players_not_referees():
    # Referee tracks never carry court positions (the court model places players only). Counting
    # them put a film with 55% of player sightings mapped into pixel mode, unlike the GPU pipeline.
    tracking = _partly_mapped_tracking(0, 330)  # two player tracks, 330 of 600 samples mapped
    referees = [helpers.track(1_000_000 + i, None, [(f, 900.0, 500.0) for f in range(0, 1800, 9)],
                              role="referee", court=False) for i in range(3)]
    index = TrackingIndex(tracking.model_copy(update={"tracks": tracking.tracks + referees}), CFG)
    assert index.coord_mode == "court"
    assert index.position(1, 300) == pytest.approx((30.0, 25.0))


@pytest.mark.parametrize("with_foul", [True, False])
def test_defender_holding_the_ball_between_two_free_throws_is_not_a_possession(with_foul):
    # The first free throw drops through; a defender under the basket catches the ball and holds
    # it until the official takes it back for the second one.
    foul = [ev("f", "foul", 5, track_id=11, kind="shooting", fouled_track=1)] if with_foul else []
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("m", "shot", 5, track_id=1, made=False, shot_court_xy=[10.0, 25.0]),
        *foul,
        ev("ft1", "free_throw", 30, track_id=1, made=True),
        ev("ft2", "free_throw", 38, track_id=1, made=True),
        ev("b", "shot", 50, track_id=11, made=False, shot_court_xy=[78.0, 25.0]),
        ev("r", "rebound", 51, track_id=2),
    ]
    build = _build(events, balls=hold(12, 31, 35, xy=(3.0, 25.0)))
    assert _possessions(build) == [
        (S, "jump_ball", PossessionOutcome.FREE_THROWS, 2),
        (O, "made_basket", PossessionOutcome.MISSED_FG, 0),
        (S, "def_rebound", PossessionOutcome.UNKNOWN, 0),
    ]
    assert _rebound_ids(build) == ["r"]


def test_scoring_team_holding_the_ball_after_its_last_free_throw_is_not_a_possession():
    events = [
        ev("j", "jump_ball", 0, won_by_team=0),
        ev("f", "foul", 5, track_id=11, kind="shooting", fouled_track=1),
        ev("ft1", "free_throw", 30, track_id=1, made=True),
        ev("ft2", "free_throw", 35, track_id=1, made=True),
        ev("b", "shot", 60, track_id=11, made=False, shot_court_xy=[78.0, 25.0]),
    ]
    build = _build(events, balls=hold(2, 36, 39, xy=(3.0, 25.0)))  # catches his made free throw
    assert _possessions(build) == [
        (S, "jump_ball", PossessionOutcome.FREE_THROWS, 2),
        (O, "made_basket", PossessionOutcome.MISSED_FG, 0),
    ]
