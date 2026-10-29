"""Tests for the FastScout exports: paste block, warnings, team helper block,
custom-table CSV, timeline CSV and the YAML column mapping.

``make_analysis`` / ``make_roster`` build a small hand-made GameAnalysis (no other
engineer's module is involved); tests/test_reporting.py reuses them.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

import pytest
import yaml

from scout import db
from scout.errors import ErrorCode, ScoutError
from scout.export import fastscout
from scout.schemas import (
    BoxScoreLine,
    DataQuality,
    EventType,
    GameAnalysis,
    PipelineInfo,
    PipelineWarning,
    Play,
    PlayerRef,
    PlayOutcome,
    PlayType,
    PlayTypeSummary,
    Possession,
    Roster,
    RosterPlayer,
    ShootingSplit,
    ShotRecord,
    ShotZone,
    TeamBoxScore,
    TeamSide,
    TeamSummary,
    TimelineEvent,
    ZoneSplits,
)
from tests import helpers

S, O = TeamSide.SCOUTED, TeamSide.OTHER
DEFENSE_TYPES = (PlayType.ZONE_DEFENSE, PlayType.MAN_DEFENSE, PlayType.PRESS)

# ---------------------------------------------------------------------------
# Sample game
# ---------------------------------------------------------------------------


def _zones(paint=(0, 0), mid=(0, 0), three=(0, 0), unknown=(0, 0)) -> ZoneSplits:
    def split(pair: tuple[int, int]) -> ShootingSplit:
        return ShootingSplit(made=pair[0], attempts=pair[1])

    return ZoneSplits(paint=split(paint), mid=split(mid), three=split(three), unknown=split(unknown))


def _ref(jersey: str, name: str | None = None, player_id: str | None = None, side: TeamSide = S) -> PlayerRef:
    confidence = 0.9 if player_id else 0.0
    return PlayerRef(player_id=player_id, jersey=jersey, name=name, side=side, match_confidence=confidence)


JR = _ref("3", "J.R. Smith", "p_jr")
JOSE = _ref("10", "José Núñez", "p_jose")
BEN = _ref("5", "Ben Bench", "p_ben")
TY = _ref("0", "Ty Allen", "p_ty")
UNKNOWN_23 = _ref("23")
RIVAL_4 = _ref("4", "Sam Rival", "p_rival", side=O)


def make_roster(game_id: str) -> Roster:
    return Roster(
        game_id=game_id,
        side=S,
        team_name="Opponent HS",
        players=[
            RosterPlayer(
                id="p_jr", jersey="3", first_name="J.R.", last_name="Smith", position="G", height="6-1", grade="Sr"
            ),
            RosterPlayer(
                id="p_jose", jersey="10", first_name="José", last_name="Núñez", position="F",
                fastscout_name="Joey Nunez",
            ),  # fmt: skip
            RosterPlayer(id="p_ben", jersey="5", first_name="Ben", last_name="Bench"),
            RosterPlayer(id="p_ty", jersey="0", first_name="Ty", last_name="Allen", position="G"),
        ],
    )


def _scouted_box() -> TeamBoxScore:
    jr = BoxScoreLine(
        player=JR, minutes_est=22.4, pts=12, fgm=5, fga=11, tpm=2, tpa=5,
        oreb=1, dreb=3, ast=4, stl=2, tov=3, pf=2, zones=_zones(paint=(2, 4), mid=(1, 2), three=(2, 5)),
    )  # fmt: skip
    jose = BoxScoreLine(
        player=JOSE, minutes_est=30.5, pts=9, fgm=3, fga=8, tpm=1, tpa=3, ftm=2, fta=2,
        dreb=5, ast=1, blk=1, tov=1, pf=3, zones=_zones(paint=(1, 2), mid=(1, 3), three=(1, 3)),
    )  # fmt: skip
    unknown = BoxScoreLine(
        player=UNKNOWN_23, minutes_est=12.0, pts=4, fgm=2, fga=3, oreb=2, dreb=1, pf=1, zones=_zones(paint=(2, 3))
    )
    players = [
        BoxScoreLine(player=BEN, minutes_est=0.6),  # did not play: skipped
        jr,
        jose,
        unknown,
        BoxScoreLine(player=TY, minutes_est=None, pf=1),  # played (a foul) but minutes unknown
    ]
    unattributed = BoxScoreLine(
        player=PlayerRef(side=S), pts=2, fgm=1, fga=2, dreb=1, zones=_zones(mid=(0, 1), unknown=(1, 1))
    )
    totals = BoxScoreLine(
        player=PlayerRef(name="Team", side=S), minutes_est=160.0, pts=27, fgm=11, fga=24, tpm=3, tpa=8,
        ftm=2, fta=2, oreb=3, dreb=10, ast=5, stl=2, blk=1, tov=4, pf=7,
        zones=_zones(paint=(5, 9), mid=(2, 6), three=(3, 8), unknown=(1, 1)),
    )  # fmt: skip
    return TeamBoxScore(
        side=S, team_name="Opponent HS", players=players, team_unattributed=unattributed, totals=totals,
        possessions=31, points_per_possession=0.8710,
    )  # fmt: skip


def _other_box() -> TeamBoxScore:
    line = BoxScoreLine(player=RIVAL_4, minutes_est=30.0, pts=20, fgm=8, fga=20, ftm=4, fta=6, tov=3, stl=1, dreb=6)
    totals = line.model_copy(update={"player": PlayerRef(name="Team", side=O)})
    return TeamBoxScore(
        side=O, team_name="Rival HS", players=[line], team_unattributed=BoxScoreLine(player=PlayerRef(side=O)),
        totals=totals, possessions=30, points_per_possession=0.6667,
    )  # fmt: skip


def _event(eid: str, t: float, type_: EventType, label: str, side: TeamSide | None = None, **kw: Any) -> TimelineEvent:
    return TimelineEvent(id=eid, t=t, frame=int(t * 30), type=type_, label=label, side=side, possession_side=side, **kw)


def _timeline() -> list[TimelineEvent]:
    def score(scouted: int, other: int) -> dict[str, int]:
        return {"score_scouted": scouted, "score_other": other}

    return [
        _event("e1", 5.0, EventType.PERIOD_START, "Start of Period 1"),
        _event("e2", 12.0, EventType.STEAL, "Steal", S, player=JR, secondary_player=RIVAL_4, possession_id=1),
        _event(
            "e3", 16.0, EventType.SHOT_MADE, "3PT Make", S, player=JR, possession_id=1, points=3, is_three=True,
            zone=ShotZone.THREE, subzone="left_corner_3", court_xy=(2.0, 3.0), confidence=0.9, play_id="pl_1",
            description="Corner three by #3", **score(3, 0),
        ),
        _event(
            "e4", 40.0, EventType.SHOT_MADE, "2PT Make", O, player=RIVAL_4, possession_id=2, points=2,
            zone=ShotZone.PAINT, **score(3, 2),
        ),
        _event(
            "e5", 70.0, EventType.SHOT_MADE, "2PT Make", S, player=UNKNOWN_23, possession_id=3, points=2,
            zone=ShotZone.PAINT, subzone="restricted_area", play_id="pl_2",
            description='=HYPERLINK("http://x") said "go", scored', **score(5, 2),
        ),
        _event(
            "e6", 95.0, EventType.TURNOVER, "Turnover (Bad Pass)", O, player=RIVAL_4, possession_id=4, **score(5, 2)
        ),
        _event(
            "e7", 120.0, EventType.SHOT_MISSED, "2PT Miss", S, player=JR, possession_id=5, zone=ShotZone.MID,
            subzone="top_mid", **score(5, 2),
        ),
        _event("e8", 122.0, EventType.OREB, "Off. Rebound", S, player=UNKNOWN_23, possession_id=5, **score(5, 2)),
        _event(
            "e9", 124.0, EventType.SHOT_MADE, "2PT Make", S, player=UNKNOWN_23, possession_id=5, points=2,
            zone=ShotZone.PAINT, subzone="restricted_area", **score(7, 2),
        ),
        _event(
            "e10", 130.0, EventType.FT_MADE, "FT Make", S, player=UNKNOWN_23, possession_id=5, points=1, **score(8, 2)
        ),
        _event("e11", 140.0, EventType.SHOT_MISSED, "2PT Miss", O, player=RIVAL_4, possession_id=6, **score(8, 2)),
        _event("e12", 142.0, EventType.DREB, "Def. Rebound", S, player=JOSE, possession_id=6, **score(8, 2)),
        _event(
            "e13", 150.0, EventType.SHOT_MADE, "3PT Make", S, player=JOSE, possession_id=7, points=3, is_three=True,
            zone=ShotZone.THREE, subzone="top_3", **score(11, 2),
        ),
        _event("e14", 180.0, EventType.TURNOVER, "Turnover (Travel)", S, player=JOSE, possession_id=8, **score(11, 2)),
    ]  # fmt: skip


def _possession(
    pid: int, side: TeamSide, start: float, end: float, reason: str, points: int = 0, **kw: Any
) -> Possession:
    return Possession(
        id=pid, side=side, start_t=start, end_t=end, start_frame=int(start * 30), end_frame=int(end * 30),
        start_reason=reason, points=points, **kw,
    )  # fmt: skip


def _play(pid: str, type_: PlayType, side: TeamSide, start: float, end: float, **kw: Any) -> Play:
    category = "defense" if type_ in DEFENSE_TYPES else "offense"
    return Play(
        id=pid, type=type_, category=category, side=side, start_t=start, end_t=end,
        start_frame=int(start * 30), end_frame=int(end * 30), **kw,
    )  # fmt: skip


def _summary(type_: PlayType, side: TeamSide, count: int, pct: float, points: int, ppp: float, fg: str, tov: int):
    fgm, fga = (int(n) for n in fg.split("-"))
    return PlayTypeSummary(
        type=type_, category="defense" if type_ in DEFENSE_TYPES else "offense", side=side, count=count,
        possessions_pct=pct, points=points, ppp=ppp, fgm=fgm, fga=fga, turnovers=tov,
    )  # fmt: skip


def _shot(eid: str, t: float, side: TeamSide, player: PlayerRef, made: bool, points: int, zone: ShotZone, sub: str):
    return ShotRecord(
        event_id=eid, t=t, side=side, player=player, made=made, points=points if made else 0, zone=zone, subzone=sub
    )


def make_analysis(game_id: str = "g_test") -> GameAnalysis:
    return GameAnalysis(
        game_id=game_id,
        generated_at=datetime(2026, 10, 1, 12, 0, tzinfo=UTC),
        video=helpers.video_info(duration_s=1920.0),
        pipeline=PipelineInfo(name="openhoopvision", version="1.2"),
        teams=[
            TeamSummary(side=S, name="Opponent HS", team_id=0, color_name="navy", score=27),
            TeamSummary(side=O, name="Rival HS", team_id=1, color_name="white", score=20),
        ],
        timeline=_timeline(),
        possessions=[
            _possession(1, S, 12, 30, "steal", 3, transition=True, play_ids=["pl_1"]),
            _possession(2, O, 30, 60, "made_basket", 2),
            _possession(3, S, 60, 90, "made_basket", 2, play_ids=["pl_2"]),
            _possession(4, O, 90, 100, "made_basket", 0),
            _possession(5, S, 100, 135, "turnover", 3, play_ids=["pl_6"]),
            _possession(6, O, 135, 145, "made_basket", 0),
            _possession(7, S, 145, 155, "def_rebound", 3),
            _possession(8, S, 170, 180, "def_rebound", 0),
        ],
        plays=[
            _play(
                "pl_1", PlayType.FAST_BREAK, S, 12, 16, possession_id=1, points=3, outcome=PlayOutcome.MADE_FG,
                players={"ball_handler": JR}, attrs={"numbers": "3v2"},
            ),
            _play("pl_3", PlayType.ZONE_DEFENSE, S, 30, 60, possession_id=2, attrs={"zone_shape": "2-3"}),
            _play(
                "pl_2", PlayType.FAST_BREAK, S, 60, 70, possession_id=3, points=2, outcome=PlayOutcome.MADE_FG,
                players={"ball_handler": JOSE, "shooter": UNKNOWN_23},
            ),
            _play("pl_4", PlayType.ZONE_DEFENSE, S, 90, 100, possession_id=4, attrs={"zone_shape": "2-3"}),
            _play(
                "pl_6", PlayType.PICK_AND_ROLL, S, 100, 124, possession_id=5, points=3, outcome=PlayOutcome.MADE_FG,
                players={"ball_handler": JR, "screener": UNKNOWN_23},
            ),
            _play("pl_5", PlayType.ZONE_DEFENSE, S, 135, 145, possession_id=6, attrs={"zone_shape": "1-3-1"}),
            _play("pl_7", PlayType.ISOLATION, O, 30, 40, possession_id=2, points=2, players={"ball_handler": RIVAL_4}),
        ],  # fmt: skip
        shots=[
            _shot("e3", 16.0, S, JR, True, 3, ShotZone.THREE, "left_corner_3"),
            _shot("e4", 40.0, O, RIVAL_4, True, 2, ShotZone.PAINT, "paint"),
            _shot("e5", 70.0, S, UNKNOWN_23, True, 2, ShotZone.PAINT, "restricted_area"),
            _shot("e7", 120.0, S, JR, False, 2, ShotZone.MID, "top_mid"),
            _shot("e9", 124.0, S, UNKNOWN_23, True, 2, ShotZone.PAINT, "restricted_area"),
            _shot("e13", 150.0, S, JOSE, True, 3, ShotZone.THREE, "top_3"),
        ],
        box_scores=[_scouted_box(), _other_box()],
        play_summary=[
            _summary(PlayType.ISOLATION, S, 6, 0.097, 7, 1.1667, "3-5", 0),
            _summary(PlayType.PICK_AND_ROLL, S, 14, 0.226, 13, 0.9286, "5-11", 2),
            _summary(PlayType.FAST_BREAK, S, 2, 0.032, 5, 2.5, "2-2", 0),
            _summary(PlayType.ISOLATION, O, 3, 0.1, 2, 0.667, "1-3", 1),
            _summary(PlayType.ZONE_DEFENSE, S, 10, 0.323, 7, 0.7, "3-10", 2),
            _summary(PlayType.MAN_DEFENSE, S, 20, 0.645, 18, 0.9, "7-17", 4),
        ],
        data_quality=DataQuality(
            homography_available=True,
            coord_mode="court",
            ball_coverage=0.8234,
            jersey_match_rate=0.75,
            unmatched_jerseys=["scouted:#23"],
            tracks_total=24,
            tracks_assigned=18,
            event_confidence_mean=0.7134,
            warnings=[PipelineWarning(code="OCR_SPARSE", message="Few jersey numbers were readable.")],
        ),
    )


@pytest.fixture
def analysis() -> GameAnalysis:
    return make_analysis()


@pytest.fixture
def roster() -> Roster:
    return make_roster("g_test")


def _col(header: str, field: Any, **extra: Any) -> dict[str, Any]:
    return {"header": header, "field": field, **extra}


def _one_table(*columns: dict[str, Any], **options: Any) -> dict[str, Any]:
    return {"custom_tables": {"t": {"columns": list(columns), **options}}}


EXPECTED_PASTE = "\n".join(
    [
        "NAME\tMIN\tFGM-A\t3PM-A\tFTM-A\tOREB\tREB\tAST\tST\tBLK\tTO\tPF\tPTS",
        "Ty Allen\t\t0-0\t0-0\t0-0\t0\t0\t0\t0\t0\t0\t1\t0",
        "JR Smith\t22\t5-11\t2-5\t0-0\t1\t4\t4\t2\t0\t3\t2\t12",
        "Joey Nunez\t31\t3-8\t1-3\t2-2\t0\t5\t1\t0\t1\t1\t3\t9",
        "Unknown Twenty Three\t12\t2-3\t0-0\t0-0\t2\t3\t0\t0\t0\t0\t1\t4",
    ]
)

# ---------------------------------------------------------------------------
# Paste block
# ---------------------------------------------------------------------------


def test_paste_block_exact_output(analysis, game, roster):
    # Tab separated, one header row, DNP (#5) skipped, sorted by jersey, letters-only names,
    # fastscout_name override (#10), unrostered fallback (#23), blank MIN when unknown (#0).
    assert fastscout.build_paste_block(analysis, game, roster=roster) == EXPECTED_PASTE


def test_paste_block_reads_roster_from_database(analysis, game):
    db.save_roster(make_roster(game.id))
    assert fastscout.build_paste_block(analysis, game) == EXPECTED_PASTE


def test_paste_block_without_roster_uses_analysis_names(analysis, game):
    text = fastscout.build_paste_block(analysis, game, roster=Roster(game_id=game.id, side=S))
    names = [line.split("\t")[0] for line in text.splitlines()[1:]]
    assert names == ["Ty Allen", "JR Smith", "Jose Nunez", "Unknown Twenty Three"]


def test_paste_block_warnings(analysis, game, roster):
    warnings = fastscout.paste_block_warnings(analysis, game, roster=roster)
    joined = "\n".join(warnings)
    assert 'The player with #23 is not on the Opponent HS roster, so the row is named "Unknown Twenty Three"' in joined
    assert '"J.R. Smith" (#3) is pasted as "JR Smith"' in joined
    assert "Minutes could not be measured from the film for #0; MIN is left blank" in joined
    assert "(2 PTS, 2 FGA, 1 REB)" in joined
    assert "Joey" not in joined and "Ben" not in joined  # clean override; DNP not pasted
    assert len(warnings) == 4


def test_paste_block_options(analysis, game, roster):
    config = {
        "paste_block": {
            "delimiter": "comma",
            "header_row": False,
            "name_format": "last_first",
            "skip_dnp": False,
            "unknown_minutes": "zero",
            "unrostered_name": "Opponent {jersey_words}",
        }
    }
    lines = fastscout.build_paste_block(analysis, game, config=config, roster=roster).splitlines()
    assert lines[0] == "Allen Ty,0,0-0,0-0,0-0,0,0,0,0,0,0,1,0"
    assert lines[1] == "Smith JR,22,5-11,2-5,0-0,1,4,4,2,0,3,2,12"
    assert lines[2] == "Bench Ben,1,0-0,0-0,0-0,0,0,0,0,0,0,0,0"  # DNP kept; 0.6 min rounds to 1
    assert lines[3].startswith("Joey Nunez,31,")  # fastscout_name wins over name_format
    assert lines[4].startswith("Opponent Twenty Three,12,")


def test_paste_block_custom_columns(analysis, game, roster):
    config = {"paste_block": {"columns": [_col("NAME", "name"), _col("FG%", "fg_pct")]}}
    lines = fastscout.build_paste_block(analysis, game, config=config, roster=roster).splitlines()
    assert lines[:3] == ["NAME\tFG%", "Ty Allen\t", "JR Smith\t45.5%"]


def test_paste_block_separate_name_columns(analysis, game, roster):
    columns = [_col("FIRST", "first_name"), _col("LAST", "last_name"), _col("#", "jersey")]
    text = fastscout.build_paste_block(analysis, game, config={"paste_block": {"columns": columns}}, roster=roster)
    assert text.splitlines()[:3] == ["FIRST\tLAST\t#", "Ty\tAllen\t0", "JR\tSmith\t3"]


def test_paste_block_duplicate_names_warn(analysis, game, roster):
    roster.players[1].fastscout_name = "JR Smith"
    warnings = fastscout.paste_block_warnings(analysis, game, roster=roster)
    assert any('2 rows are named "JR Smith"' in w for w in warnings)


def test_paste_block_for_side_without_players(analysis, game):
    analysis.box_scores[1] = analysis.box_scores[1].model_copy(update={"players": []})
    other_roster = Roster(game_id=game.id, side=O)
    assert fastscout.build_paste_block(analysis, game, O, roster=other_roster) == EXPECTED_PASTE.splitlines()[0]
    assert fastscout.paste_block_warnings(analysis, game, "other", roster=other_roster) == [
        "No Rival HS player has a stat or a minute on the floor, so the paste has only the header row."
    ]


def test_paste_block_errors(analysis, game, roster):
    analysis.box_scores = analysis.box_scores[:1]
    with pytest.raises(ScoutError) as err:
        fastscout.build_paste_block(analysis, game, O, roster=roster)
    assert err.value.code == ErrorCode.ANALYSIS_NOT_READY
    with pytest.raises(ScoutError) as err:
        fastscout.build_paste_block(analysis, game, "home", roster=roster)
    assert err.value.code == ErrorCode.VALIDATION_FAILED


@pytest.mark.parametrize(
    ("raw", "clean"),
    [
        ("J.R. Smith", "JR Smith"),
        ("O'Neil", "ONeil"),
        ("José Núñez", "Jose Nunez"),
        ("Mary-Kate  Olsen", "Mary Kate Olsen"),
        ("#5 Mike", "Mike"),
        ("  Ødegaard\tJr. ", "Odegaard Jr"),
        ("Đorđe Łukasz", "Dorde Lukasz"),
        ("12", ""),
    ],
)
def test_sanitize_fastscout_name(raw, clean):
    assert fastscout.sanitize_fastscout_name(raw) == clean


@pytest.mark.parametrize(
    ("jersey", "words"),
    [
        ("0", "Zero"),
        ("00", "Double Zero"),
        ("5", "Five"),
        ("10", "Ten"),
        ("13", "Thirteen"),
        ("20", "Twenty"),
        ("23", "Twenty Three"),
        ("99", "Ninety Nine"),
        ("07", "Zero Seven"),
        ("123", "One Two Three"),
        ("2B", ""),
        (None, ""),
    ],
)
def test_jersey_words(jersey, words):
    assert fastscout.jersey_words(jersey) == words


# ---------------------------------------------------------------------------
# Team helper block
# ---------------------------------------------------------------------------


def test_team_helper_block(analysis):
    assert fastscout.team_helper_block(analysis, S) == "\n".join(
        [
            "Opponent HS: team numbers to type in by hand (not part of the paste)",
            "Final score: Opponent HS 27, Rival HS 20",
            "Fast-break points: 5",
            "Points in the paint: 10 (approximate: 1 made shot had no court location)",
            "Second-chance points: 3",
            "Points off turnovers: 6",
            "From video analysis - verify against the film.",
        ]
    )


# ---------------------------------------------------------------------------
# Custom table CSV
# ---------------------------------------------------------------------------


def test_custom_table_box_csv(analysis, game, roster):
    text = fastscout.build_custom_table_csv(analysis, game, roster=roster)
    assert not text.startswith("\ufeff") and not text.encode("utf-8").startswith(b"\xef\xbb\xbf")
    assert text.endswith("\r\n") and "\n" not in text.replace("\r\n", "")
    rows = text.split("\r\n")[:-1]
    assert rows == [
        "#,Player,MIN,PTS,FGM-A,FG%,3PM-A,3P%,FTM-A,FT%,ORB,DRB,REB,AST,TO,STL,BLK,PF",
        "0,Ty Allen,,0,0-0,,0-0,,0-0,,0,0,0,0,0,0,0,1",
        "3,J.R. Smith,22,12,5-11,45.5%,2-5,40.0%,0-0,,1,3,4,4,3,2,0,2",
        "10,José Núñez,31,9,3-8,37.5%,1-3,33.3%,2-2,100.0%,0,5,5,1,1,0,1,3",
        "23,Unknown,12,4,2-3,66.7%,0-0,,0-0,,2,1,3,0,0,0,0,1",
        ",Unidentified,,2,1-2,50.0%,0-0,,0-0,,0,1,1,0,0,0,0,0",
        ",Team Totals,160,27,11-24,45.8%,3-8,37.5%,2-2,100.0%,3,10,13,5,4,2,1,7",
    ]


def test_custom_table_zones_csv(analysis, game, roster):
    rows = fastscout.build_custom_table_csv(analysis, game, table="zones", roster=roster).split("\r\n")
    assert rows[0] == "#,Player,Paint FGM-A,Paint FG%,Mid FGM-A,Mid FG%,3PT FGM-A,3P%"
    assert rows[2] == "3,J.R. Smith,2-4,50.0%,1-2,50.0%,2-5,40.0%"


def test_custom_table_plays_csv(analysis, game):
    text = fastscout.build_custom_table_csv(analysis, game, table="plays")
    assert text == (
        "Play Type,Poss,% Poss,PTS,PPP,FG,TO\r\n"
        "P&R Ball Handler,14,22.6%,13,0.93,5-11,2\r\n"
        "Isolation,6,9.7%,7,1.17,3-5,0\r\n"
        "Transition,2,3.2%,5,2.50,2-2,0\r\n"
    )


def test_custom_table_defense_csv_quotes_commas(analysis, game):
    text = fastscout.build_custom_table_csv(analysis, game, table="defense")
    assert text == (
        "Defense,Poss,% Poss,PTS Allowed,PPP Allowed,Opp FG,TO Forced,Zone Shape\r\n"
        "Man-to-Man,20,64.5%,18,0.90,7-17,4,\r\n"
        'Zone,10,32.3%,7,0.70,3-10,2,"2-3 (2), 1-3-1 (1)"\r\n'
    )


def test_custom_table_unknown_name(analysis, game):
    with pytest.raises(ScoutError) as err:
        fastscout.build_custom_table_csv(analysis, game, table="nope")
    assert err.value.code == ErrorCode.VALIDATION_FAILED
    assert "box, zones, plays, defense" in err.value.message


def test_custom_table_config_options(analysis, game, roster):
    mini = {
        "title": "Mini",
        "totals_row": False,
        "unattributed_row": False,
        "columns": [
            _col("Player", "name"),
            _col("+/-", "plus_minus"),
            _col("MIN", "minutes_est"),
            _col("FG", "fg_pct", format="dec2"),
        ],
    }
    config = {
        "csv": {"line_ending": "lf", "bom": True, "default_table": "mini"},
        "play_labels": {"isolation": "ISO, one on one"},
        "custom_tables": {"mini": mini, "iso": {"rows": "plays", "columns": [_col("Play", "label")]}},
    }
    text = fastscout.build_custom_table_csv(analysis, game, config=config, roster=roster)
    assert text.startswith("\ufeffPlayer,+/-,MIN,FG\n")  # headers are written as-is (no formula guard)
    assert "J.R. Smith,,22.4,0.46\n" in text and "Team Totals" not in text  # fg_pct 0.455 -> "0.46"
    plays = fastscout.build_custom_table_csv(analysis, game, table="iso", config=config)
    assert '"ISO, one on one"' in plays
    assert fastscout.list_custom_tables(config) == ["mini", "iso"]


def test_list_custom_tables_and_titles():
    assert fastscout.list_custom_tables() == ["box", "zones", "plays", "defense"]
    assert fastscout.custom_table_titles() == {
        "box": "Box Score",
        "zones": "Shot Zones",
        "plays": "Play Types",
        "defense": "Defensive Looks",
    }


# ---------------------------------------------------------------------------
# Timeline CSV
# ---------------------------------------------------------------------------


def test_timeline_csv(analysis):
    rows = fastscout.build_timeline_csv(analysis).split("\r\n")
    assert rows[0] == (
        "Time,Seconds,Type,Event,Team,Player #,Player,Secondary Player,Possession Team,Possession #,Points,Zone,"
        "Subzone,X (ft),Y (ft),Confidence,Opponent HS Score,Rival HS Score,Play ID,Description"
    )
    assert len(rows) == len(analysis.timeline) + 2  # header + events + trailing empty string
    assert rows[1] == "00:05,5.0,period_start,Start of Period 1,,,,,,,0,,,,,0.50,0,0,,"
    assert rows[2] == "00:12,12.0,steal,Steal,Opponent HS,3,J.R. Smith,#4 Sam Rival,Opponent HS,1,0,,,,,0.50,0,0,,"
    assert rows[3] == (
        "00:16,16.0,shot_made,3PT Make,Opponent HS,3,J.R. Smith,,Opponent HS,1,3,three,left_corner_3,2.0,3.0,0.90,"
        "3,0,pl_1,Corner three by #3"
    )
    # RFC 4180 quoting, and a leading "=" is neutralised so spreadsheets do not run it as a formula.
    assert rows[5].endswith(',pl_2,"\'=HYPERLINK(""http://x"") said ""go"", scored"')


def test_clock_counts_past_an_hour():
    assert fastscout._clock(3725.9) == "62:05"


# ---------------------------------------------------------------------------
# YAML config
# ---------------------------------------------------------------------------


def test_shipped_yaml_matches_defaults():
    # config/fastscout_columns.yaml is what settings point to by default.
    assert fastscout.load_fastscout_config() == fastscout.validate_fastscout_config({})


def test_missing_config_file_uses_defaults(tmp_path):
    assert fastscout.load_fastscout_config(tmp_path / "missing.yaml") == fastscout.validate_fastscout_config({})


def test_invalid_yaml_file(tmp_path):
    path = tmp_path / "fastscout_columns.yaml"
    path.write_text("paste_block: [unclosed\n", encoding="utf-8")
    with pytest.raises(ScoutError) as err:
        fastscout.load_fastscout_config(path)
    assert err.value.code == ErrorCode.VALIDATION_FAILED
    assert "not valid YAML" in err.value.message


def test_non_utf8_yaml_file(tmp_path):
    path = tmp_path / "fastscout_columns.yaml"
    path.write_bytes("play_labels:\n  cut: Coupé\n".encode("cp1252"))
    with pytest.raises(ScoutError) as err:
        fastscout.load_fastscout_config(path)
    assert err.value.code == ErrorCode.VALIDATION_FAILED and "UTF-8" in err.value.message


def test_yaml_file_with_unknown_field_names_the_key(tmp_path):
    path = tmp_path / "fastscout_columns.yaml"
    columns = [_col("NAME", "name"), _col("X", "fgx")]
    path.write_text(yaml.safe_dump({"paste_block": {"columns": columns}}), encoding="utf-8")
    with pytest.raises(ScoutError) as err:
        fastscout.load_fastscout_config(path)
    assert err.value.code == ErrorCode.VALIDATION_FAILED
    assert "'paste_block.columns[1].field'" in err.value.message and "'fgx'" in err.value.message
    assert "fastscout_columns.yaml" in err.value.message


@pytest.mark.parametrize(
    ("config", "key"),
    [
        ({"paste_block": {"delimiter": "space"}}, "paste_block.delimiter"),
        ({"paste_block": {"skip_dnpp": True}}, "paste_block.skip_dnpp"),
        ({"paste_block": {"skip_dnp": "yes please"}}, "paste_block.skip_dnp"),
        ({"paste_block": {"unknown_minutes": "dash"}}, "paste_block.unknown_minutes"),
        ({"paste_block": {"unrostered_name": "Player {jersey_words} 2"}}, "paste_block.unrostered_name"),
        ({"paste_block": {"columns": [_col("NA\tME", "name")]}}, "paste_block.columns[0].header"),
        ({"paste_block": {"columns": []}}, "paste_block.columns"),
        ({"csv": {"line_ending": "cr"}}, "csv.line_ending"),
        ({"csv": {"default_table": "missing"}}, "csv.default_table"),
        ({"play_labels": {"alley_oop": "Lob"}}, "play_labels.alley_oop"),
        ({"custom_tables": {}}, "custom_tables"),
        ({"custom_tables": {"bad name": {"columns": [_col("A", "pts")]}}}, "custom_tables.bad name"),
        ({"custom_tables": {"t": {"colums": []}}}, "custom_tables.t.colums"),
        (_one_table(_col("A", "pts"), rows="teams"), "custom_tables.t.rows"),
        (_one_table(_col("A", "pts"), rows="plays"), "custom_tables.t.columns[0].field"),
        (_one_table(_col("A", ["pts"])), "custom_tables.t.columns[0].field"),
        (_one_table(_col("A", "pts", format="money")), "custom_tables.t.columns[0].format"),
        (_one_table(_col("A", "name", format="int")), "custom_tables.t.columns[0].format"),
        ({"extra": 1}, "extra"),
        ("just text", "(top level)"),
    ],
)
def test_config_validation_names_the_key(config, key):
    with pytest.raises(ScoutError) as err:
        fastscout.validate_fastscout_config(config)
    assert err.value.code == ErrorCode.VALIDATION_FAILED
    assert f"'{key}'" in err.value.message


def test_config_partial_override_keeps_defaults():
    raw = {"paste_block": {"unknown_minutes": "zero"}, "play_labels": {"cut": "Cutter"}}
    config = fastscout.validate_fastscout_config(raw)
    assert config["paste_block"]["unknown_minutes"] == "zero"
    assert config["paste_block"]["delimiter"] == "tab"
    assert [c["header"] for c in config["paste_block"]["columns"]][:2] == ["NAME", "MIN"]
    assert config["play_labels"]["cut"] == "Cutter" and config["play_labels"]["spot_up"] == "Spot Up"
    assert list(config["custom_tables"]) == ["box", "zones", "plays", "defense"]
