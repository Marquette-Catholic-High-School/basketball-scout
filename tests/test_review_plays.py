"""Review regressions for play recognition: free-throw credit, dead-ball starts, ID switches, rebounds, rules.

Scenes reuse ``tests.test_plays.Scene`` (court feet, offense = team 0 attacking the LEFT basket).
"""

from __future__ import annotations

import pytest

from scout.analysis.geometry import CourtConfig
from scout.analysis.plays import PlayRules, detect_plays, load_play_rules
from scout.analysis.tracking_index import TrackingIndex
from scout.errors import ErrorCode, ScoutError
from scout.schemas import (
    EventType,
    PlayOutcome,
    PlayType,
    Possession,
    TeamSide,
    TimelineEvent,
    TrackAssignment,
    TrackingResult,
)
from tests.test_plays import (
    FPS,
    SIDES,
    Scene,
    defense_scene,
    fast_break_scene,
    only,
    press_scene,
    spot_up_scene,
    toward_basket,
    types,
)

COURT = CourtConfig()


def free_throw(scene: Scene, t: float, tid: int, *, made: bool = True) -> Scene:
    """Add a free throw (raw event + timeline row) to a scene."""
    team = scene.keys[tid][0]
    eid = scene._raw("free_throw", t, tid, team, made=made)
    scene.rows.append(
        TimelineEvent(id=f"r{len(scene.rows)}", t=t, frame=round(t * FPS),
                      type=EventType.FT_MADE if made else EventType.FT_MISSED, label="FT", side=SIDES[team],
                      points=1 if made else 0, source_event_id=eid)
    )
    return scene


def detect_tracking(tracking: TrackingResult, rows: list[TimelineEvent], seconds: float) -> list:
    """Scene.detect for a tracking result edited after Scene.build()."""
    end = int(seconds * FPS)
    possessions = [Possession(id=1, side=TeamSide.SCOUTED, start_t=0.0, end_t=seconds, start_frame=0, end_frame=end,
                              start_reason="made_basket")]
    assignments = [TrackAssignment(track_id=t.track_id, team_id=t.team_id, side=SIDES[t.team_id],
                                   jersey=str(t.track_id)) for t in tracking.tracks]
    index = TrackingIndex(tracking, COURT)
    return detect_plays(index, sorted(rows, key=lambda r: r.frame), possessions, assignments, SIDES, COURT,
                        PlayRules())


# ---------------------------------------------------------------------------
# Points: free throws belong to the action that drew the foul
# ---------------------------------------------------------------------------


def test_free_throws_from_a_later_foul_are_not_credited_to_an_earlier_play():
    """Missed spot-up 3, offensive rebound, the rebounder is fouled on his drive (no shot logged), 2 FTs made."""
    s = spot_up_scene()
    s.seconds = 11.0
    s.rows.clear()
    s.raw.clear()
    s.shot(2.6, 3, made=False, points=3)
    s.player(5, 0, (0, 9, 33), (3.6, 6, 27), (5.0, 5.5, 25.5), (11, 5.5, 25.5))
    s.player(15, 1, (0, 7, 31), (3.6, 4.5, 28.5), (11, 4.5, 28.5))
    s.row("rebound", 3.6, 5, 0, offensive=True).hold(3.6, 5.0, 5)
    s.row("foul", 5.0, 15, 1, kind="shooting", fouled_track=5)
    free_throw(s, 8.0, 5)
    free_throw(s, 10.0, 5)
    play = only(s.detect(), PlayType.SPOT_UP)
    assert play.outcome == PlayOutcome.MISSED_FG and play.points == 0


def test_and_one_free_throw_counts_for_the_play():
    """The shooting foul is logged just after the made shot; the and-one free throw belongs to the shot."""
    s = spot_up_scene()
    s.seconds = 8.0
    s.player(3, 0, (0, 3.5, 47), (8, 3.5, 47))
    s.row("foul", 2.65, 13, 1, kind="shooting", fouled_track=3)
    free_throw(s, 5.2, 3)
    play = only(s.detect(), PlayType.SPOT_UP)
    assert play.outcome == PlayOutcome.MADE_FG and play.points == 4


# ---------------------------------------------------------------------------
# Dead-ball turnovers: an inbound, not transition (FastScout) -- and a press can follow
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(("kind", "fast_break"), [("out_of_bounds", False), ("travel", False), ("bad_pass", True)])
def test_fast_break_needs_a_live_ball_turnover(kind, fast_break):
    s = fast_break_scene()
    s.row("turnover", 0.0, 12, 1, kind=kind)  # the other team lost it at the start of this possession
    assert (PlayType.FAST_BREAK in types(s.detect(start_reason="turnover"))) is fast_break


