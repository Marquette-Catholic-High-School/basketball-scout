"""Checking the shots: a second opinion picks the shots to look at, and the coach's call decides."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from scout import config, db
from scout.analysis import pipeline, shot_check, synthetic
from scout.schemas import BallSample, RawEvent, RawEventType, RimInfo, TrackingResult
from scout.worker import Worker
from tests import helpers

RIM = (900.0, 300.0)


def _shot_film(made: bool | None, ball_goes_through: bool, *, rim: bool = True) -> TrackingResult:
    """One player (120 px tall: rim half-width 15 px), one shot at frame 30, the ball arcing to the rim."""
    player = helpers.track(1, 0, [(f, 10, 10) for f in range(0, 120, 3)])
    player = player.model_copy(update={"samples": [s.model_copy(update={"bbox": (800.0, 400.0, 840.0, 520.0)}) for s in player.samples]})
    rx, ry = RIM
    arc = [(30, rx - 200, ry - 150), (36, rx - 100, ry - 120), (42, rx - 20, ry - 40)]
    arc += [(48, rx + 2, ry + 30), (54, rx + 5, ry + 70)] if ball_goes_through else [(48, rx + 90, ry - 20), (54, rx + 150, ry + 60)]
    ball = [BallSample(f=f, xy=(x, y)) for f, x, y in arc]
    shot = RawEvent(event_id="e1", type=RawEventType.SHOT, frame=30, t=1.0, track_id=1, team_id=0,
                    attrs={"made": made, "end_frame": 45, "shot_court_xy": [10.0, 25.0]})
    rims = [RimInfo(side="left", xy_px=RIM, frame_start=0, frame_end=200)] if rim else []
    return helpers.tracking([player], events=[shot], duration_s=10).model_copy(update={"ball": ball, "rims": rims})


@pytest.mark.parametrize(
    ("made", "through", "rim", "reason"),
    [
        (True, True, True, None),
        (False, False, True, None),
        (True, False, True, shot_check.REASON_DISAGREE_MADE),
        (False, True, True, shot_check.REASON_DISAGREE_MISSED),
        (None, True, True, shot_check.REASON_UNKNOWN),
        (True, True, False, shot_check.REASON_NO_VIEW),
    ],
)
def test_the_second_check_flags_only_the_shots_it_disagrees_on(made, through, rim, reason):
    check = shot_check.check_shots(_shot_film(made, through, rim=rim))["e1"]
    assert check.reason == reason
    if rim:
        assert check.through is through


def test_the_coach_s_call_decides_and_takes_the_shot_off_the_list(game):
    film = _shot_film(False, True)
    rosters = {side: synthetic.synthetic_rosters(game.id, seed=1)[side].model_copy(update={"players": []}) for side in synthetic.synthetic_rosters(game.id, seed=1)}
    before = pipeline.analyze_game(film, game, rosters, [])
    shot = before.shots[0]
    assert (shot.made, shot.gpu_made, shot.coach_made, shot.needs_review) == (False, False, None, True)
    assert shot.review_reason == shot_check.REASON_DISAGREE_MISSED
    called = pipeline.analyze_game(film, game.model_copy(update={"shot_calls": {"e1": True}}), rosters, [])
    shot = called.shots[0]
    assert (shot.made, shot.points, shot.gpu_made, shot.coach_made, shot.needs_review) == (True, 2, False, True, False)
    assert sum(b.totals.pts for b in called.box_scores) == 2


@pytest.fixture
def client(auth_headers, monkeypatch):
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    config.reset_settings()
    from scout.main import create_app

    with TestClient(create_app()) as test_client:
        test_client.headers.update(auth_headers)
        yield test_client


def test_calls_are_saved_undone_and_checked(client):
    game_id = client.post("/api/games", json={"scouted_team": "A", "other_team": "B", "scouted_color": "dark"}).json()["id"]
    data = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 12 + b"\x11" * 4000
    upload = client.post(f"/api/games/{game_id}/uploads", json={"filename": "g.mp4", "size": len(data)}).json()
    client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=data)
    client.post(f"/api/uploads/{upload['id']}/complete")
    assert Worker(worker_id="t").run_once(timeout=2)
    shots = client.get(f"/api/games/{game_id}/analysis").json()["shots"]
    target = next(s for s in shots if not s["made"])
    r = client.put(f"/api/games/{game_id}/shots/{target['event_id']}", json={"made": True})
    assert r.status_code == 200 and r.json()["shot_calls"] == {target["event_id"]: True}
    assert client.put(f"/api/games/{game_id}/shots/nope", json={"made": True}).status_code == 404
    assert client.put(f"/api/games/{game_id}/shots/{target['event_id']}", json={"made": "yes"}).status_code == 422
    job = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json()
    assert Worker(worker_id="t").run_once(timeout=2)
    assert db.get_job(job["id"]).status == "succeeded"
    after = {s["event_id"]: s for s in client.get(f"/api/games/{game_id}/analysis").json()["shots"]}
    assert after[target["event_id"]]["made"] is True and after[target["event_id"]]["coach_made"] is True
    assert client.delete(f"/api/games/{game_id}/shots/{target['event_id']}").json()["shot_calls"] == {}
