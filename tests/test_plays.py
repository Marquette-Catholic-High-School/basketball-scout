"""Play recognition: rules loading, one hand-made scenario per detector, linking and summaries.

Scenes use court feet with the offense (team 0 = scouted) attacking the LEFT basket at
(5.25, 25), so x is the distance from the attacked baseline. Pixel scenes multiply feet
by 20 (helpers.track draws 120 px tall boxes, which the index reads as 6 ft).
"""

from __future__ import annotations

import logging

import numpy as np
import pytest

from scout.analysis.geometry import CourtConfig, classify_shot
from scout.analysis.plays import DEFAULT_RULES, PlayRules, detect_plays, link_plays, load_play_rules, summarize_plays
from scout.analysis.tracking_index import TrackingIndex
from scout.errors import ErrorCode, ScoutError
from scout.schemas import (
    EventType,
    Play,
    PlayOutcome,
    PlayType,
    Possession,
    TeamSide,
    TimelineEvent,
    TrackAssignment,
)
from tests import helpers

COURT = CourtConfig()
FPS, STEP = 30.0, 3  # helpers.video_info: 30 fps video analysed at 10 fps
PX = 20.0  # pixel scenes: 20 px per foot
SIDES = {0: TeamSide.SCOUTED, 1: TeamSide.OTHER}
ROW_TYPES = {
    "rebound": EventType.OREB, "foul": EventType.FOUL, "turnover": EventType.TURNOVER, "timeout": EventType.TIMEOUT,
}


class Scene:
    """A hand-made possession: keyframed players, ball holders and timeline rows."""

    def __init__(self, seconds: float = 10.0, *, pixel: bool = False) -> None:
        self.seconds, self.pixel = seconds, pixel
        self.keys: dict[int, tuple[int, list[tuple[float, float, float]]]] = {}
        self.spans: list[tuple[float, float, int]] = []
        self.raw: list = []
        self.rows: list[TimelineEvent] = []

    def player(self, tid: int, team: int, *keys: tuple[float, float, float]) -> Scene:
        self.keys[tid] = (team, list(keys))
        return self

    def hold(self, t0: float, t1: float, tid: int) -> Scene:
        self.spans.append((t0, t1, tid))
        return self

    def where(self, tid: int, t: float) -> tuple[float, float]:
        keys = self.keys[tid][1]
        kt, kx, ky = zip(*keys, strict=True)
        return float(np.interp(t, kt, kx)), float(np.interp(t, kt, ky))

    def shot(self, t: float, tid: int, *, made: bool = True, points: int = 2) -> Scene:
        xy = self.where(tid, t)
        team = self.keys[tid][0]
        row_type = EventType.SHOT_MADE if made else EventType.SHOT_MISSED
        eid = self._raw("shot", t, tid, team, made=made, shot_court_xy=list(xy))
        zone = classify_shot(COURT, xy, "left")[0]
        self.rows.append(
            TimelineEvent(id=f"r{len(self.rows)}", t=t, frame=round(t * FPS), type=row_type, label="shot",
                          side=SIDES[team], points=points if made else 0, court_xy=xy, zone=zone,
                          is_three=points == 3, source_event_id=eid)
        )
        return self

    def row(self, raw_type: str, t: float, tid: int | None, team: int, **attrs: object) -> Scene:
        eid = self._raw(raw_type, t, tid, team, **attrs)
        self.rows.append(TimelineEvent(id=f"r{len(self.rows)}", t=t, frame=round(t * FPS), type=ROW_TYPES[raw_type],
                                       label=raw_type, side=SIDES[team], source_event_id=eid))
        return self

    def _raw(self, raw_type: str, t: float, tid: int | None, team: int, **attrs: object) -> str:
        eid = f"e{len(self.raw)}"
        self.raw.append(helpers.event(eid, raw_type, round(t * FPS), track_id=tid, team_id=team, **attrs))
        return eid

    def build(self):
        k = PX if self.pixel else 1.0
        frames = list(range(0, int(self.seconds * FPS) + 1, STEP))
        tracks = []
        for tid, (team, _keys) in self.keys.items():
            path = [(f, self.where(tid, f / FPS)[0] * k, self.where(tid, f / FPS)[1] * k) for f in frames]
            tracks.append(helpers.track(tid, team, path, jersey=str(tid), court=not self.pixel))
        balls = []
        for f in frames:
            holder = next((tid for t0, t1, tid in self.spans if t0 <= f / FPS <= t1), None)
            x, y = self.where(holder, f / FPS) if holder is not None else (42.0, 25.0)
            balls.append((f, x * k, y * k, holder))
        return helpers.tracking(tracks, balls=helpers.ball(balls, court=not self.pixel), events=self.raw,
                                duration_s=self.seconds, homography=not self.pixel)

    def detect(self, *, start_reason: str = "made_basket", rules: PlayRules | None = None,
               possessions: list[Possession] | None = None) -> list[Play]:
        tracking = self.build()
        if possessions is None:
            end = int(self.seconds * FPS)
            possessions = [Possession(id=1, side=TeamSide.SCOUTED, start_t=0.0, end_t=self.seconds, start_frame=0,
                                      end_frame=end, start_reason=start_reason)]
        assignments = [
            TrackAssignment(track_id=t.track_id, team_id=t.team_id, side=SIDES[t.team_id], jersey=str(t.track_id))
            for t in tracking.tracks
        ]
        rows = sorted(self.rows, key=lambda r: r.frame)
        index = TrackingIndex(tracking, COURT)
        return detect_plays(index, rows, possessions, assignments, SIDES, COURT, rules or PlayRules())


