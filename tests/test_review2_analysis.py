"""Regression tests from the second review of the server-side transform: unseen defensive
rebounds, malformed raw attrs, FREE_THROWS_NOT_DETECTED on the server, and roster matching
(a second track reading a roster number, the coach's override on a referee track)."""

from __future__ import annotations

import pytest

from scout.analysis import pipeline
from scout.analysis import plays as play_rec
from scout.analysis.boxscore import build_box_scores
from scout.analysis.events import INFERRED_CONFIDENCE, build_timeline
from scout.analysis.geometry import CourtConfig
from scout.analysis.plays import PlayRules
from scout.analysis.synthetic import generate_synthetic_game, synthetic_rosters
from scout.analysis.tracking_index import TrackingIndex
from scout.export import fastscout
from scout.roster.matcher import assign_tracks
from scout.schemas import (
    CourtCalibration,
    EventType,
    Game,
    GameAnalysis,
    JerseyRead,
    PipelineWarning,
    PlayType,
    PossessionOutcome,
    RawEventType,
    Roster,
    RosterPlayer,
    TeamSide,
    Track,
    TrackingResult,
    TrackOverride,
    TrackSample,
)
from tests import helpers

S, O = TeamSide.SCOUTED, TeamSide.OTHER
CFG = CourtConfig()
TEAM_MAP = {0: S, 1: O}
FPS = 30
NAMES = {S: "Central", O: "North"}
GAME = Game(id="g", scouted_team="Central", other_team="North", team_id_map=TEAM_MAP)
# track id -> (team id, court position, jersey read)
PLAYERS = {
    1: (0, (25.5, 25.0), "23"), 2: (0, (10.0, 25.0), "5"), 11: (1, (70.0, 25.0), "10"), 12: (1, (60.0, 10.0), "3"),
}


def _rosters() -> dict[TeamSide, Roster]:
    smith = RosterPlayer(id="p23", jersey="23", first_name="Sam", last_name="Smith")
    jones = RosterPlayer(id="p5", jersey="5", first_name="Jo", last_name="Jones")
    return {S: Roster(game_id="g", side=S, team_name="Central", players=[smith, jones]),
            O: Roster(game_id="g", side=O, team_name="North")}


def _tracking(events, *, balls=None, extra_tracks=(), players=PLAYERS, duration_s=120.0) -> TrackingResult:
    frames = range(0, int(duration_s * FPS), 3)
    tracks = [helpers.track(tid, team, [(f, x, y) for f in frames], jersey=j)
              for tid, (team, (x, y), j) in players.items()]
    return helpers.tracking(tracks + list(extra_tracks), balls=balls, events=events, duration_s=duration_s)


def _build(events, *, balls=None):
    tracking = _tracking(events, balls=balls)
    assignments = assign_tracks(tracking, TEAM_MAP, _rosters())
    return build_timeline(tracking, TrackingIndex(tracking, CFG), TEAM_MAP, assignments, _rosters(), CFG)


def _analyze(tracking: TrackingResult, game: Game = GAME, overrides=None) -> GameAnalysis:
    return pipeline.analyze_game(tracking, game, _rosters(), overrides, court=CFG, rules=PlayRules())


def ev(event_id, type_, second, track_id=None, **attrs):
    team = PLAYERS[track_id][0] if track_id in PLAYERS else attrs.pop("team_id", None)
    return helpers.event(event_id, type_, round(second * FPS), track_id=track_id, team_id=team, **attrs)


def hold(track_id, start_s, end_s, xy=(19.0, 25.0)):
    """Ball samples: ``track_id`` holds the ball from ``start_s`` to ``end_s``."""
    return helpers.ball([(f, xy[0], xy[1], track_id) for f in range(int(start_s * FPS), int(end_s * FPS) + 1, 3)])


def _possessions(build):
    return [(p.side, p.start_reason, p.outcome, p.points) for p in build.possessions]


JUMP = ev("j", "jump_ball", 0, won_by_team=0)
MISS = ev("m", "shot", 5, track_id=1, made=False, shot_court_xy=[25.5, 25.0])  # Scouted misses at 5 s


# ---------------------------------------------------------------------------
# Possessions: a defensive rebound the pipeline did not see
# ---------------------------------------------------------------------------


