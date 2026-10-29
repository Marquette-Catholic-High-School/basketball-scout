"""Jersey OCR -> roster matching: normalisation, similarity, voting and track assignment."""

from __future__ import annotations

import random
import time
from collections import defaultdict
from collections.abc import Sequence
from typing import Literal

import pytest

from scout.roster.matcher import (
    DIGIT_CONFUSION,
    assign_tracks,
    jersey_similarity,
    jersey_votes,
    match_name,
    match_votes,
    normalize_jersey,
)
from scout.schemas import JerseyRead, Roster, RosterPlayer, TeamSide, Track, TrackAssignment, TrackOverride, TrackSample
from tests import helpers

SCOUTED, OTHER = TeamSide.SCOUTED, TeamSide.OTHER
TEAM_MAP = {0: SCOUTED, 1: OTHER}
FPS = 30  # helpers.tracking() videos


def _roster(side: TeamSide, *jerseys: str) -> Roster:
    """Player ids are "<side>-<jersey>" so assertions stay readable."""
    players = [
        RosterPlayer(id=f"{side.value}-{jersey}", jersey=jersey, first_name="Player", last_name=jersey)
        for jersey in jerseys
    ]
    return Roster(game_id="g_test", side=side, players=players)


def _track(
    track_id: int,
    team_id: int | None,
    frames: tuple[int, int],
    reads: Sequence[str | tuple[str, float]] = (),
    *,
    role: Literal["player", "referee", "unknown"] = "player",
) -> Track:
    """A track sampled every 3 frames over ``frames`` (inclusive); reads are texts (conf 0.9) or (text, conf)."""
    start, end = frames
    samples = [TrackSample(f=f, bbox=(0.0, 0.0, 10.0, 60.0)) for f in range(start, end + 1, 3)]
    jersey_reads = []
    for offset, read in enumerate(reads):
        text, conf = (read, 0.9) if isinstance(read, str) else read
        jersey_reads.append(JerseyRead(frame=start + 3 * offset, text=text, conf=conf))
    return Track(track_id=track_id, team_id=team_id, role=role, jersey_reads=jersey_reads, samples=samples)


def _assign(
    tracks: list[Track],
    rosters: dict[TeamSide, Roster],
    overrides: list[TrackOverride] | None = None,
) -> dict[int, TrackAssignment]:
    return {a.track_id: a for a in assign_tracks(helpers.tracking(tracks), TEAM_MAP, rosters, overrides)}


# ---------------------------------------------------------------------------
# normalize_jersey / jersey_similarity / jersey_votes
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("23", "23"), ("#23", "23"), (" 23. ", "23"), ("2 3", "23"),
        ("2B", "28"), ("Z3", "23"), ("l2", "12"), ("|7", "17"), ("1!", "11"), ("lO", "10"),
        ("O", "0"), ("o", "0"), ("OO", "00"), ("0O", "00"), ("S", "5"), ("s", "5"), ("B", "8"),
        ("G", "6"), ("T", "7"), ("A", "4"), ("z", "2"),
        ("05", "05"), ("0", "0"), ("00", "00"),
        ("No. 5", "5"), ("EAGLES 23", "23"),
        ("Sr", None), ("OK", None), ("BOB", None), ("#", None), ("", None), (None, None),
        ("123", None), ("2323", None),
    ],
)  # fmt: skip
def test_normalize_jersey(text, expected):
    assert normalize_jersey(text) == expected