def only(plays: list[Play], play_type: PlayType) -> Play:
    found = [p for p in plays if p.type == play_type]
    assert len(found) == 1, [(p.type.value, p.start_t, p.attrs) for p in plays]
    return found[0]


def types(plays: list[Play]) -> set[PlayType]:
    return {p.type for p in plays}


def toward_basket(path: list[tuple[float, float, float]], gap: float = 3.5) -> list[tuple[float, float, float]]:
    """A man defender's keyframes: ``gap`` feet from his man toward the basket."""
    bx, by = COURT.basket("left")
    out = []
    for t, x, y in path:
        d = max(np.hypot(bx - x, by - y), 1e-6)
        out.append((t, x + (bx - x) / d * gap, y + (by - y) / d * gap))
    return out


# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------


def test_missing_rules_file_gives_defaults(tmp_path):
    rules = load_play_rules(tmp_path / "missing.yaml")
    default = DEFAULT_RULES["pick_and_roll"]["screen_distance_ft"]
    assert rules.get("pick_and_roll", "screen_distance_ft", None) == default
    assert all(rules.is_enabled(name) for name in rules.enabled)
    assert "enabled" not in rules.values["pick_and_roll"]


def test_shipped_rules_file_matches_defaults(caplog):
    with caplog.at_level(logging.WARNING, logger="scout.analysis.plays"):
        rules = load_play_rules()  # settings.play_rules_config -> config/play_rules.yaml
    assert not caplog.records, "every key in config/play_rules.yaml must be a known setting"
    defaults = load_play_rules("does/not/exist.yaml")
    assert rules.values == defaults.values
    assert rules.enabled == defaults.enabled


def test_yaml_overrides_merge_over_defaults(tmp_path):
    path = tmp_path / "rules.yaml"
    path.write_text("pick_and_roll:\n  screen_distance_ft: 6\nisolation:\n  enabled: false\nnot_a_section:\n  x: 1\n")
    rules = load_play_rules(path)
    assert rules.get("pick_and_roll", "screen_distance_ft", None) == 6.0
    assert rules.get("pick_and_roll", "min_screen_s", None) == DEFAULT_RULES["pick_and_roll"]["min_screen_s"]
    assert not rules.is_enabled("isolation") and rules.is_enabled("pick_and_roll")
    assert PlayType.ISOLATION in types(isolation_scene().detect())
    assert PlayType.ISOLATION not in types(isolation_scene().detect(rules=rules))


@pytest.mark.parametrize(
    ("text", "needle"),
    [
        ("pick_and_roll: [unclosed", "could not be read"),
        ("pick_and_roll:\n  screen_distance_ft: four\n", "screen_distance_ft"),
        ("zone_defense:\n  templates:\n    '2-3': [[22, 17], [9]]\n", "zone template '2-3'"),
    ],
)
def test_bad_yaml_is_a_clear_error(tmp_path, text, needle):
    path = tmp_path / "rules.yaml"
    path.write_text(text)
    with pytest.raises(ScoutError) as exc:
        load_play_rules(path)
    assert exc.value.code == ErrorCode.CONFIG_INVALID and needle in exc.value.message