def test_other_team_controlling_the_ball_right_after_a_miss_is_an_unseen_defensive_rebound():
    # No rebound event: North's #3 simply has the ball 1.5 s after the miss, then North scores on the break.
    events = [JUMP, MISS, ev("b", "shot", 12, track_id=11, made=True, shot_court_xy=[78.0, 25.0])]
    build = _build(events, balls=hold(12, 6.5, 9.5))
    assert _possessions(build) == [
        (S, "jump_ball", PossessionOutcome.MISSED_FG, 0),
        (O, "def_rebound", PossessionOutcome.MADE_FG, 2),
        (S, "made_basket", PossessionOutcome.UNKNOWN, 0),
    ]
    poss = build.possessions[1]
    assert poss.transition and poss.start_t == pytest.approx(6.5)
    change = next(r for r in build.timeline if r.id == "poss2")
    assert change.confidence == INFERRED_CONFIDENCE
    # Nobody is credited with the rebound.
    assert not [r for r in build.timeline if r.type in (EventType.DREB, EventType.OREB)]
    boxes = build_box_scores(build.timeline, build.possessions, [], _rosters(), NAMES)
    assert [b.totals.dreb for b in boxes] == [0, 0] and [b.totals.pts for b in boxes] == [0, 2]


@pytest.mark.parametrize(
    ("made", "extra", "balls"),
    [
        (False, [], hold(12, 9.5, 12.5)),  # 4.5 s after the miss: the ball may have gone out of bounds
        (False, [ev("to", "timeout", 6, team_id=1)], hold(12, 6.5, 9.5)),
        (False, [ev("f", "foul", 6, track_id=2, kind="personal", fouled_track=12)], hold(12, 6.5, 9.5)),
        (False, [], hold(2, 5.5, 7.6) + hold(12, 7.8, 10.8)),  # Scouted had its miss back first
        (None, [], hold(12, 6.5, 9.5)),  # result unknown: the shot may have gone in
    ],
    ids=["late", "timeout", "foul", "offense-got-it-back", "unknown-result"],
)
def test_other_team_controlling_the_ball_otherwise_stays_an_inferred_possession(made, extra, balls):
    miss = ev("m", "shot", 5, track_id=1, made=made, shot_court_xy=[25.5, 25.0])
    events = [JUMP, miss, *extra, ev("b", "shot", 15, track_id=11, made=True, shot_court_xy=[78.0, 25.0])]
    poss = _build(events, balls=balls).possessions[1]
    assert (poss.side, poss.start_reason, poss.transition) == (O, "inferred", False)


def test_unseen_defensive_rebound_of_a_missed_last_free_throw():
    events = [
        JUMP,
        ev("f", "foul", 5, track_id=11, kind="personal", fouled_track=1),  # in the bonus
        ev("ft1", "free_throw", 30, track_id=1, made=True),
        ev("ft2", "free_throw", 33, track_id=1, made=False),
        ev("b", "shot", 40, track_id=11, made=True, shot_court_xy=[78.0, 25.0]),
    ]
    build = _build(events, balls=hold(12, 34.5, 37.0))
    assert _possessions(build) == [
        (S, "jump_ball", PossessionOutcome.FREE_THROWS, 1),
        (O, "def_rebound", PossessionOutcome.MADE_FG, 2),
        (S, "made_basket", PossessionOutcome.UNKNOWN, 0),
    ]
    assert build.possessions[1].transition


def test_turnover_right_after_an_unseen_defensive_rebound():
    # North never shows up as the ball holder, but loses the ball 2.5 s after the miss: it had it.
    events = [JUMP, MISS, ev("t", "turnover", 7.5, track_id=11, kind="bad_pass"),
              ev("a", "shot", 12, track_id=2, made=True, shot_court_xy=[10.0, 25.0])]
    assert [(p.side, p.start_reason) for p in _build(events).possessions] == [
        (S, "jump_ball"), (O, "def_rebound"), (S, "turnover"), (O, "made_basket"),
    ]


def _after_unseen_rebound(*events):
    """Scouted misses at 5 s; North holds the ball from 6 s (nobody seen rebounding), then ``events``."""
    poss = _build([JUMP, MISS, *events], balls=hold(12, 6.0, 8.5)).possessions[1]
    assert (poss.side, poss.start_reason) == (O, "def_rebound")
    return poss