@pytest.mark.parametrize(
    ("read", "jersey", "score", "method"),
    [
        ("23", "23", 1.0, "exact"),
        ("Z3", "23", 1.0, "exact"),
        ("05", "5", 0.9, "fuzzy"),
        ("5", "05", 0.9, "fuzzy"),
        ("0", "00", 0.45, "partial"),  # one zero hidden
        ("00", "0", 0.0, "none"),  # 0 and 00 are different numbers
        ("3", "8", 0.7, "fuzzy"),
        ("28", "23", 0.7, "fuzzy"),
        ("17", "11", 0.7, "fuzzy"),
        ("13", "78", 0.49, "fuzzy"),  # two confused digits multiply
        ("2", "23", 0.45, "partial"),  # first digit visible
        ("3", "23", 0.4, "partial"),  # last digit visible
        ("8", "23", 0.28, "partial"),  # last digit visible and confused (0.4 x 0.7)
        ("23", "32", 0.3, "partial"),  # reversed
        ("38", "83", 0.49, "fuzzy"),  # confusion beats reversal
        ("23", "45", 0.0, "none"),
        ("23", "3", 0.0, "none"),  # a read longer than the jersey
        ("Sr", "5", 0.0, "none"),
    ],
)
def test_jersey_similarity(read, jersey, score, method):
    assert jersey_similarity(read, jersey) == (pytest.approx(score), method)


def test_similarity_is_bounded_exact_only_for_equal_numbers_and_symmetric_for_same_length():
    numbers = [str(n) for n in range(100)] + ["00"] + [f"0{n}" for n in range(1, 10)]
    for read in numbers:
        for jersey in numbers:
            score, method = jersey_similarity(read, jersey)
            assert 0.0 <= score <= 1.0
            assert (score == 1.0) == (read == jersey) == (method == "exact")
            if len(read) == len(jersey):
                assert jersey_similarity(jersey, read)[0] == score


def test_single_digit_confusions_follow_the_table():
    for pair, similarity in DIGIT_CONFUSION.items():
        a, b = sorted(pair)
        assert jersey_similarity(a, b) == (similarity, "fuzzy")


def test_jersey_votes_weights_by_confidence_and_drops_noise():
    texts = [("23", 0.9), ("Z3", 0.6), ("2", 0.5), ("23", 0.1), ("Sr", 0.9), ("123", 0.8)]
    reads = [JerseyRead(frame=i, text=text, conf=conf) for i, (text, conf) in enumerate(texts)]

    votes = jersey_votes(reads)
    assert votes == {"23": 1.5, "2": 0.5}
    assert list(votes) == ["23", "2"]  # strongest first
    assert jersey_votes(reads, min_conf=0.05)["23"] == pytest.approx(1.6)
    assert jersey_votes([]) == {}


# ---------------------------------------------------------------------------
# match_votes
# ---------------------------------------------------------------------------


def test_match_votes_with_noisy_and_partial_reads():
    roster = _roster(SCOUTED, "3", "8", "23", "28")
    player, score, method = match_votes({"23": 3.0, "2": 1.0, "28": 0.5, "3": 0.5}, roster)
    assert (player.jersey, method) == ("23", "exact")
    assert score == pytest.approx((3.0 + 0.45 + 0.35 + 0.2) / 5.0)


def test_match_votes_single_digit_confusion():
    player, score, method = match_votes({"3": 2.0, "8": 1.0}, _roster(SCOUTED, "8", "3"))
    assert (player.jersey, score, method) == ("3", pytest.approx(0.9), "exact")


def test_match_votes_below_threshold_is_unrostered_and_threshold_is_a_keyword():
    roster = _roster(SCOUTED, "23", "32")
    assert match_votes({"2": 2.0}, roster) == (None, 0.45, "unrostered")
    player, score, method = match_votes({"2": 2.0}, roster, accept=0.4)
    assert (player.jersey, score, method) == ("23", 0.45, "partial")  # "2" is the first digit of 23


def test_match_votes_without_votes_or_roster():
    assert match_votes({}, _roster(SCOUTED, "5")) == (None, 0.0, "none")
    assert match_votes({"5": 1.0}, _roster(SCOUTED)) == (None, 0.0, "unrostered")
    assert match_votes({"5": 1.0}, _roster(SCOUTED, "40")) == (None, 0.0, "unrostered")


def test_match_votes_tie_break_prefers_exact_reads():
    # #4 gets 0.7/1.7 from exact "4" reads; #8 gets the same 0.7/1.7 from "0" reads (0/8 confusion).
    player, score, method = match_votes({"4": 0.7, "0": 1.0}, _roster(SCOUTED, "8", "4"), accept=0.3)
    assert (player.jersey, method) == ("4", "exact")
    assert score == pytest.approx(0.7 / 1.7, abs=1e-4)