# ---------------------------------------------------------------------------
# Scenes (offense attacks the left basket)
# ---------------------------------------------------------------------------


def screen_scene(*, pop: bool = False, pixel: bool = False) -> Scene:
    """Handler at the top; #2 sets a screen on his right, then rolls to the rim (or pops to the left wing)."""
    handler = [(0, 30, 25), (4.0, 30, 25), (5.0, 22, 32), (6.0, 16, 30)]
    s = Scene(9.0, pixel=pixel).player(1, 0, *handler).player(11, 1, *toward_basket(handler, 3.0))
    if pop:
        s.player(2, 0, (0, 20, 40), (2.0, 30.5, 28.2), (3.2, 30.5, 28.2), (4.6, 24, 12), (9, 24, 12))
        s.player(12, 1, (0, 18, 37), (2.0, 28, 27), (3.2, 28, 27), (4.6, 21, 15), (9, 21, 15))
        return s.hold(0, 5.0, 1).hold(5.4, 6.0, 2).shot(6.0, 2, points=3)
    s.player(2, 0, (0, 20, 40), (2.0, 30.5, 28.2), (3.2, 30.5, 28.2), (5.5, 9, 24), (6.5, 7, 24.5), (9, 7, 24.5))
    s.player(12, 1, (0, 18, 37), (2.0, 28, 27), (3.2, 28, 27), (5.5, 11, 24), (6.5, 9, 24.5), (9, 9, 24.5))
    return s.hold(0, 6.0, 1).hold(6.4, 7.0, 2).shot(7.0, 2)


def handoff_scene(*, pixel: bool = False) -> Scene:
    """#2 holds the ball at the right slot; #3 runs past him and takes it hand to hand."""
    s = Scene(6.0, pixel=pixel)
    s.player(2, 0, (0, 25, 35), (6, 25, 35)).player(12, 1, (0, 22, 33), (6, 22, 33))
    s.player(3, 0, (0, 21, 43), (2.0, 21, 43), (3.0, 25.5, 33.4), (4.0, 17, 27), (6, 17, 27))
    s.player(13, 1, (0, 18, 40), (2.0, 18, 40), (3.0, 22, 31), (4.0, 14, 26), (6, 14, 26))
    return s.hold(0, 3.0, 2).hold(3.1, 4.1, 3).shot(4.15, 3)


def isolation_scene(*, crowded: bool = False) -> Scene:
    """#1 catches on the left wing, jab steps for ~3 s with one defender on him, then drives."""
    iso = [(0, 21, 7), (1.0, 21, 7), (1.8, 20.4, 7.9), (2.6, 21.6, 6.6), (3.4, 20.6, 7.8), (4.4, 21, 7), (5.4, 7, 20),
           (7, 7, 20)]
    top = [(0, 27, 25), (0.6, 27, 25), (1.8, 26, 38), (7, 26, 38)]
    mate = (24.0, 14.0) if crowded else (4.0, 47.0)
    s = Scene(7.0).player(1, 0, *iso).player(11, 1, *toward_basket(iso, 3.5))
    s.player(2, 0, *top).player(12, 1, *toward_basket(top, 4.0))
    s.player(3, 0, (0, *mate), (7, *mate)).player(13, 1, *toward_basket([(0, *mate), (7, *mate)], 4.0))
    return s.hold(0, 0.6, 2).hold(1.0, 5.5, 1).shot(5.5, 1)


def post_up_scene() -> Scene:
    post = [(0, 8, 32.5), (1.4, 8, 32.5), (2.6, 7.4, 30.8), (3.8, 7.0, 30.0), (6, 7.0, 30.0)]
    s = Scene(6.0).player(2, 0, (0, 21, 43), (6, 21, 43)).player(12, 1, *toward_basket([(0, 21, 43), (6, 21, 43)], 4.0))
    s.player(5, 0, *post).player(15, 1, *toward_basket(post, 2.5))
    return s.hold(0, 1.0, 2).hold(1.4, 3.8, 5).shot(3.9, 5)