def test_transition_rules_hold_after_an_unseen_defensive_rebound():
    quick_shot = ev("b", "shot", 12, track_id=11, made=True, shot_court_xy=[78.0, 25.0])  # 6 s after the takeover
    assert _after_unseen_rebound(quick_shot).transition
    assert not _after_unseen_rebound(ev("to", "timeout", 9, team_id=1), quick_shot).transition
    common_foul = ev("f", "foul", 9, track_id=2, kind="personal", fouled_track=11)
    assert not _after_unseen_rebound(common_foul, quick_shot).transition
    reset = (  # quick miss, offensive rebound, then a half-court possession that ends at 30 s
        ev("b1", "shot", 9, track_id=11, made=False, shot_court_xy=[78.0, 25.0]),
        ev("r2", "rebound", 10, track_id=12),
        ev("b2", "shot", 30, track_id=12, made=True, shot_court_xy=[78.0, 25.0]),
    )
    assert not _after_unseen_rebound(*reset).transition
    fouled_drive = (  # fouled 3 s after the takeover; the free throws come much later
        ev("f", "foul", 9, track_id=2, kind="shooting", fouled_track=11),
        ev("ft1", "free_throw", 40, track_id=11, made=True),
        ev("ft2", "free_throw", 43, track_id=11, made=True),
    )
    assert _after_unseen_rebound(*fouled_drive).transition


def _defensive_rebounds(tracking: TrackingResult) -> set[str]:
    """Ids of rebound events by the team that did not take the missed shot / free throw."""
    out: set[str] = set()
    missed_by: int | None = None
    for e in sorted(tracking.events, key=lambda e: e.frame):
        if e.type in (RawEventType.SHOT, RawEventType.FREE_THROW):
            missed = e.attrs.get("made") is not True or e.attrs.get("blocked_by_track") is not None
            missed_by = e.team_id if missed else None
        elif e.type == RawEventType.REBOUND:
            if missed_by is not None and e.team_id != missed_by:
                out.add(e.event_id)
            missed_by = None
    return out


def _fast_breaks_found(analysis: GameAnalysis, scripted: list[dict]) -> int:
    return sum(
        any(p.type == PlayType.FAST_BREAK and p.side is not None and p.side.value == s["side"]
            and p.start_t <= s["end_t"] + 0.5 and s["start_t"] <= p.end_t + 0.5 for p in analysis.plays)
        for s in scripted
    )


@pytest.mark.parametrize("seed", [3, 7])
def test_fast_breaks_are_found_when_the_pipeline_misses_the_defensive_rebounds(seed):
    tracking, truth = generate_synthetic_game(seed=seed, duration_s=600.0)
    dropped = _defensive_rebounds(tracking)
    unseen = tracking.model_copy(update={"events": [e for e in tracking.events if e.event_id not in dropped]})
    game = GAME.model_copy(update={"id": "g_syn"})
    rosters = synthetic_rosters(game.id, seed=seed)
    full, partial = (pipeline.analyze_game(t, game, rosters, [], court=CFG, rules=PlayRules())
                     for t in (tracking, unseen))
    breaks = [p for p in truth.plays if p["type"] == "fast_break"]
    assert len(dropped) >= 10 and len(breaks) >= 10
    assert _fast_breaks_found(partial, breaks) >= _fast_breaks_found(full, breaks) - 1
    # The same possessions, each unseen rebound still a defensive-rebound start, but no DREB credited.
    starts = [[(p.side, p.start_reason) for p in a.possessions] for a in (full, partial)]
    assert starts[1] == starts[0]
    assert [b.totals.dreb for b in partial.box_scores] == [0, 0]
    last = partial.timeline[-1]
    assert [b.totals.pts for b in partial.box_scores] == [last.score_scouted, last.score_other]
    assert [last.score_scouted, last.score_other] == [truth.score["scouted"], truth.score["other"]]


