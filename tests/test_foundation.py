"""Tests for the shared foundation: geometry, tracking index, db, SQLite queue."""

from __future__ import annotations

import math
import time

import pytest

from scout import db
from scout.analysis import geometry
from scout.analysis.tracking_index import TrackingIndex
from scout.errors import ErrorCode, ScoutError
from scout.jobs.queue import SQLiteJobQueue, submit_job
from scout.schemas import GameUpdate, JobKind, JobStatus, Roster, RosterPlayer, ShotZone, TeamSide, TrackOverride
from tests import helpers

CFG = geometry.CourtConfig()


@pytest.mark.parametrize(
    ("xy", "zone", "sub"),
    [
        ((5.25, 25.0), ShotZone.PAINT, "restricted_area"),
        ((15.0, 30.0), ShotZone.PAINT, "paint"),
        ((2.0, 3.0), ShotZone.THREE, "left_corner_3"),
        ((2.0, 47.0), ShotZone.THREE, "right_corner_3"),
        ((25.5, 25.0), ShotZone.THREE, "top_3"),
        ((22.0, 20.0), ShotZone.MID, "top_mid"),
        ((3.0, 10.0), ShotZone.MID, "left_baseline_mid"),
        ((80.0, 47.0), ShotZone.THREE, "left_corner_3"),  # right basket: far sideline is the offense's left
        ((58.0, 25.0), ShotZone.THREE, "top_3"),
    ],
)
def test_classify_shot(xy, zone, sub):
    assert geometry.classify_shot(CFG, xy) == (zone, sub)


def test_three_point_boundaries():
    # Exactly 19'9" from the basket on the arc is a two; just beyond is a three.
    bx, by = CFG.basket("left")
    assert not geometry.is_three(CFG, (bx + 19.7, by))
    assert geometry.is_three(CFG, (bx + 19.8, by))
    # Corner: straight segment at 19.75 ft lateral.
    assert geometry.is_three(CFG, (1.0, by - 19.9))
    assert not geometry.is_three(CFG, (1.0, by - 19.5))
    # Beyond half court is always a three (heave).
    assert geometry.classify_shot(CFG, (50.0, 25.0), basket="left") == (ShotZone.THREE, "backcourt_3")


def test_half_court_normalisation():
    assert geometry.to_half_court(CFG, (10.0, 5.0)) == (10.0, 5.0)
    assert geometry.to_half_court(CFG, (74.0, 5.0)) == (10.0, 45.0)


def test_homography_roundtrip_and_degenerate():
    src = [(100.0, 900.0), (1800.0, 880.0), (1500.0, 300.0), (400.0, 310.0), (950.0, 500.0)]
    true_h = [[0.05, 0.01, -3.0], [0.002, -0.08, 75.0], [0.00001, 0.0002, 1.0]]
    dst = [geometry.apply_homography(true_h, p) for p in src]
    h, err = geometry.compute_homography(src, dst)
    assert err < 1e-6
    for p, q in zip(src, dst, strict=True):
        got = geometry.apply_homography(h, p)
        assert math.isclose(got[0], q[0], abs_tol=1e-6) and math.isclose(got[1], q[1], abs_tol=1e-6)
    with pytest.raises(ValueError):
        geometry.compute_homography([(0, 0), (1, 1), (2, 2), (3, 3)], [(0, 0), (1, 1), (2, 2), (3, 3)])
    with pytest.raises(ValueError):
        geometry.compute_homography([(0, 0), (1, 1), (2, 0)], [(0, 0), (1, 1), (2, 0)])


def test_landmarks_mirror():
    lm = geometry.landmarks(CFG)
    assert lm["left_ft_line_near"] == (19.0, 19.0)
    assert lm["right_ft_line_near"] == (65.0, 19.0)
    assert lm["center"] == (42.0, 25.0)


