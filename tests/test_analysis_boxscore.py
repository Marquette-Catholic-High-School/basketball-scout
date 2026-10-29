"""Timeline rows -> box score lines, team totals, minutes and plus-minus."""

from __future__ import annotations

import pytest

from scout.analysis.boxscore import build_box_scores
from scout.analysis.geometry import CourtConfig
from scout.analysis.tracking_index import TrackingIndex
from scout.schemas import (
    EventType,
    PlayerRef,
    Possession,
    Roster,
    RosterPlayer,
    ShotZone,
    TeamSide,
    TimelineEvent,
    TrackAssignment,
)
from tests import helpers

S, O = TeamSide.SCOUTED, TeamSide.OTHER
NAMES = {S: "Central", O: "North"}


def _rosters() -> dict[TeamSide, Roster]:
    players = [
        RosterPlayer(id="p23", jersey="23", first_name="Sam", last_name="Smith"),
        RosterPlayer(id="p5", jersey="5", first_name="Jo", last_name="Jones"),
        RosterPlayer(id="p00", jersey="00", last_name="Zero"),
        RosterPlayer(id="p0", jersey="0", last_name="Oh"),
    ]
    return {S: Roster(game_id="g", side=S, players=players), O: Roster(game_id="g", side=O)}


SMITH = PlayerRef(player_id="p23", jersey="23", name="Sam Smith", side=S)
JONES = PlayerRef(player_id="p5", jersey="5", name="Jo Jones", side=S)
NO14 = PlayerRef(jersey="14", side=S)
NO3 = PlayerRef(jersey="3", side=O)

_seq = iter(range(10_000))


def row(type_, side, player=None, *, frame=0, points=0, is_three=None, zone=None) -> TimelineEvent:
    return TimelineEvent(id=f"r{next(_seq)}", t=frame / 30, frame=frame, type=type_, label="x", side=side,
                         player=player, points=points, is_three=is_three, zone=zone)


def _box(boxes, side):
    return next(b for b in boxes if b.side == side)


def _line(box, jersey):
    return next(line for line in box.players if line.player.jersey == jersey)


def test_stat_attribution_lines_and_totals():
    timeline = [
        row(EventType.SHOT_MADE, S, SMITH, points=3, is_three=True, zone=ShotZone.THREE),
        row(EventType.SHOT_MISSED, S, SMITH, is_three=False, zone=ShotZone.MID),
        row(EventType.SHOT_MADE, S, JONES, points=2, is_three=False, zone=ShotZone.PAINT),
        row(EventType.ASSIST, S, SMITH),
        row(EventType.FT_MADE, S, SMITH, points=1),
        row(EventType.FT_MISSED, S, SMITH),
        row(EventType.OREB, S, JONES),
        row(EventType.DREB, S, NO14),
        row(EventType.STEAL, S, NO14),
        row(EventType.BLOCK, S, JONES),
        row(EventType.TURNOVER, S, SMITH),
        row(EventType.FOUL, S, JONES),
        row(EventType.SHOT_MADE, S, None, points=2, is_three=False, zone=ShotZone.UNKNOWN),  # unknown shooter
        row(EventType.DREB, S, None),
        row(EventType.SHOT_MADE, O, NO3, points=3, is_three=True, zone=ShotZone.THREE),
        row(EventType.PASS, S, SMITH),  # not a box-score stat
        row(EventType.POSSESSION_CHANGE, S),
    ]
    boxes = build_box_scores(timeline, [], [], _rosters(), NAMES)
    assert [b.side for b in boxes] == [S, O]
    scouted = _box(boxes, S)
    assert scouted.team_name == "Central"
    smith = _line(scouted, "23")
    assert (smith.pts, smith.fgm, smith.fga, smith.tpm, smith.tpa, smith.ftm, smith.fta) == (4, 1, 2, 1, 1, 1, 2)
    assert (smith.ast, smith.tov, smith.zones.three.made, smith.zones.mid.attempts) == (1, 1, 1, 1)
    jones = _line(scouted, "5")
    assert (jones.pts, jones.oreb, jones.blk, jones.pf, jones.zones.paint.made) == (2, 1, 1, 1, 1)
    no14 = _line(scouted, "14")
    assert no14.player.player_id is None and (no14.dreb, no14.stl, no14.reb) == (1, 1, 1)
    team = scouted.team_unattributed
    assert (team.pts, team.fgm, team.dreb, team.zones.unknown.made, team.player.label) == (2, 1, 1, 1, "Team")
    totals = scouted.totals
    assert (totals.pts, totals.fga, totals.fgm, totals.dreb, totals.reb, totals.tov) == (8, 4, 3, 2, 3, 1)
    assert totals.zones.paint.made == 1 and totals.zones.unknown.attempts == 1
    other = _box(boxes, O)
    assert other.team_name == "North" and other.totals.pts == 3 and _line(other, "3").tpm == 1
    # Without a tracking index nothing is known about presence.
    assert smith.minutes_est is None and smith.plus_minus is None