def test_steal_is_never_credited_to_a_teammate_of_the_player_who_lost_the_ball():
    # The GPU's team label for Scouted's #5 flickered for a moment, so his catch looked like a steal.
    build = _build([JUMP, ev("t", "turnover", 5, track_id=1, kind="steal", stolen_by_track=2)])
    steal = next(r for r in build.timeline if r.type == EventType.STEAL)
    assert (steal.side, steal.player) == (O, None)  # still a steal (the kind says so), by an unknown North player
    boxes = build_box_scores(build.timeline, build.possessions, [], _rosters(), NAMES)
    assert [b.totals.stl for b in boxes] == [0, 1] and [b.totals.tov for b in boxes] == [1, 0]
    plain = _build([JUMP, ev("t", "turnover", 5, track_id=1, kind="bad_pass", stolen_by_track=2)])
    assert not [r for r in plain.timeline if r.type == EventType.STEAL]
    assert [(p.side, p.start_reason) for p in plain.possessions] == [(S, "jump_ball"), (O, "turnover")]


# ---------------------------------------------------------------------------
# Plays: raw attrs are unchecked JSON
# ---------------------------------------------------------------------------


def test_malformed_turnover_kind_does_not_fail_the_analysis():
    events = [JUMP, ev("t", "turnover", 5, track_id=1, kind=["travel"]),
              ev("b", "shot", 12, track_id=11, made=True, shot_court_xy=[78.0, 25.0])]
    analysis = _analyze(_tracking(events))
    assert [p.start_reason for p in analysis.possessions] == ["jump_ball", "turnover", "made_basket"]
    assert analysis.team(O).score == 2


# ---------------------------------------------------------------------------
# Data quality: FREE_THROWS_NOT_DETECTED
# ---------------------------------------------------------------------------

PX_PER_FT = 20.0
CALIBRATION = [[1 / PX_PER_FT, 0.0, 0.0], [0.0, 1 / PX_PER_FT, 0.0], [0.0, 0.0, 1.0]]  # 20 px = 1 ft
NO_COURT = PipelineWarning(code="NO_COURT_HOMOGRAPHY", message="The court lines could not be mapped.")
FT_WARNING = PipelineWarning(code="FREE_THROWS_NOT_DETECTED", message="Free throws could not be detected.")
SHOT_PX = helpers.event("s1", "shot", 150, track_id=1, team_id=0, made=True, shot_xy_px=[6.0 * PX_PER_FT, 500.0])
FREE_THROWS = [helpers.event("ft1", "free_throw", 600, track_id=1, team_id=0, made=True),
               helpers.event("ft2", "free_throw", 660, track_id=1, team_id=0, made=False)]


def _unmapped_film(events, warnings) -> TrackingResult:
    """GPU result in pixels only (no court positions, no homography) with the given warnings."""
    frames = range(0, 1800, 3)
    tracks = [
        helpers.track(1, 0, [(f, 10.0 * PX_PER_FT, 25.0 * PX_PER_FT) for f in frames], jersey="23", court=False),
        helpers.track(11, 1, [(f, 70.0 * PX_PER_FT, 25.0 * PX_PER_FT) for f in frames], jersey="10", court=False),
    ]
    tracking = helpers.tracking(tracks, events=[JUMP, *events], homography=False, duration_s=60.0)
    return tracking.model_copy(update={"warnings": list(warnings)})


def _calibrated() -> Game:
    calibration = CourtCalibration(points=[], matrix=CALIBRATION, reprojection_error_ft=0.3)
    return GAME.model_copy(update={"calibration": calibration})


def _free_throw_notes(analysis: GameAnalysis) -> list[PipelineWarning]:
    return [w for w in analysis.data_quality.warnings if w.code == "FREE_THROWS_NOT_DETECTED"]


def test_unmapped_gpu_run_without_free_throws_warns_that_they_were_not_detected():
    # A GPU result from a pipeline that does not send FREE_THROWS_NOT_DETECTED itself.
    [note] = _free_throw_notes(_analyze(_unmapped_film([SHOT_PX], [NO_COURT])))
    assert note.severity == "warning" and "2-point attempt" in note.message
    assert "Calibrate the court, then choose Full re-analysis" in note.message
    # A calibrated re-analysis maps the court on the server, but cannot find the free throws.
    calibrated = _analyze(_unmapped_film([SHOT_PX], [NO_COURT]), _calibrated())
    assert calibrated.data_quality.coord_mode == "court"
    assert "NO_COURT_HOMOGRAPHY" not in [w.code for w in calibrated.data_quality.warnings]
    [note] = _free_throw_notes(calibrated)
    assert "Full re-analysis" in note.message and "Calibrate the court" not in note.message