# ---------------------------------------------------------------------------
# assign_tracks
# ---------------------------------------------------------------------------


def test_each_side_matches_its_own_roster_in_track_order():
    rosters = {SCOUTED: _roster(SCOUTED, "3", "23"), OTHER: _roster(OTHER, "3", "12")}
    tracks = [
        _track(7, 1, (0, 300), ["3"] * 4),
        _track(2, 0, (0, 300), ["23", "23", "2", "28"]),
        _track(5, 0, (0, 300), ["l2"] * 3),  # #12 is only on the other roster
    ]
    result = assign_tracks(helpers.tracking(tracks), TEAM_MAP, rosters)

    assert [a.track_id for a in result] == [7, 2, 5]
    by_id = {a.track_id: a for a in result}
    assert (by_id[7].side, by_id[7].player_id, by_id[7].method, by_id[7].role) == (OTHER, "other-3", "exact", "player")
    assert (by_id[2].player_id, by_id[2].jersey, by_id[2].frames, by_id[2].team_id) == ("scouted-23", "23", 101, 0)
    assert (by_id[5].side, by_id[5].player_id, by_id[5].jersey, by_id[5].method) == (SCOUTED, None, "12", "unrostered")
    assert by_id[5].match_score == 1.0  # vote share of the best read


def test_overlapping_tracks_cannot_share_a_player_and_fall_back_to_next_best():
    rosters = {SCOUTED: _roster(SCOUTED, "23", "28"), OTHER: _roster(OTHER)}
    long_track = _track(1, 0, (0, 900), ["23"] * 5)
    overlapping = _track(2, 0, (300, 600), ["23", "23", "28"])  # listed first, but shorter and noisier
    result = _assign([overlapping, long_track], rosters)

    assert result[1].player_id == "scouted-23"
    assert (result[2].player_id, result[2].jersey, result[2].method) == ("scouted-28", "28", "fuzzy")


def test_overlapping_track_without_a_fallback_is_unrostered_with_its_best_read():
    rosters = {SCOUTED: _roster(SCOUTED, "23"), OTHER: _roster(OTHER)}
    result = _assign([_track(1, 0, (0, 900), ["23"] * 5), _track(2, 0, (300, 600), ["23", "23", "28"])], rosters)

    assert result[1].player_id == "scouted-23"
    weaker = result[2]  # no jersey: #23 is track 1, a second "#23" line would be a player who does not exist
    assert (weaker.player_id, weaker.method, weaker.jersey, weaker.best_read) == (None, "unrostered", None, "23")
    assert weaker.match_score == pytest.approx(2 / 3, abs=1e-3)


def test_fragments_of_one_player_that_do_not_overlap_share_the_player():
    rosters = {SCOUTED: _roster(SCOUTED, "23"), OTHER: _roster(OTHER)}
    fragments = [
        _track(1, 0, (0, 300), ["23"] * 3),
        _track(2, 0, (330, 600), ["23"] * 2),
        _track(3, 0, (590, 900), ["2", "23"]),  # 10-frame hand-over overlap with track 2 is tolerated
    ]
    result = _assign(fragments, rosters)
    assert [result[i].player_id for i in (1, 2, 3)] == ["scouted-23"] * 3


def test_zero_and_double_zero_are_different_players():
    rosters = {SCOUTED: _roster(SCOUTED, "0", "00"), OTHER: _roster(OTHER)}
    result = _assign([_track(1, 0, (0, 300), ["0"] * 3), _track(2, 0, (0, 300), ["OO", "00", "00"])], rosters)
    assert (result[1].player_id, result[2].player_id) == ("scouted-0", "scouted-00")