def off_ball_screen_scene() -> Scene:
    """#4 screens #3's defender on the left block; #3 pops out and catches from the top."""
    screener = [(0, 14, 20), (1.0, 11, 12.5), (2.2, 11, 12.5), (3.0, 9, 18), (5, 9, 18)]
    s = Scene(5.0).player(1, 0, (0, 27, 25), (5, 27, 25)).player(11, 1, *toward_basket([(0, 27, 25), (5, 27, 25)], 3.0))
    s.player(3, 0, (0, 10, 10), (2.0, 10, 10), (2.8, 16, 10), (5, 16, 10))
    s.player(13, 1, (0, 9, 12.5), (2.0, 9, 12.5), (2.8, 13.5, 12.5), (5, 13.5, 12.5))
    s.player(4, 0, *screener).player(14, 1, *toward_basket(screener, 3.0))
    return s.hold(0, 2.6, 1).hold(3.0, 3.5, 3).shot(3.6, 3)


def spot_up_scene() -> Scene:
    drive = [(0, 27, 25), (1.5, 13, 24), (4, 13, 24)]
    s = Scene(4.0).player(1, 0, *drive).player(11, 1, *toward_basket(drive, 3.0))
    s.player(3, 0, (0, 3.5, 47), (4, 3.5, 47)).player(13, 1, (0, 6, 41), (2.0, 6, 41), (2.4, 5, 44), (4, 5, 44))
    return s.hold(0, 1.5, 1).hold(2.0, 2.6, 3).shot(2.6, 3, points=3)


def cut_scene() -> Scene:
    s = Scene(4.0).player(1, 0, (0, 27, 25), (4, 27, 25)).player(11, 1, *toward_basket([(0, 27, 25), (4, 27, 25)], 3.0))
    s.player(3, 0, (0, 22, 6), (0.8, 22, 6), (2.2, 8, 24), (2.6, 7, 24.5), (4, 7, 24.5))
    s.player(13, 1, (0, 19, 9), (0.8, 19, 9), (2.4, 10, 22), (4, 10, 22))
    return s.hold(0, 1.8, 1).hold(2.2, 2.6, 3).shot(2.65, 3)


def putback_scene() -> Scene:
    s = Scene(6.0).player(2, 0, (0, 21, 7), (6, 21, 7)).player(12, 1, *toward_basket([(0, 21, 7), (6, 21, 7)], 3.5))
    s.player(5, 0, (0, 8, 32.5), (3.4, 6, 27.5), (4.6, 5.6, 26.4), (6, 5.6, 26.4))
    s.player(15, 1, (0, 6, 31), (3.4, 4.5, 29), (6, 4.5, 29))
    s.hold(0, 2.0, 2).shot(2.0, 2, made=False, points=3)
    return s.row("rebound", 3.7, 5, 0, offensive=True).hold(3.7, 4.6, 5).shot(4.6, 5)


def fast_break_scene(*, stoppage: str | None = None) -> Scene:
    """Rebound at the far end; #1 pushes up the middle with two wings, one defender gets back."""
    s = Scene(6.0)
    s.player(1, 0, (0, 70, 30), (2.5, 42, 25), (4.0, 15, 25), (5.0, 7, 24), (6, 7, 24))
    s.player(2, 0, (0, 68, 8), (2.3, 38, 7), (4.5, 10, 7), (6, 10, 7))
    s.player(3, 0, (0, 68, 42), (2.3, 38, 43), (4.5, 10, 43), (6, 10, 43))
    s.player(4, 0, (0, 78, 25), (6, 50, 25))
    s.player(11, 1, (0, 50, 25), (2.5, 28, 22), (5, 8, 25), (6, 8, 25))
    s.player(12, 1, (0, 60, 10), (6, 40, 12)).player(13, 1, (0, 62, 40), (6, 42, 38))
    s.hold(0, 5.0, 1).shot(5.1, 1)
    if stoppage == "timeout":
        s.row("timeout", 2.0, None, 0)
    if stoppage == "foul":
        s.row("foul", 2.0, 12, 1, kind="personal")
    return s