def test_pipeline_free_throw_warning_survives_a_calibrated_reanalysis_once():
    analysis = _analyze(_unmapped_film([SHOT_PX], [NO_COURT, FT_WARNING]), _calibrated())
    assert _free_throw_notes(analysis) == [FT_WARNING]
    assert "NO_COURT_HOMOGRAPHY" not in [w.code for w in analysis.data_quality.warnings]


def test_no_free_throw_warning_when_free_throws_were_found_or_the_court_was_mapped():
    assert _free_throw_notes(_analyze(_unmapped_film([SHOT_PX, *FREE_THROWS], [NO_COURT]))) == []
    assert _free_throw_notes(_analyze(_unmapped_film([SHOT_PX], []))) == []
    # The demo film without a court mapping still has its scripted free throws.
    tracking, _ = generate_synthetic_game(seed=7, duration_s=300.0, with_homography=False)
    assert "NO_COURT_HOMOGRAPHY" in [w.code for w in tracking.warnings]
    assert any(e.type == RawEventType.FREE_THROW for e in tracking.events)
    game = GAME.model_copy(update={"id": "g_demo"})
    analysis = pipeline.analyze_game(tracking, game, synthetic_rosters(game.id, seed=7), [], court=CFG,
                                     rules=PlayRules())
    assert _free_throw_notes(analysis) == []


# ---------------------------------------------------------------------------
# Roster matching: a second track reading a roster number, overrides on referee tracks
# ---------------------------------------------------------------------------


def _reads_track(track_id: int, team_id: int | None, frames: tuple[int, int], reads, *, role="player") -> Track:
    """A track sampled every 3 frames over ``frames``; reads are texts (conf 0.9) or (text, conf)."""
    samples = [TrackSample(f=f, bbox=(0.0, 0.0, 10.0, 60.0)) for f in range(frames[0], frames[1] + 1, 3)]
    jersey_reads = [JerseyRead(frame=frames[0] + 3 * i, text=r if isinstance(r, str) else r[0],
                               conf=0.9 if isinstance(r, str) else r[1]) for i, r in enumerate(reads)]
    return Track(track_id=track_id, team_id=team_id, role=role, jersey_reads=jersey_reads, samples=samples)


def test_second_track_reading_a_roster_number_goes_to_the_team_line():
    # The tracker follows Smith (#23) twice at once (a duplicate box, or a teammate's #23 read by mistake):
    # the weaker track loses the conflict, and it must not become a second "#23" next to "#23 Sam Smith".
    frames = range(0, 1800, 3)
    tracks = [
        helpers.track(1, 0, [(f, 30.0, 25.0) for f in frames], jersey="23"),
        helpers.track(2, 0, [(f, 40.0, 25.0) for f in range(300, 1500, 3)], jersey="23"),
        helpers.track(11, 1, [(f, 70.0, 25.0) for f in frames], jersey="10"),
    ]
    shot = helpers.event("a", "shot", 600, track_id=2, team_id=0, made=True, shot_court_xy=[10.0, 25.0])
    analysis = _analyze(helpers.tracking(tracks, events=[shot], duration_s=60.0))

    ghost = next(a for a in analysis.track_assignments if a.track_id == 2)
    assert (ghost.player_id, ghost.side, ghost.jersey, ghost.best_read) == (None, S, None, "23")
    assert ghost.method == "unrostered"
    box = analysis.box_score(S)
    assert [(line.player.player_id, line.player.jersey) for line in box.players] == [("p5", "5"), ("p23", "23")]
    assert box.team_unattributed.pts == 2 and box.totals.pts == analysis.team(S).score == 2
    assert analysis.data_quality.unmatched_jerseys == []
    assert analysis.data_quality.tracks_total == 3 and analysis.data_quality.tracks_assigned == 1
    block = fastscout.build_paste_block(analysis, GAME, roster=_rosters()[S])
    assert "Twenty Three" not in block and "Smith" in block