def test_press_after_a_dead_ball_turnover():
    s = press_scene()
    s.row("turnover", 0.0, 13, 1, kind="out_of_bounds")
    play = only(s.detect(start_reason="turnover"), PlayType.PRESS)
    assert play.side == TeamSide.OTHER


# ---------------------------------------------------------------------------
# Tracking artefacts: ID switches and rebounds are not passes
# ---------------------------------------------------------------------------


def _split_track(tracking: TrackingResult, tid: int, new_tid: int, frame: int) -> TrackingResult:
    """The tracker loses ``tid`` after ``frame`` and picks the same player up as ``new_tid`` (ID switch)."""
    tracks = []
    for t in tracking.tracks:
        if t.track_id != tid:
            tracks.append(t)
            continue
        tracks.append(t.model_copy(update={"samples": [s for s in t.samples if s.f <= frame]}))
        tracks.append(t.model_copy(update={"track_id": new_tid, "samples": [s for s in t.samples if s.f > frame]}))
    ball = [b.model_copy(update={"holder_track_id": new_tid}) if b.holder_track_id == tid and b.f > frame else b
            for b in tracking.ball]
    events = [e.model_copy(update={"track_id": new_tid}) if e.track_id == tid and e.frame > frame else e
              for e in tracking.events]
    return tracking.model_copy(update={"tracks": tracks, "ball": ball, "events": events})


def test_id_switch_of_the_ball_handler_is_not_a_handoff():
    """#1 dribbles slowly at the top; the tracker re-labels him #21 mid-dribble."""
    handler = [(0, 27, 25), (6, 25, 22)]
    s = Scene(6.0).player(1, 0, *handler).player(11, 1, *toward_basket(handler, 3.0))
    s.player(2, 0, (0, 21, 7), (6, 21, 7)).player(12, 1, *toward_basket([(0, 21, 7), (6, 21, 7)], 4.0))
    s.hold(0, 5.0, 1).shot(5.0, 1, made=False)
    tracking = _split_track(s.build(), 1, 21, round(3.0 * FPS))
    plays = detect_tracking(tracking, s.rows, s.seconds)
    assert PlayType.HANDOFF not in types(plays), [(p.type.value, p.players) for p in plays]


def test_offensive_rebound_is_not_a_catch():
    """#5 crashes from the arc, grabs the offensive rebound in the paint and kicks out for a corner 3:
    that is a spot-up, not a cut (the ball came off the rim, nobody passed it to #5)."""
    s = Scene(7.0)
    s.player(2, 0, (0, 21, 7), (7, 21, 7)).player(12, 1, *toward_basket([(0, 21, 7), (7, 21, 7)], 3.5))
    s.player(5, 0, (0, 22, 40), (2.0, 22, 40), (3.5, 8, 27), (7, 8, 27))
    s.player(15, 1, (0, 18, 37), (2.0, 18, 37), (3.5, 6, 29), (7, 6, 29))
    s.player(3, 0, (0, 3.5, 47), (7, 3.5, 47)).player(13, 1, (0, 6, 41), (4.6, 6, 41), (5.0, 5, 44), (7, 5, 44))
    s.hold(0, 2.0, 2).shot(2.0, 2, made=False, points=3)
    s.row("rebound", 3.5, 5, 0, offensive=True).hold(3.5, 4.5, 5)
    s.hold(5.0, 5.6, 3).shot(5.6, 3, points=3)
    plays = s.detect()
    assert PlayType.CUT not in types(plays), [(p.type.value, p.attrs) for p in plays]
    spot = only(plays, PlayType.SPOT_UP)
    assert spot.players["passer"].label == "#5" and spot.points == 3


def test_bringing_the_ball_up_is_not_an_isolation():
    """The guard walks the ball up from the backcourt with his man on him, then swings it to the wing for a 3."""
    pg = [(0, 50, 25), (3.0, 24, 25), (6, 24, 25)]
    s = Scene(6.0).player(1, 0, *pg).player(11, 1, *toward_basket(pg, 3.5))
    for tid, spot in {2: (21.0, 7.0), 3: (21.0, 43.0), 4: (3.5, 47.0), 5: (8.0, 17.5)}.items():
        s.player(tid, 0, (0, *spot), (6, *spot)).player(10 + tid, 1, *toward_basket([(0, *spot), (6, *spot)], 4.0))
    s.hold(0, 4.0, 1).hold(4.4, 5.0, 2).shot(5.0, 2, points=3)
    plays = s.detect()
    assert PlayType.ISOLATION not in types(plays), [(p.type.value, p.attrs) for p in plays]
    assert only(plays, PlayType.SPOT_UP).points == 3