ATTACK = {  # five attackers moving between spots for 12 s
    1: [(0, 27, 25), (3, 24, 32), (6, 27, 25), (9, 24, 18), (12, 27, 25)],
    2: [(0, 21, 7), (3, 12, 4), (6, 21, 7), (9, 14, 10), (12, 21, 7)],
    3: [(0, 21, 43), (3, 12, 46), (6, 21, 43), (9, 14, 40), (12, 21, 43)],
    4: [(0, 8, 17.5), (3, 8, 32.5), (6, 8, 17.5), (9, 8, 32.5), (12, 8, 17.5)],
    5: [(0, 3.5, 47), (3, 14, 40), (6, 3.5, 47), (9, 14, 40), (12, 3.5, 47)],
}
TWO_THREE = [(22.0, 17.0), (22.0, 33.0), (9.0, 9.0), (9.0, 41.0), (6.0, 25.0)]


def defense_scene(kind: str) -> Scene:
    s = Scene(12.0)
    for tid, path in ATTACK.items():
        s.player(tid, 0, *path)
        if kind == "man":
            s.player(10 + tid, 1, *toward_basket(path, 3.5))
        else:
            x, y = TWO_THREE[tid - 1]
            s.player(10 + tid, 1, (0, x, y), (4, x + 0.8, y + 1.0), (8, x - 0.8, y - 1.0), (12, x, y))
    return s.hold(0, 12.0, 1)


def press_scene(*, trap: bool = False) -> Scene:
    """Inbound after a made basket; defenders pick up the guard (and the inbounder) in the backcourt."""
    pg = [(0, 76, 30), (2.4, 74, 27), (5.0, 66, 25), (9.0, 44, 25), (10.5, 35, 25), (11, 35, 25)]
    inbounder = [(0, 84.8, 15), (2.0, 84.8, 15), (3.0, 79, 10), (8.0, 60, 10), (11, 50, 10)]
    s = Scene(11.0).player(1, 0, *pg).player(11, 1, *[(t, x - 3.0, y) for t, x, y in pg]).player(5, 0, *inbounder)
    if trap:  # second defender doubles the ball handler instead of guarding the inbounder
        s.player(15, 1, (0, 80, 20), (2.4, 72, 31), *[(t, x - 2.0, y + 3.2) for t, x, y in pg[2:]])
    else:
        s.player(15, 1, *[(t, x - 3.0, y) for t, x, y in inbounder])
    for tid, spot in {2: (21.0, 7.0), 3: (21.0, 43.0), 4: (8.0, 17.5)}.items():
        s.player(tid, 0, (0, *spot), (11, *spot)).player(10 + tid, 1, *toward_basket([(0, *spot), (11, *spot)], 3.5))
    return s.hold(1.0, 2.0, 5).hold(2.4, 10.5, 1)


# ---------------------------------------------------------------------------
# Detector tests
# ---------------------------------------------------------------------------


def test_pick_and_roll():
    plays = screen_scene().detect()
    play = only(plays, PlayType.PICK_AND_ROLL)
    assert PlayType.PICK_AND_POP not in types(plays)
    assert play.category == "offense" and play.side == TeamSide.SCOUTED and play.possession_id == 1
    assert play.players["ball_handler"].label == "#1" and play.players["screener"].label == "#2"
    assert play.attrs["roll_or_pop"] == "roll"
    assert play.attrs["screen_side"] == "right" and play.attrs["handler_direction"] == "right"
    assert play.outcome == PlayOutcome.MADE_FG and play.points == 2
    assert play.start_t < 2.0 < 7.0 <= play.end_t
    assert play.confidence == pytest.approx(DEFAULT_RULES["pick_and_roll"]["confidence"])
    assert play.id == "pl_1" and "Pick & Roll" in play.description


def test_pick_and_pop_wins_over_the_spot_up_it_creates():
    plays = screen_scene(pop=True).detect()
    play = only(plays, PlayType.PICK_AND_POP)
    assert play.attrs["roll_or_pop"] == "pop"
    assert play.outcome == PlayOutcome.MADE_FG and play.points == 3
    assert PlayType.SPOT_UP not in types(plays) and play.attrs["also"] == ["spot_up"]


def test_handoff_is_not_mistaken_for_a_screen():
    plays = handoff_scene().detect()
    play = only(plays, PlayType.HANDOFF)
    assert play.players["ball_handler"].label == "#3" and play.players["passer"].label == "#2"
    assert play.outcome == PlayOutcome.MADE_FG
    assert not types(plays) & {PlayType.PICK_AND_ROLL, PlayType.PICK_AND_POP}