def test_unmatched_tracks_never_show_a_roster_number():
    rosters = {
        S: Roster(game_id="g", side=S, players=[RosterPlayer(id="p23", jersey="23", last_name="Smith"),
                                                 RosterPlayer(id="p05", jersey="05", last_name="Cole")]),
        O: Roster(game_id="g", side=O, players=[RosterPlayer(id="o10", jersey="10", last_name="Park")]),
    }
    tracks = [
        _reads_track(1, 0, (0, 900), ["23"] * 5),
        _reads_track(2, 0, (300, 600), ["23", "23"]),  # on screen with #23
        _reads_track(3, 0, (0, 900), ["05"] * 5),
        _reads_track(4, 0, (300, 600), ["5", "5"]),  # "5" is #05's number too
        _reads_track(5, 0, (1000, 1300), [("23", 0.9), ("8", 0.8), ("6", 0.8)]),  # votes too split to name #23
        _reads_track(6, 0, (1000, 1300), ["14", "14"]),  # not on the roster: shown as #14
        _reads_track(7, None, (1000, 1300), ["10", "10"]),  # team unknown, #10 is on screen in track 8
        _reads_track(8, 1, (900, 1500), ["10"] * 5),
    ]
    result = {a.track_id: a for a in assign_tracks(helpers.tracking(tracks), TEAM_MAP, rosters)}
    assert [result[t].player_id for t in (1, 3, 8)] == ["p23", "p05", "o10"]
    for track_id in (2, 4, 5, 7):
        a = result[track_id]
        assert (a.player_id, a.jersey, a.method) == (None, None, "unrostered"), track_id
        assert a.best_read is not None and a.match_score > 0
    assert (result[2].side, result[7].side) == (S, None)
    assert (result[6].jersey, result[6].method) == ("14", "unrostered")


def test_unknown_player_override_on_a_referee_track_makes_it_a_player_of_that_side():
    tracks = [
        _reads_track(1, 0, (0, 900), ["23"] * 3),
        _reads_track(90, None, (0, 900), ["12"] * 3, role="referee"),  # Unknown player (keep team), side named
        _reads_track(91, None, (0, 900), ["12"] * 3, role="referee"),  # Unknown player, no side to keep
        _reads_track(92, None, (0, 900), ["12"] * 3, role="referee"),  # no override: still a referee
        _reads_track(2, 0, (0, 900), ["23"] * 3),  # Unknown player on a track that reads Smith's number
    ]
    overrides = [TrackOverride(track_id=90, side=S), TrackOverride(track_id=91), TrackOverride(track_id=2)]
    result = {a.track_id: a for a in assign_tracks(helpers.tracking(tracks), TEAM_MAP, _rosters(), overrides)}
    fields = ("role", "side", "player_id", "jersey", "method")
    assert tuple(getattr(result[90], f) for f in fields) == ("player", S, None, None, "manual")
    assert tuple(getattr(result[91], f) for f in fields) == ("player", None, None, None, "manual")
    assert tuple(getattr(result[92], f) for f in fields) == ("referee", None, None, None, "none")
    assert tuple(getattr(result[2], f) for f in fields) == ("player", S, None, None, "manual")
    assert result[1].player_id == "p23"


@pytest.mark.parametrize(
    ("override", "scorer"),
    [(TrackOverride(track_id=99, side=S), None), (TrackOverride(track_id=99, player_id="p5"), "p5")],
    ids=["unknown-player", "roster-player"],
)
def test_coach_override_on_a_referee_track_counts_its_events(override, scorer):
    # The pipeline called a scouted player a referee (a striped warm-up shirt); he scores at 10 s.
    referee = helpers.track(99, None, [(f, 15.0, 25.0) for f in range(0, 1800, 3)], role="referee")
    events = [JUMP, helpers.event("a", "shot", 300, track_id=99, made=True, shot_court_xy=[10.0, 25.0])]
    tracking = _tracking(events, extra_tracks=[referee], players={1: PLAYERS[1], 11: PLAYERS[11]}, duration_s=60.0)
    analysis = _analyze(tracking, overrides=[override])

    assert analysis.team(S).score == 2
    shot = next(r for r in analysis.timeline if r.id == "a")
    assert shot.side == S and (shot.player.player_id if shot.player else None) == scorer
    box = analysis.box_score(S)
    assert [line.player.player_id for line in box.players if line.pts] == ([scorer] if scorer else [])
    assert box.team_unattributed.pts == (0 if scorer else 2)
    # Play recognition counts him among the scouted players too.
    sides = play_rec._track_sides(TrackingIndex(tracking, CFG), TEAM_MAP, analysis.track_assignments)
    assert sides[99] == S