def test_basket_after_halftime_without_period_markers():
    """Cut film (no period breaks found): the scouted team shot at the RIGHT basket before half time and at the
    LEFT one after. A shot-less half-court possession right after the switch attacks the left basket."""
    shift = 46.0
    base = defense_scene("man")
    s = Scene(shift + 12.0)
    for tid, (team, keys) in base.keys.items():
        s.player(tid, team, *[(t + shift, x, y) for t, x, y in keys])
    s.hold(shift, shift + 12.0, 1)
    for t, xy in ((30.0, (78.0, 25.0)), (40.0, (79.0, 20.0)), (62.0, (6.0, 25.0))):  # earlier / later possessions
        s.rows.append(TimelineEvent(id=f"x{t:.0f}", t=t, frame=round(t * FPS), type=EventType.SHOT_MISSED,
                                    label="shot", side=TeamSide.SCOUTED, court_xy=xy))
    possession = Possession(id=7, side=TeamSide.SCOUTED, start_t=shift, end_t=shift + 12.0,
                            start_frame=round(shift * FPS), end_frame=round((shift + 12.0) * FPS),
                            start_reason="made_basket")
    play = only(s.detect(possessions=[possession]), PlayType.MAN_DEFENSE)
    assert play.possession_id == 7 and play.side == TeamSide.OTHER


def test_bench_players_do_not_block_the_defense_label():
    """Two players of the defending team sit on their bench in the other half (mapped off the court)."""
    s = defense_scene("man")
    s.player(31, 1, (0, 60, 55), (12, 60, 55)).player(32, 1, (0, 66, 55.5), (12, 66, 55.5))
    play = only(s.detect(), PlayType.MAN_DEFENSE)
    assert play.side == TeamSide.OTHER


# ---------------------------------------------------------------------------
# Rules file
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("text", ["defense:\n  sample_hz: 0\n", "pick_and_roll:\n  screen_distance_ft: -4\n"])
def test_impossible_thresholds_are_a_config_error(tmp_path, text):
    path = tmp_path / "rules.yaml"
    path.write_text(text)
    with pytest.raises(ScoutError) as exc:
        load_play_rules(path)
    assert exc.value.code == ErrorCode.CONFIG_INVALID
    assert text.split(":")[1].strip() in exc.value.message  # names the setting


# ---------------------------------------------------------------------------
# Second review
# ---------------------------------------------------------------------------


def _screen_with_a_ball_dropout(*, shot: bool) -> Scene:
    """#2 screens for #1 at the top; the ball is not detected for half a second in the middle of the
    screen (the dribble hidden behind the screener). #1 then swings it to #3 on the wing."""
    handler = [(0, 30, 25), (4.0, 30, 25), (5.0, 22, 32), (6.0, 20, 34), (9, 20, 34)]
    s = Scene(9.0).player(1, 0, *handler).player(11, 1, *toward_basket(handler, 3.0))
    s.player(2, 0, (0, 20, 40), (2.0, 30.5, 28.2), (3.8, 30.5, 28.2), (5.5, 9, 24), (9, 9, 24))
    s.player(12, 1, (0, 18, 37), (2.0, 28, 27), (3.8, 28, 27), (5.5, 11, 24), (9, 11, 24))
    s.player(3, 0, (0, 21, 7), (9, 21, 7)).player(13, 1, *toward_basket([(0, 21, 7), (9, 21, 7)], 4.0))
    s.hold(0, 2.4, 1).hold(2.9, 6.5, 1).hold(7.0, 8.4, 3)
    return s.shot(8.4, 3, points=3) if shot else s


@pytest.mark.parametrize("shot", [False, True])
def test_one_ball_screen_split_by_a_ball_dropout_is_one_play(shot):
    plays = _screen_with_a_ball_dropout(shot=shot).detect()
    screens = [p for p in plays if p.type in (PlayType.PICK_AND_ROLL, PlayType.PICK_AND_POP)]
    assert len(screens) == 1, [(p.type.value, p.start_t, p.end_t, p.outcome.value) for p in plays]
    assert screens[0].outcome == (PlayOutcome.MADE_FG if shot else PlayOutcome.NO_SHOT)