def test_isolation_needs_spacing():
    play = only(isolation_scene().detect(), PlayType.ISOLATION)
    assert play.players["ball_handler"].label == "#1" and play.players["defender"].label == "#11"
    assert play.attrs["finish"] == "drive" and play.attrs["location"] == "left"
    assert play.outcome == PlayOutcome.MADE_FG and play.points == 2
    assert PlayType.ISOLATION not in types(isolation_scene(crowded=True).detect())


def test_post_up():
    play = only(post_up_scene().detect(), PlayType.POST_UP)
    assert play.players["post_player"].label == "#5" and play.players["passer"].label == "#2"
    assert play.players["defender"].label == "#15" and play.attrs["block"] == "right"
    assert play.outcome == PlayOutcome.MADE_FG


def test_off_ball_screen():
    plays = off_ball_screen_scene().detect()
    play = only(plays, PlayType.OFF_BALL_SCREEN)
    roles = {role: ref.label for role, ref in play.players.items()}
    assert roles == {"screener": "#4", "receiver": "#3", "passer": "#1"}
    assert play.attrs["also"] == ["spot_up"] and PlayType.SPOT_UP not in types(plays)


def test_spot_up():
    play = only(spot_up_scene().detect(), PlayType.SPOT_UP)
    assert play.players["shooter"].label == "#3" and play.players["passer"].label == "#1"
    assert play.outcome == PlayOutcome.MADE_FG and play.points == 3 and play.attrs["zone"] == "three"


def test_cut():
    play = only(cut_scene().detect(), PlayType.CUT)
    assert play.players["cutter"].label == "#3" and play.attrs["speed_fts"] > 10
    assert play.outcome == PlayOutcome.MADE_FG


def test_putback():
    plays = putback_scene().detect()
    play = only(plays, PlayType.PUTBACK)
    assert play.players["shooter"].label == "#5" and play.outcome == PlayOutcome.MADE_FG and play.points == 2
    assert PlayType.SPOT_UP not in types(plays)


def test_fast_break_numbers():
    play = only(fast_break_scene().detect(start_reason="def_rebound"), PlayType.FAST_BREAK)
    assert play.attrs["numbers"] == "3v1" and play.attrs["start"] == "def_rebound"
    assert play.players["ball_handler"].label == "#1" and play.players["shooter"].label == "#1"
    assert play.outcome == PlayOutcome.MADE_FG and play.end_t == pytest.approx(5.1, abs=0.05)


@pytest.mark.parametrize("stoppage", ["timeout", "foul"])
def test_no_fast_break_after_a_stoppage_or_dead_ball(stoppage):
    assert PlayType.FAST_BREAK not in types(fast_break_scene(stoppage=stoppage).detect(start_reason="def_rebound"))
    assert PlayType.FAST_BREAK not in types(fast_break_scene().detect(start_reason="made_basket"))


def test_man_and_zone_defense():
    man = only(defense_scene("man").detect(), PlayType.MAN_DEFENSE)
    assert man.category == "defense" and man.side == TeamSide.OTHER and man.attrs["follow_score"] >= 0.5
    zone = only(defense_scene("zone").detect(), PlayType.ZONE_DEFENSE)
    assert zone.side == TeamSide.OTHER and zone.attrs["zone_shape"] == "2-3"
    assert PlayType.MAN_DEFENSE not in types(defense_scene("zone").detect())


@pytest.mark.parametrize(("trap", "press_type"), [(False, "man"), (True, "zone")])
def test_full_court_press(trap, press_type):
    play = only(press_scene(trap=trap).detect(start_reason="made_basket"), PlayType.PRESS)
    assert play.category == "defense" and play.side == TeamSide.OTHER and play.attrs["press_type"] == press_type
    assert PlayType.PRESS not in types(press_scene(trap=trap).detect(start_reason="def_rebound"))


def test_pixel_mode_lowers_confidence_and_skips_basket_rules():
    play = only(handoff_scene(pixel=True).detect(), PlayType.HANDOFF)
    factor = DEFAULT_RULES["general"]["pixel_confidence_factor"]
    assert play.confidence == pytest.approx(DEFAULT_RULES["handoff"]["confidence"] * factor)
    assert "location" not in play.attrs  # needs the court mapping
    assert not types(screen_scene(pixel=True).detect()) & {PlayType.PICK_AND_ROLL, PlayType.PICK_AND_POP}


