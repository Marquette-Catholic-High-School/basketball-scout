"""Synthetic game generator: determinism, schema consistency and ground truth."""

from __future__ import annotations

import time
from collections import Counter, defaultdict

import numpy as np
import pytest

from scout.analysis.geometry import CourtConfig, apply_homography, bbox_foot_point, is_three, nearest_basket
from scout.analysis.synthetic import generate_synthetic_game, synthetic_rosters
from scout.analysis.tracking_index import TrackingIndex
from scout.schemas import OFFENSIVE_PLAY_TYPES, RawEventType, TeamSide, TrackingResult

COURT = CourtConfig()


@pytest.fixture(scope="module")
def game():
    return generate_synthetic_game(seed=7)


def retally(tracking: TrackingResult, track_players: dict[int, str]) -> tuple[dict[str, Counter], dict[str, int]]:
    """Independent box-score tally from the raw events (ARCHITECTURE "Event semantics")."""
    box: dict[str, Counter] = defaultdict(Counter)
    score = Counter()
    side_of_team = {0: "scouted", 1: "other"}
    last_miss = None
    for e in tracking.events:
        who = track_players.get(e.track_id)
        side = side_of_team.get(e.team_id)
        a = e.attrs
        if e.type == RawEventType.SHOT:
            made = a["made"] is True and not a.get("blocked_by_track")
            three = a["is_three"]
            box[who].update(fga=1, tpa=int(three))
            if made:
                box[who].update(fgm=1, tpm=int(three), pts=3 if three else 2)
                score[side] += 3 if three else 2
                if a.get("assisted_by_track") is not None:
                    box[track_players[a["assisted_by_track"]]]["ast"] += 1
            else:
                last_miss = side
            if a.get("blocked_by_track") is not None:
                box[track_players[a["blocked_by_track"]]]["blk"] += 1
        elif e.type == RawEventType.FREE_THROW:
            box[who].update(fta=1, ftm=int(a["made"]), pts=int(a["made"]))
            score[side] += int(a["made"])
            if not a["made"]:
                last_miss = side
        elif e.type == RawEventType.REBOUND:
            offensive = a["offensive"] if a.get("offensive") is not None else side == last_miss
            box[who]["oreb" if offensive else "dreb"] += 1
        elif e.type == RawEventType.TURNOVER:
            box[who]["tov"] += 1
            if a.get("stolen_by_track") is not None:
                box[track_players[a["stolen_by_track"]]]["stl"] += 1
        elif e.type == RawEventType.FOUL:
            box[who]["pf"] += 1
    return box, dict(score)


def test_deterministic_and_fast():
    start = time.perf_counter()
    first, truth = generate_synthetic_game(seed=7)
    assert time.perf_counter() - start < 5.0
    second, truth2 = generate_synthetic_game(seed=7)
    assert first.model_dump_json() == second.model_dump_json()
    assert truth == truth2
    other, _ = generate_synthetic_game(seed=8)
    assert other.model_dump_json() != first.model_dump_json()


def test_truth_box_and_score_match_the_raw_events(game):
    tracking, truth = game
    box, score = retally(tracking, truth.track_players)
    assert score == truth.score and sum(score.values()) > 20
    for key, line in truth.box.items():
        assert {k: v for k, v in line.items() if v} == dict(+box[key]), key
    assert set(truth.box) == set(truth.track_players.values())
    assert len(truth.box) == 10 and {k.split(":")[0] for k in truth.box} == {"scouted", "other"}
    # Points add up, and box keys use the roster jerseys.
    assert sum(v["pts"] for k, v in truth.box.items() if k.startswith("scouted")) == truth.score["scouted"]
    rosters = synthetic_rosters("g_test", seed=7)
    for key in truth.box:
        side, jersey = key.split(":#")
        assert jersey in {p.jersey for p in rosters[TeamSide(side)].players}


def test_events_are_consistent_with_tracks_and_ball(game):
    tracking, truth = game
    TrackingResult.model_validate(tracking.model_dump())
    fps = tracking.video.fps
    frames = [e.frame for e in tracking.events]
    assert frames == sorted(frames) and all(e.t == pytest.approx(e.frame / fps) for e in tracking.events)
    track_team = {t.track_id: t.team_id for t in tracking.tracks}
    index = TrackingIndex(tracking, COURT)
    mismatched = 0
    seen = Counter(e.type for e in tracking.events)
    for kind in RawEventType:
        assert seen[kind] or kind == RawEventType.TIMEOUT, kind
    for e in tracking.events:
        if e.track_id is not None:
            assert track_team[e.track_id] == e.team_id
        if e.type == RawEventType.SHOT:
            xy = tuple(e.attrs["shot_court_xy"])
            assert e.attrs["is_three"] == is_three(COURT, xy, nearest_basket(COURT, xy))
            assert len(e.attrs["shot_xy_px"]) == 2
            if e.attrs["assisted_by_track"] is not None:
                assert e.attrs["made"] and track_team[e.attrs["assisted_by_track"]] == e.team_id
            if e.attrs["blocked_by_track"] is not None:
                assert not e.attrs["made"] and track_team[e.attrs["blocked_by_track"]] != e.team_id
        if e.type == RawEventType.TURNOVER and e.attrs.get("kind") == "steal":
            assert track_team[e.attrs["stolen_by_track"]] != e.team_id
        if e.type in (RawEventType.SHOT, RawEventType.PASS, RawEventType.FREE_THROW):
            mismatched += index.holder_at(e.frame - 3, max_gap_frames=4) != e.track_id
        if e.type == RawEventType.REBOUND:
            mismatched += index.holder_at(e.frame + 3, max_gap_frames=4) != e.track_id
    assert mismatched <= 0.05 * len(tracking.events)  # only ball-detection dropouts