def test_two_screeners_across_a_ball_dropout_are_two_ball_screens():
    """A double screen (#2 on the right, #4 on the left): each screen once, neither merged into the other."""
    s = _screen_with_a_ball_dropout(shot=False)
    s.player(4, 0, (0, 20, 10), (2.0, 30.5, 21.8), (3.8, 30.5, 21.8), (5.5, 21, 7), (9, 21, 7))
    s.player(14, 1, (0, 18, 13), (2.0, 28, 23), (3.8, 28, 23), (5.5, 18, 9), (9, 18, 9))
    screens = [p for p in s.detect() if p.type in (PlayType.PICK_AND_ROLL, PlayType.PICK_AND_POP)
               and p.players["ball_handler"].label == "#1"]
    assert sorted(p.players["screener"].label for p in screens) == ["#2", "#4"]


@pytest.mark.parametrize("encoding", ["cp1252", "utf-16"])
def test_play_rules_not_saved_as_utf8_is_a_config_error(tmp_path, encoding):
    """Notepad's "Unicode" (UTF-16) or a Windows code page: a settings problem, not a failed analysis to retry."""
    path = tmp_path / "rules.yaml"
    path.write_bytes("# coach’s tweaks\npick_and_roll:\n  screen_distance_ft: 5\n".encode(encoding))
    with pytest.raises(ScoutError) as exc:
        load_play_rules(path)
    assert exc.value.code == ErrorCode.CONFIG_INVALID and "UTF-8" in exc.value.message


def test_zero_min_move_with_a_still_attacker_still_labels_the_defense(tmp_path):
    """defense.min_move_ft: 0 is allowed; an attacker standing perfectly still must not divide by zero."""
    path = tmp_path / "rules.yaml"
    path.write_text("defense:\n  min_move_ft: 0\n")
    s = defense_scene("man")
    s.player(5, 0, (0, 3.5, 47), (12, 3.5, 47)).player(15, 1, *toward_basket([(0, 3.5, 47), (12, 3.5, 47)], 3.5))
    assert PlayType.MAN_DEFENSE in types(s.detect(rules=load_play_rules(path)))


@pytest.mark.parametrize("seconds", [0.3, 1.0, 1.5])
def test_demo_game_for_a_very_short_clip_stays_inside_the_film(seconds):
    from scout.analysis.synthetic import generate_synthetic_game
    from scout.schemas import RawEventType

    tracking, truth = generate_synthetic_game(seed=3, duration_s=seconds)
    frames = {e.type: e.frame for e in tracking.events}
    assert all(0 <= e.frame < tracking.video.frame_count for e in tracking.events), frames
    order = [RawEventType.PERIOD_START, RawEventType.JUMP_BALL, RawEventType.PERIOD_END]
    assert [frames[t] for t in order] == sorted(frames[t] for t in order)
    assert sum(truth.score.values()) == 0


def test_window_reads_short_tracks_only_where_they_exist(monkeypatch):
    """Film without re-identification splits every player into short tracks; a long possession (sparse
    events) must not look up every fragment at every sample of the possession (minutes on a full game)."""
    from scout.analysis.synthetic import generate_synthetic_game

    tracking, _ = generate_synthetic_game(seed=3, duration_s=120.0)
    tracks, next_id = [], 1000
    for t in tracking.tracks:
        for i in range(0, len(t.samples), 20):  # 2 s fragments
            tracks.append(t.model_copy(update={"track_id": next_id, "samples": t.samples[i:i + 20]}))
            next_id += 1
    tracking = tracking.model_copy(update={"tracks": tracks})
    index = TrackingIndex(tracking, COURT)
    calls = 0
    position = TrackingIndex.position

    def counted(self, *args, **kwargs):
        nonlocal calls
        calls += 1
        return position(self, *args, **kwargs)

    monkeypatch.setattr(TrackingIndex, "position", counted)
    end = tracking.video.frame_count - 1
    possession = Possession(id=1, side=TeamSide.SCOUTED, start_t=0.0, end_t=end / FPS, start_frame=0, end_frame=end,
                            start_reason="inferred")
    assignments = [TrackAssignment(track_id=t.track_id, team_id=t.team_id, side=SIDES.get(t.team_id), role=t.role)
                   for t in tracks]
    detect_plays(index, [], [possession], assignments, SIDES, COURT, PlayRules())
    samples = sum(len(t.samples) for t in tracks if t.role == "player")
    assert calls <= 2 * samples, (calls, samples)