def test_tracking_index_interpolation_and_holders():
    t = helpers.tracking(
        [
            helpers.track(1, 0, [(0, 10.0, 10.0), (3, 13.0, 10.0), (6, 16.0, 10.0)], jersey="3"),
            helpers.track(2, 1, [(0, 30.0, 30.0), (3, 30.0, 33.0), (6, 30.0, 36.0)], jersey="12"),
        ],
        balls=helpers.ball([(0, 10.0, 10.0, 1), (3, 13.0, 10.0, 1), (6, 30.0, 36.0, 2), (9, 30.0, 36.0, 2)]),
    )
    idx = TrackingIndex(t, CFG)
    assert idx.coord_mode == "court"
    assert idx.step == 3
    assert idx.position(1, 1) == pytest.approx((11.0, 10.0))
    assert idx.position(1, 100) is None
    assert idx.speed(1, 3, window_s=0.2) == pytest.approx(30.0)  # 3 ft per 3 frames at 30 fps
    assert idx.distance_ft(1, 2, 0) == pytest.approx(math.hypot(20, 20))
    assert idx.holder_at(4) == 1
    segs = idx.holder_segments()
    assert [(s.track_id, s.start_frame, s.end_frame) for s in segs] == [(1, 0, 3), (2, 6, 9)]


def test_tracking_index_pixel_mode_scale():
    t = helpers.tracking(
        [helpers.track(1, 0, [(0, 500.0, 800.0), (3, 520.0, 800.0)], court=False)], homography=False
    )
    idx = TrackingIndex(t, CFG)
    assert idx.coord_mode == "pixel"
    assert idx.scale_ft(1, 0) == pytest.approx(6.0 / 120.0)


def test_game_crud(game):
    assert db.get_game(game.id).scouted_team == "Opponent HS"
    updated = db.update_game(game.id, **GameUpdate(notes="watch #3").model_dump(exclude_unset=True))
    assert updated.notes == "watch #3"
    assert updated.updated_at >= game.updated_at
    assert [g.id for g in db.list_games()] == [game.id]
    with pytest.raises(ScoutError) as exc:
        db.update_game("g_missing", notes="x")
    assert exc.value.code == ErrorCode.NOT_FOUND
    assert db.delete_game(game.id)
    assert db.get_game(game.id) is None


def test_job_claim_lease_and_cancel(game):
    queue = SQLiteJobQueue(poll_interval=0.05)
    job = submit_job(game.id, JobKind.ANALYZE, {"x": 1}, queue=queue)
    assert job.status == JobStatus.QUEUED and job.processor == "mock"
    claimed = queue.claim("w1", timeout=0.2)
    assert claimed and claimed.id == job.id and claimed.status == JobStatus.RUNNING and claimed.attempts == 1
    assert queue.claim("w2", timeout=0.1) is None  # leased
    db.update_job(job.id, lease_expires_at=time.time() - 1, external_id="fc-123")
    reclaimed = queue.claim("w2", timeout=0.1)
    assert reclaimed.id == job.id and reclaimed.worker_id == "w2" and reclaimed.attempts == 2
    assert reclaimed.external_id == "fc-123"
    assert not db.heartbeat_job(job.id, "w1", 60)
    assert db.heartbeat_job(job.id, "w2", 60)
    assert db.request_cancel(job.id).cancel_requested
    queued = submit_job(game.id, JobKind.REPORT, queue=queue)
    assert db.request_cancel(queued.id).status == JobStatus.CANCELLED


def test_rosters_overrides_reports(game):
    empty = db.get_roster(game.id, TeamSide.SCOUTED)
    assert empty.team_name == "Opponent HS" and empty.players == []
    saved = db.save_roster(Roster(game_id=game.id, side=TeamSide.SCOUTED, players=[RosterPlayer(jersey="00", first_name="A", last_name="B")]))
    assert db.get_rosters(game.id)[TeamSide.SCOUTED].players[0].jersey == "00"
    assert saved.updated_at is not None
    db.set_track_override(game.id, TrackOverride(track_id=4, player_id=saved.players[0].id))
    assert db.list_track_overrides(game.id)[0].track_id == 4
    assert db.delete_track_override(game.id, 4)
    assert db.last_worker_heartbeat() is None
    db.record_worker_heartbeat("w1", {"pid": 1})
    assert db.last_worker_heartbeat() is not None