def test_camera_homography_and_pixel_mode(game):
    tracking, _ = game
    matrix = tracking.court.homographies[0].matrix
    for track in tracking.tracks[:4]:
        for s in track.samples[::200]:
            x1, y1, x2, y2 = s.bbox
            assert 0 <= x1 < x2 <= 1920 and 0 <= y1 < y2 <= 1080
            back = apply_homography(matrix, bbox_foot_point(s.bbox))
            assert back == pytest.approx(s.court_xy, abs=0.15)
    pixel, _ = generate_synthetic_game(seed=7, duration_s=120.0, with_homography=False)
    assert not pixel.court.homographies and {w.code for w in pixel.warnings} == {"NO_COURT_HOMOGRAPHY"}
    assert all(s.court_xy is None for t in pixel.tracks for s in t.samples)
    assert all(b.court_xy is None for b in pixel.ball)
    assert all(e.attrs["shot_court_xy"] is None for e in pixel.events if e.type == RawEventType.SHOT)
    assert TrackingIndex(pixel, COURT).coord_mode == "pixel"


def test_teams_referees_fragmentation_and_ocr_noise(game):
    tracking, truth = game
    assert [t.color_name for t in tracking.teams] == ["navy", "white"]
    refs = [t for t in tracking.tracks if t.role == "referee"]
    assert len(refs) == 3 and all(t.team_id is None and not t.jersey_reads for t in refs)
    by_player = defaultdict(list)
    for tid, key in truth.track_players.items():
        by_player[key].append(next(t for t in tracking.tracks if t.track_id == tid))
    split = {key: parts for key, parts in by_player.items() if len(parts) > 1}
    assert len(split) == 2
    for parts in split.values():
        first, second = sorted(parts, key=lambda t: t.first_frame)
        assert first.last_frame < second.first_frame
    partial = confused = 0
    for key, parts in by_player.items():
        jersey = key.split("#")[1]
        reads = [r.text for t in parts for r in t.jersey_reads]
        assert Counter(reads).most_common(1)[0][0] == jersey and len(reads) > 50
        wrong = [r for r in reads if r != jersey]
        partial += sum(len(r) < len(jersey) for r in wrong)
        confused += sum(len(r) == len(jersey) for r in wrong)
    assert partial and confused
    clean, clean_truth = generate_synthetic_game(seed=7, duration_s=120.0, ocr_noise=0.0)
    jerseys = {tid: key.split("#")[1] for tid, key in clean_truth.track_players.items()}
    assert all(r.text == jerseys[t.track_id] for t in clean.tracks for r in t.jersey_reads if t.role == "player")


def test_scripted_plays_defenses_and_alternating_possessions(game):
    tracking, truth = game
    offense = {p["type"] for p in truth.plays if p["category"] == "offense"}
    assert {t.value for t in OFFENSIVE_PLAY_TYPES} - offense == {"off_ball_screen", "cut"}
    zones = {p["zone_shape"] for p in truth.plays if p["type"] == "zone_defense"}
    assert zones == {"2-3", "1-3-1"} and any(p["type"] == "man_defense" for p in truth.plays)
    presses = [p for p in truth.plays if p["type"] == "press"]
    assert presses and {p["press_type"] for p in presses} <= {"man", "zone"}
    assert all(p["side"] in ("scouted", "other") and p["start_t"] <= p["end_t"] for p in truth.plays)
    sides = [p["side"] for p in truth.possessions]
    flips = sum(a != b for a, b in zip(sides, sides[1:], strict=False))
    assert flips >= len(sides) - 1 - 3  # alternate, except around period breaks
    assert truth.possessions[-1]["end_t"] < tracking.video.duration_s


def test_movement_is_plausible(game):
    tracking, _ = game
    fps = tracking.video.fps
    for track in tracking.tracks:
        f = np.array([s.f for s in track.samples])
        xy = np.array([s.court_xy for s in track.samples])
        speed = np.hypot(*np.diff(xy, axis=0).T) / (np.diff(f) / fps)
        assert speed.max() < 30.0, track.track_id  # sprint speed is ~20-25 ft/s
        assert xy[:, 0].min() >= -2 and xy[:, 0].max() <= COURT.length_ft + 2
        assert xy[:, 1].min() >= -2 and xy[:, 1].max() <= COURT.width_ft + 2


def test_rosters_match_the_players():
    rosters = synthetic_rosters("g_demo", seed=11)
    assert rosters[TeamSide.SCOUTED].team_name == "Navy" and len(rosters[TeamSide.OTHER].players) == 8
    _, truth = generate_synthetic_game(seed=11, duration_s=120.0)
    for key in truth.box:
        side, jersey = key.split(":#")
        assert jersey in {p.jersey for p in rosters[TeamSide(side)].players}
    assert all(r.game_id == "g_demo" for r in rosters.values())
