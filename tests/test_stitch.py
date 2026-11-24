"""Stitching: a jersey number carries across the pieces a player's track breaks into."""

from __future__ import annotations

import random

import pytest

from scout.analysis import pipeline, stitch, synthetic
from scout.schemas import Track
from tests import helpers


def _break_up(tracking, piece_s: float = 12.0, lost_s: float = 0.3, seed: int = 1):
    """Each track cut into pieces with new ids, a short gap between them, the reads left on one piece only."""
    rng = random.Random(seed)
    fps = tracking.video.fps
    out, next_id, origin = [], 10_000, {}
    for track in tracking.tracks:
        if track.role != "player" or len(track.samples) < 2:
            out.append(track)
            continue
        pieces, current, start = [], [], track.samples[0].f
        length = piece_s * rng.uniform(0.6, 1.4)  # players are not all lost at the same moment
        for sample in track.samples:
            if sample.f - start >= length * fps and current:
                pieces.append(current)
                current, start = [], sample.f + lost_s * fps
                length = piece_s * rng.uniform(0.6, 1.4)
            if sample.f >= start:
                current.append(sample)
        if current:
            pieces.append(current)
        keeper = rng.randrange(len(pieces))
        for index, samples in enumerate(pieces):
            lo, hi = samples[0].f, samples[-1].f
            reads = [r for r in track.jersey_reads if lo <= r.frame <= hi] if index == keeper else []
            out.append(Track(track_id=next_id, team_id=track.team_id, role=track.role, jersey_reads=reads, samples=samples))
            origin[next_id] = track.track_id
            next_id += 1
    broken = tracking.model_copy(update={"tracks": out, "ball": [b.model_copy(update={"holder_track_id": None}) for b in tracking.ball], "events": []})
    return broken, origin


def test_two_pieces_of_one_player_are_linked_and_strangers_are_not():
    a = helpers.track(1, 0, [(0, 10, 10), (30, 20, 10)], jersey="23")
    b = helpers.track(2, 0, [(45, 22, 10), (90, 30, 12)])  # picked up half a second later, 2 ft on
    far = helpers.track(3, 0, [(45, 60, 40), (90, 62, 40)])  # same team, other end of the floor
    other = helpers.track(4, 1, [(40, 21, 10), (90, 25, 10)])  # right there, but the other team
    late = helpers.track(5, 0, [(200, 20, 10), (260, 21, 10)])  # same spot, five seconds later
    tracking = helpers.tracking([a, b, far, other, late])
    assert stitch.link_tracks(tracking) == [[1, 2]]
    shared = {t.track_id: [r.text for r in t.jersey_reads] for t in stitch.share_jersey_reads(tracking).tracks}
    assert shared == {1: ["23"], 2: ["23"], 3: [], 4: [], 5: []}


def test_no_link_when_two_teammates_could_both_be_him():
    a = helpers.track(1, 0, [(0, 10, 10), (30, 20, 10)], jersey="23")
    b = helpers.track(2, 0, [(40, 21, 10), (90, 30, 12)])
    c = helpers.track(3, 0, [(40, 20, 12), (90, 25, 20)])  # just as close
    tracking = helpers.tracking([a, b, c])
    assert stitch.link_tracks(tracking) == []
    assert stitch.share_jersey_reads(tracking) is tracking


def test_a_broken_up_game_gets_most_of_its_names_back_and_no_wrong_ones(game):
    whole, _ = synthetic.generate_synthetic_game(seed=3, duration_s=300, ocr_noise=0.05)
    rosters = synthetic.synthetic_rosters(game.id, seed=3)
    broken, origin = _break_up(whole)
    assert len(broken.tracks) > 3 * len(whole.tracks)

    from scout.analysis.teams import resolve_team_map
    from scout.roster.matcher import assign_tracks

    def named_share(tracking):
        assignments = [a for a in assign_tracks(tracking, resolve_team_map(tracking, game), rosters, []) if a.role == "player"]
        frames = {t.track_id: len(t.samples) for t in tracking.tracks}
        return sum(frames[a.track_id] for a in assignments if a.player_id) / sum(frames[a.track_id] for a in assignments)

    before, after = named_share(broken), named_share(stitch.share_jersey_reads(broken))
    assert before < 0.1 and after > 0.6, (before, after)  # one read per player: 5% of his time named, then most of it
    # Wrong links are rare (a substitute stepping in exactly where a teammate left looks the same).
    links = [(a, b) for chain in stitch.link_tracks(broken) for a, b in zip(chain, chain[1:], strict=False)]
    wrong = [pair for pair in links if origin[pair[0]] != origin[pair[1]]]
    assert len(links) > 150 and len(wrong) <= 0.02 * len(links), (len(links), len(wrong))
    analysis = pipeline.analyze_game(broken, game, rosters, [])
    assert analysis.data_quality.jersey_match_rate == pytest.approx(after, abs=0.05)


def test_a_chain_that_reads_two_numbers_is_cut_between_them():
    pieces = [
        helpers.track(1, 0, [(0, 10, 10), (30, 12, 10)], jersey="23"),
        helpers.track(2, 0, [(40, 13, 10), (70, 15, 10)]),
        helpers.track(3, 0, [(80, 16, 10), (110, 18, 10)]),
        helpers.track(4, 0, [(120, 19, 10), (150, 21, 10)], jersey="11"),
    ]
    tracking = helpers.tracking(pieces)
    assert stitch.link_tracks(tracking) == [[1, 2, 3, 4]]
    shared = {t.track_id: [r.text for r in t.jersey_reads] for t in stitch.share_jersey_reads(tracking).tracks}
    assert shared == {1: ["23"], 2: ["23"], 3: ["11"], 4: ["11"]}
    # "2" seen when the 3 was hidden is still jersey 23: no cut.
    pieces[3] = helpers.track(4, 0, [(120, 19, 10), (150, 21, 10)], jersey="2")
    shared = {t.track_id: len(t.jersey_reads) for t in stitch.share_jersey_reads(helpers.tracking(pieces)).tracks}
    assert shared == {1: 2, 2: 2, 3: 2, 4: 2}