def test_player_order_roster_then_unrostered_by_jersey():
    timeline = [row(EventType.FOUL, S, PlayerRef(jersey=j, side=S)) for j in ("33", "4")]
    scouted = _box(build_box_scores(timeline, [], [], _rosters(), NAMES), S)
    assert [line.player.jersey for line in scouted.players] == ["0", "00", "5", "23", "4", "33"]
    zero_line = scouted.players[0]
    assert zero_line.pts == 0 and zero_line.player.name == "Oh"


def test_possessions_and_points_per_possession():
    timeline = [row(EventType.SHOT_MADE, S, SMITH, points=2, is_three=False, zone=ShotZone.PAINT)]
    possessions = [
        Possession(id=1, side=S, start_t=0, end_t=5, start_frame=0, end_frame=150, points=2),
        Possession(id=2, side=O, start_t=5, end_t=9, start_frame=150, end_frame=270),
        Possession(id=3, side=S, start_t=9, end_t=20, start_frame=270, end_frame=600),
    ]
    boxes = build_box_scores(timeline, possessions, [], _rosters(), NAMES)
    assert (_box(boxes, S).possessions, _box(boxes, S).points_per_possession) == (2, 1.0)
    assert (_box(boxes, O).possessions, _box(boxes, O).points_per_possession) == (1, 0.0)
    assert build_box_scores([], [], [], _rosters(), NAMES)[0].points_per_possession is None


def _assignment(track_id, side, player_id=None, jersey=None, **kw):
    return TrackAssignment(track_id=track_id, side=side, player_id=player_id, jersey=jersey,
                           method="exact" if player_id else "unrostered", **kw)


def test_minutes_and_plus_minus_from_presence():
    def path(start_s, end_s, step=3):
        return [(f, 10.0, 10.0) for f in range(int(start_s * 30), int(end_s * 30), step)]

    tracks = [
        helpers.track(1, 0, path(0, 60)),  # Smith: first minute
        helpers.track(2, 0, path(0, 30)),  # Jones, two separate tracks
        helpers.track(4, 0, path(90, 120, step=6)),  # thinned samples still count fully
        helpers.track(5, 0, path(10, 50)),  # Smith again, overlapping track 1: no double count
        helpers.track(6, 0, path(0, 20) + path(40, 60)),  # #14: a 20-second gap is not presence
        helpers.track(7, 0, path(0, 60)),  # ignored track (a coach on the sideline)
    ]
    index = TrackingIndex(helpers.tracking(tracks), CourtConfig())
    assignments = [
        _assignment(1, S, "p23"), _assignment(2, S, "p5"), _assignment(4, S, "p5"), _assignment(5, S, "p23"),
        _assignment(6, S, jersey="14"), _assignment(7, S, "p0", ignored=True),
    ]
    timeline = [
        row(EventType.SHOT_MADE, S, SMITH, frame=300, points=3, is_three=True, zone=ShotZone.THREE),  # both on
        row(EventType.SHOT_MADE, O, NO3, frame=1200, points=2, is_three=False, zone=ShotZone.PAINT),  # Smith only
        row(EventType.FT_MADE, S, JONES, frame=3000, points=1),  # Jones only (track 4)
        row(EventType.FOUL, S, NO14, frame=100),
    ]
    scouted = _box(build_box_scores(timeline, [], assignments, _rosters(), NAMES, index=index), S)
    smith, jones, no14 = _line(scouted, "23"), _line(scouted, "5"), _line(scouted, "14")
    assert smith.minutes_est == pytest.approx(1.0) and smith.plus_minus == 1
    assert jones.minutes_est == pytest.approx(1.0) and jones.plus_minus == 4
    assert no14.minutes_est == pytest.approx(0.7) and no14.plus_minus == 1  # 40 s on the floor, not 60
    never_seen = _line(scouted, "0")  # only an ignored track
    assert never_seen.minutes_est == 0.0 and never_seen.plus_minus is None
    assert scouted.team_unattributed.minutes_est is None


def test_minutes_capped_at_video_duration():
    tracks = [helpers.track(1, 0, [(f, 10.0, 10.0) for f in range(0, 3600 * 2, 3)])]  # 4 min of samples
    tracking = helpers.tracking(tracks, duration_s=120.0)
    index = TrackingIndex(tracking, CourtConfig())
    scouted = _box(build_box_scores([], [], [_assignment(1, S, "p23")], _rosters(), NAMES, index=index), S)
    assert _line(scouted, "23").minutes_est == 2.0