def test_partial_reads_alone_are_not_enough():
    rosters = {SCOUTED: _roster(SCOUTED, "23"), OTHER: _roster(OTHER)}
    result = _assign([_track(1, 0, (0, 300), ["2", "2", "23"]), _track(2, 0, (400, 700), ["2", "2", "2"])], rosters)

    assert (result[1].player_id, result[1].method) == ("scouted-23", "exact")
    assert (result[2].player_id, result[2].jersey, result[2].method) == (None, "2", "unrostered")


def test_noisy_track_resolves_to_the_right_player():
    rosters = {SCOUTED: _roster(SCOUTED, "3", "8", "13"), OTHER: _roster(OTHER)}
    reads = [("3", 0.9), ("8", 0.6), ("3", 0.8), ("B", 0.5), ("3", 0.7), ("13", 0.3), ("3", 0.15)]
    assignment = _assign([_track(1, 0, (0, 300), reads)], rosters)[1]

    assert (assignment.player_id, assignment.method) == ("scouted-3", "exact")
    assert assignment.votes == {"3": 2.4, "8": 1.1, "13": 0.3}
    assert assignment.match_score == pytest.approx((2.4 + 0.7 * 1.1) / 3.8, abs=1e-4)


def test_overrides_win_and_block_conflicting_automatic_matches():
    rosters = {SCOUTED: _roster(SCOUTED, "5", "15"), OTHER: _roster(OTHER, "5")}
    tracks = [
        _track(1, 0, (0, 600), ["15"] * 3),  # the coach says this is #5
        _track(2, 0, (100, 500), ["5"] * 4),  # reads 5, but #5 is on the floor in track 1
        _track(3, 1, (0, 600), ["5"] * 3),  # a bench player: ignored
        _track(4, 0, (0, 600), ["15"] * 2),  # explicitly not a roster player, and on the other team
        _track(5, 0, (700, 900), ["9"]),  # override to a deleted player -> automatic matching
    ]
    overrides = [
        TrackOverride(track_id=1, player_id="scouted-5"),
        TrackOverride(track_id=3, ignore=True),
        TrackOverride(track_id=4, side=OTHER),
        TrackOverride(track_id=5, player_id="p_deleted"),
        TrackOverride(track_id=99, player_id="scouted-15"),  # no such track
    ]
    result = _assign(tracks, rosters, overrides)

    manual = result[1]
    assert (manual.player_id, manual.jersey, manual.method, manual.match_score) == ("scouted-5", "5", "manual", 1.0)
    assert (result[2].player_id, result[2].jersey, result[2].method) == (None, None, "unrostered")
    assert (result[3].ignored, result[3].method, result[3].player_id) == (True, "manual", None)
    assert (result[4].player_id, result[4].side, result[4].jersey, result[4].method) == (None, OTHER, "15", "manual")
    assert (result[5].jersey, result[5].method) == ("9", "unrostered")
    assert set(result) == {1, 2, 3, 4, 5}


def test_referees_are_never_matched_unless_the_coach_says_so():
    rosters = {SCOUTED: _roster(SCOUTED, "12"), OTHER: _roster(OTHER, "12")}
    tracks = [_track(1, None, (0, 300), ["12"] * 3, role="referee"), _track(2, 2, (0, 300), ["12"] * 3, role="referee")]
    result = _assign(tracks, rosters, [TrackOverride(track_id=2, player_id="other-12")])

    referee = result[1]
    assert (referee.role, referee.player_id, referee.side, referee.jersey) == ("referee", None, None, None)
    assert referee.method == "none"
    assert referee.frames == 101
    corrected = result[2]
    assert (corrected.role, corrected.player_id, corrected.side) == ("player", "other-12", OTHER)
    assert corrected.method == "manual"


