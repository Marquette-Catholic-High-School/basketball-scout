"""Team-id -> side mapping from explicit coach choice, colour hints and fallbacks."""

from __future__ import annotations

import pytest

from scout.analysis import teams
from scout.schemas import Game, TeamInfo, TeamSide
from tests import helpers

S, O = TeamSide.SCOUTED, TeamSide.OTHER


def _tracking(team_infos: list[TeamInfo]):
    t = helpers.tracking([helpers.track(1, 0, [(0, 10.0, 10.0)]), helpers.track(2, 1, [(0, 20.0, 20.0)])])
    return t.model_copy(update={"teams": team_infos})


def _game(color: str | None = None, team_id_map: dict | None = None) -> Game:
    return Game(scouted_team="Central", other_team="North", scouted_color=color, team_id_map=team_id_map or {})


RED_ROYAL = [TeamInfo(team_id=0, color_rgb=(200, 30, 35)), TeamInfo(team_id=1, color_rgb=(40, 70, 190))]
WHITE_MAROON = [TeamInfo(team_id=0, color_rgb=(240, 240, 240)), TeamInfo(team_id=1, color_rgb=(110, 25, 40))]
NAVY_WHITE = [TeamInfo(team_id=0, color_rgb=(20, 20, 60)), TeamInfo(team_id=1, color_rgb=(240, 240, 240))]
WHITE_NAVY = [TeamInfo(team_id=0, color_rgb=(240, 240, 240)), TeamInfo(team_id=1, color_rgb=(20, 20, 60))]


def test_fallback_team_zero_is_scouted():
    assert teams.resolve_team_map(_tracking(NAVY_WHITE), _game()) == {0: S, 1: O}


def test_explicit_map_wins_over_colour():
    result = teams.resolve_team_map(_tracking(NAVY_WHITE), _game("dark", {0: O, 1: S}))
    assert result == {0: O, 1: S}


def test_partial_explicit_map_fills_remaining_side():
    assert teams.resolve_team_map(_tracking(NAVY_WHITE), _game(None, {1: S})) == {0: O, 1: S}


def test_contradictory_explicit_map_is_ignored():
    # Both ids on one side would break every stat; fall back to the colour hint.
    assert teams.resolve_team_map(_tracking(NAVY_WHITE), _game("white", {0: S, 1: S})) == {0: O, 1: S}


@pytest.mark.parametrize(
    ("hint", "infos", "expected_scouted"),
    [
        ("dark", NAVY_WHITE, 0),
        ("light", NAVY_WHITE, 1),
        ("white", WHITE_NAVY, 0),
        ("Black", WHITE_NAVY, 1),
        ("navy", WHITE_NAVY, 1),
        ("#141e50", WHITE_NAVY, 1),
        ("#fff", NAVY_WHITE, 1),
        ("royal blue", RED_ROYAL, 1),
        ("maroon and gold", WHITE_MAROON, 1),
    ],
)
def test_colour_hints(hint, infos, expected_scouted):
    result = teams.resolve_team_map(_tracking(infos), _game(hint))
    assert result[expected_scouted] == S
    assert sorted(result.values()) == [O, S]  # never both on one side


def test_pipeline_light_dark_labels_without_rgb():
    infos = [TeamInfo(team_id=0, color_name="light"), TeamInfo(team_id=1, color_name="dark")]
    assert teams.resolve_team_map(_tracking(infos), _game("dark")) == {0: O, 1: S}
    # A colour word is compared by brightness class: red jerseys count as "dark".
    assert teams.resolve_team_map(_tracking(infos), _game("red")) == {0: O, 1: S}
    assert teams.resolve_team_map(_tracking(infos), _game("gold")) == {0: S, 1: O}


def test_only_one_team_has_a_colour():
    infos = [TeamInfo(team_id=0, color_name="light"), TeamInfo(team_id=1)]
    assert teams.resolve_team_map(_tracking(infos), _game("dark")) == {0: O, 1: S}
    assert teams.resolve_team_map(_tracking(infos), _game("light")) == {0: S, 1: O}


def test_unknown_hint_or_tie_falls_back():
    assert teams.resolve_team_map(_tracking(NAVY_WHITE), _game("plaid")) == {0: S, 1: O}
    same = [TeamInfo(team_id=0, color_rgb=(50, 50, 50)), TeamInfo(team_id=1, color_rgb=(50, 50, 50))]
    assert teams.resolve_team_map(_tracking(same), _game("dark")) == {0: S, 1: O}


def test_extra_cluster_ids_go_to_other():
    infos = NAVY_WHITE + [TeamInfo(team_id=2, color_rgb=(128, 128, 128))]
    result = teams.resolve_team_map(_tracking(infos), _game("light"))
    assert result == {0: O, 1: S, 2: O}


def test_ids_from_tracks_without_team_info():
    t = _tracking([])
    assert teams.resolve_team_map(t, _game("dark")) == {0: S, 1: O}


def test_side_of():
    team_map = {0: S, 1: O}
    assert teams.side_of(team_map, 1) == O
    assert teams.side_of(team_map, None) is None
    assert teams.side_of(team_map, 7) is None


def test_parse_colour():
    assert teams.parse_colour("#1A2B3C") == (26, 43, 60)
    assert teams.parse_colour("Kelly Green") == teams.NAMED_COLORS["kelly green"]
    assert teams.parse_colour("dark green") == teams.NAMED_COLORS["dark green"]
    assert teams.parse_colour("nope") is None