def test_disabled_detectors_and_missing_possessions():
    rules = PlayRules(enabled={"handoff": False})
    assert PlayType.HANDOFF not in types(handoff_scene().detect(rules=rules))
    play = only(handoff_scene().detect(possessions=[]), PlayType.HANDOFF)  # falls back to ball-holder runs
    assert play.possession_id is None


# ---------------------------------------------------------------------------
# Linking and summaries
# ---------------------------------------------------------------------------


def _play(pid: str, play_type: PlayType, side: TeamSide, poss: int | None, start: float, end: float,
          outcome: PlayOutcome = PlayOutcome.NO_SHOT, points: int = 0) -> Play:
    category = "defense" if play_type in (PlayType.MAN_DEFENSE, PlayType.ZONE_DEFENSE, PlayType.PRESS) else "offense"
    return Play(id=pid, type=play_type, category=category, side=side, start_t=start, end_t=end,
                start_frame=int(start * FPS), end_frame=int(end * FPS), possession_id=poss, outcome=outcome,
                points=points)


def _possession(pid: int, side: TeamSide, start: float, end: float, points: int = 0) -> Possession:
    return Possession(id=pid, side=side, start_t=start, end_t=end, start_frame=int(start * FPS),
                      end_frame=int(end * FPS), points=points)


def test_link_and_summarize():
    scouted, other = TeamSide.SCOUTED, TeamSide.OTHER
    possessions = [_possession(1, scouted, 0, 10, 2), _possession(2, other, 10, 20), _possession(3, scouted, 20, 30)]
    plays = [
        _play("pl_1", PlayType.ZONE_DEFENSE, other, 1, 1, 8, PlayOutcome.MADE_FG, 2),
        _play("pl_2", PlayType.PICK_AND_ROLL, scouted, 1, 2, 6, PlayOutcome.MADE_FG, 2),
        _play("pl_3", PlayType.MAN_DEFENSE, scouted, 2, 11, 18, PlayOutcome.MISSED_FG, 0),
        _play("pl_4", PlayType.SPOT_UP, scouted, 3, 22, 25, PlayOutcome.MISSED_FG),
        _play("pl_5", PlayType.PICK_AND_ROLL, scouted, 3, 26, 29, PlayOutcome.TURNOVER),
    ]

    def ev(eid: str, t: float, poss: int, side: TeamSide) -> TimelineEvent:
        return TimelineEvent(id=eid, t=t, frame=int(t * FPS), type=EventType.PASS, label="Pass", side=side,
                             possession_side=side, possession_id=poss, play_id="stale")

    timeline = [ev("a", 1.0, 1, scouted), ev("b", 5.5, 1, scouted), ev("c", 12.0, 2, other), ev("d", 24.0, 3, scouted),
                ev("e", 28.0, 3, scouted)]
    link_plays(timeline, possessions, plays)
    assert [e.play_id for e in timeline] == [None, "pl_2", None, "pl_4", "pl_5"]
    assert [p.play_ids for p in possessions] == [["pl_1", "pl_2"], ["pl_3"], ["pl_4", "pl_5"]]

    summary = {(s.side, s.type): s for s in summarize_plays(plays, possessions)}
    pnr = summary[(scouted, PlayType.PICK_AND_ROLL)]
    assert (pnr.count, pnr.possessions_pct, pnr.points, pnr.ppp) == (2, 1.0, 2, 1.0)
    assert (pnr.fgm, pnr.fga, pnr.turnovers) == (1, 1, 1)
    spot = summary[(scouted, PlayType.SPOT_UP)]
    assert (spot.count, spot.possessions_pct, spot.ppp, spot.fga) == (1, 0.5, 0.0, 1)
    zone = summary[(other, PlayType.ZONE_DEFENSE)]  # share of OTHER's defensive possessions (= scouted's 2)
    assert (zone.category, zone.possessions_pct, zone.points, zone.ppp) == ("defense", 0.5, 2, 2.0)
    man = summary[(scouted, PlayType.MAN_DEFENSE)]
    assert (man.possessions_pct, man.ppp) == (1.0, 0.0)
    order = [(s.side, s.category) for s in summarize_plays(plays, possessions)]
    assert order == sorted(order, key=lambda o: (o[0] != scouted, o[1] != "offense"))