def test_unknown_team_id_tries_both_rosters():
    rosters = {SCOUTED: _roster(SCOUTED, "4", "23"), OTHER: _roster(OTHER, "11", "23")}
    tracks = [
        _track(1, None, (0, 300), ["11"] * 3),
        _track(2, 5, (0, 300), ["4", "4"]),  # team id 5 is not in the team map
        _track(3, None, (0, 300), ["23"] * 3),  # both teams have a #23: do not guess
        _track(4, None, (0, 300), ["77"]),
    ]
    result = _assign(tracks, rosters)

    assert (result[1].side, result[1].player_id) == (OTHER, "other-11")
    assert (result[2].side, result[2].player_id, result[2].team_id) == (SCOUTED, "scouted-4", 5)
    assert (result[3].side, result[3].player_id, result[3].jersey, result[3].method) == (None, None, None, "unrostered")
    assert (result[4].side, result[4].player_id, result[4].method) == (None, None, "unrostered")


def test_empty_roster_keeps_the_best_read_with_its_vote_share():
    rosters = {SCOUTED: _roster(SCOUTED), OTHER: _roster(OTHER)}
    reads = [("14", 0.9), ("14", 0.9), ("4", 0.6)]
    result = _assign([_track(1, 0, (0, 300), reads), _track(2, 1, (0, 300))], rosters)

    unrostered = result[1]
    assert (unrostered.method, unrostered.jersey, unrostered.best_read) == ("unrostered", "14", "14")
    assert unrostered.side == SCOUTED
    assert unrostered.match_score == pytest.approx(0.75)
    assert (result[2].method, result[2].jersey, result[2].match_score, result[2].votes) == ("none", None, 0.0, {})

    no_rosters = assign_tracks(helpers.tracking([_track(1, 0, (0, 300), reads)]), TEAM_MAP, {})
    assert (no_rosters[0].method, no_rosters[0].jersey) == ("unrostered", "14")


def test_two_hundred_tracks_are_fast_and_never_double_book_a_player():
    rng = random.Random(3)
    jerseys = [str(n) for n in rng.sample(range(100), 30)]
    rosters = {SCOUTED: _roster(SCOUTED, *jerseys[:15]), OTHER: _roster(OTHER, *jerseys[15:])}
    noise = ["2", "8", "B", "O", "l", "13", "Sr"]
    tracks = []
    for track_id in range(200):
        truth = rng.choice(jerseys)
        start = rng.randrange(0, 3000)
        reads = [truth if rng.random() < 0.6 else rng.choice(noise) for _ in range(40)]
        tracks.append(_track(track_id, rng.choice([0, 1, None]), (start, start + rng.randrange(30, 600)), reads))
    tracking = helpers.tracking(tracks)

    began = time.perf_counter()
    result = assign_tracks(tracking, TEAM_MAP, rosters)
    assert time.perf_counter() - began < 1.0
    assert len(result) == 200

    spans_by_player: dict[str, list[tuple[int, int]]] = defaultdict(list)
    for track, assignment in zip(tracks, result, strict=True):
        if assignment.player_id:
            spans_by_player[assignment.player_id].append((track.first_frame, track.last_frame))
    for spans in spans_by_player.values():
        for i, (start_a, end_a) in enumerate(spans):
            for start_b, end_b in spans[i + 1 :]:
                assert min(end_a, end_b) - max(start_a, start_b) <= FPS  # at most ~1 s shared


# ---------------------------------------------------------------------------
# match_name
# ---------------------------------------------------------------------------


def test_match_name_against_names_and_fastscout_names():
    roster = Roster(
        game_id="g_test",
        side=SCOUTED,
        players=[
            RosterPlayer(id="kvd", jersey="3", first_name="Kevin", last_name="Van Dyke"),
            RosterPlayer(
                id="tw", jersey="5", first_name="Tyrell", last_name="Williams Jr.", fastscout_name="T. Williams"
            ),
        ],
    )
    assert match_name("Kevin Van Dyke", roster) == (roster.players[0], 100.0)
    assert match_name("van dyke, kevin", roster)[0].id == "kvd"
    assert match_name("Kevn Van Dyk", roster)[0].id == "kvd"  # typo
    assert match_name("T. Williams", roster) == (roster.players[1], 100.0)

    nobody, score = match_name("Marcus Johnson", roster)
    assert nobody is None and score < 80
    assert match_name("Kevn Van Dyk", roster, threshold=99)[0] is None
    assert match_name("   ", roster) == (None, 0.0)
