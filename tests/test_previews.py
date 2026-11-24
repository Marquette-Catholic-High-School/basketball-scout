"""Pictures of tracked players, cut from the film (scout/analysis/previews.py)."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from scout import config, db, storage
from scout.analysis import previews, synthetic
from scout.schemas import Track, TrackSample
from scout.worker import Worker
from tests import helpers

_STAND_IN_FFMPEG = """#!/bin/sh
# Stands in for ffmpeg: writes its arguments as the "picture" (the last argument is the output file).
for arg in "$@"; do out="$arg"; done
[ -n "$FAIL" ] && { echo "stand-in: asked to fail" >&2; exit 1; }
printf 'JPEG %s\\n' "$*" > "$out"
"""


def _fake_mp4(size: int = 4096) -> bytes:
    head = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 12
    return head + b"\x11" * (size - len(head))


def test_the_best_moments_are_large_whole_and_spread_over_the_track():
    def sample(f, x1, y1, x2, y2, conf=0.9):
        return TrackSample(f=f, bbox=(x1, y1, x2, y2), conf=conf)

    track = Track(track_id=7, team_id=0, samples=[
        sample(0, 100, 100, 140, 200),      # first third: small
        sample(30, 100, 100, 180, 300),     # first third: the largest there
        sample(300, 0, 100, 400, 900),      # second third: huge but cut off by the picture's edge
        sample(330, 500, 100, 620, 420),    # second third: whole
        sample(600, 800, 200, 860, 380),    # last third
    ])
    views = previews.choose_views(helpers.tracking([track], duration_s=30))[7]
    assert [v.frame for v in views] == [300, 330, 30] or [v.frame for v in views][0] in (300, 330)
    assert {v.frame for v in views} <= {30, 300, 330, 600} and len(views) == 3
    assert previews.choose_views(helpers.tracking([Track(track_id=1, team_id=0, samples=[sample(5, 10, 10, 50, 90)])]))[1][0].frame == 5


def test_the_picture_is_cropped_with_room_around_the_player_and_stays_inside_the_frame():
    assert previews.crop_filter((100, 100, 200, 300), 1920, 1080, 120) == "crop=170:248:65:76,scale=-2:120"
    assert previews.crop_filter((0, 0, 60, 200), 1920, 1080, 360).startswith("crop=80:224:0:0,")
    edge = previews.crop_filter((1880, 900, 1920, 1080), 1920, 1080, 120)
    w, h, x, y = (int(v) for v in edge.split(",")[0].removeprefix("crop=").split(":"))
    assert x + w <= 1920 and y + h <= 1080 and w % 2 == 0 and h % 2 == 0


@pytest.fixture
def client(auth_headers, monkeypatch):
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    config.reset_settings()
    from scout.main import create_app

    with TestClient(create_app()) as test_client:
        test_client.headers.update(auth_headers)
        yield test_client


def _analysed_game(client) -> tuple[str, int]:
    game_id = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North", "scouted_color": "dark"}).json()["id"]
    data = _fake_mp4()
    upload = client.post(f"/api/games/{game_id}/uploads", json={"filename": "game.mp4", "size": len(data)}).json()
    client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=data)
    assert client.post(f"/api/uploads/{upload['id']}/complete").status_code == 200
    assert Worker(worker_id="test-worker").run_once(timeout=2)
    tracks = client.get(f"/api/games/{game_id}/tracks").json()["assignments"]
    return game_id, max(tracks, key=lambda a: a["frames"])["track_id"]


@pytest.fixture
def ffmpeg(monkeypatch, tmp_path):
    stand_in = tmp_path / "ffmpeg"
    stand_in.write_text(_STAND_IN_FFMPEG)
    stand_in.chmod(0o755)
    monkeypatch.setattr(previews.shutil, "which", lambda name: str(stand_in) if name == "ffmpeg" else None)
    return stand_in


def test_a_picture_is_cut_once_and_then_served_from_the_game_folder(client, ffmpeg):
    game_id, track_id = _analysed_game(client)
    r = client.get(f"/api/games/{game_id}/tracks/{track_id}/preview.jpg")
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"
    assert "private" in r.headers["cache-control"]
    command = r.text
    assert " -ss " in command and "source.mp4" in command and "scale=-2:120" in command and "-frames:v 1" in command
    saved = storage.previews_dir(game_id) / f"{track_id}-0-small.jpg"
    assert saved.is_file()
    ffmpeg.write_text("#!/bin/sh\nexit 1\n")  # a second request does not need ffmpeg any more
    assert client.get(f"/api/games/{game_id}/tracks/{track_id}/preview.jpg").text == command
    large = client.get(f"/api/games/{game_id}/tracks/{track_id}/preview.jpg", params={"size": "large", "view": 0})
    assert large.status_code == 404  # ffmpeg now fails: a clear error, no half-written file
    assert sorted(p.name for p in storage.previews_dir(game_id).iterdir()) == [f"{track_id}-0-small.jpg", "index.json"]


def test_views_past_the_last_and_unknown_tracks_are_not_found(client, ffmpeg):
    game_id, track_id = _analysed_game(client)
    views = previews.load_index(game_id)["views"][str(track_id)]
    assert 1 <= len(views) <= 3
    assert client.get(f"/api/games/{game_id}/tracks/{track_id}/preview.jpg", params={"view": len(views) - 1, "size": "large"}).status_code == 200
    assert client.get(f"/api/games/{game_id}/tracks/{track_id}/preview.jpg", params={"view": len(views)}).status_code == 404
    assert client.get(f"/api/games/{game_id}/tracks/987654321/preview.jpg").status_code == 404
    assert client.get(f"/api/games/{game_id}/tracks/{track_id}/preview.jpg", params={"size": "huge"}).status_code == 422


def test_no_picture_without_ffmpeg_a_film_or_an_analysis(client, monkeypatch):
    game_id, track_id = _analysed_game(client)
    monkeypatch.setattr(previews.shutil, "which", lambda name: None)
    r = client.get(f"/api/games/{game_id}/tracks/{track_id}/preview.jpg")
    assert r.status_code == 404 and "ffmpeg" in r.json()["error"]["message"]
    storage.find_source_video(game_id).unlink()
    r = client.get(f"/api/games/{game_id}/tracks/{track_id}/preview.jpg")
    assert r.status_code == 404 and "not stored on this server" in r.json()["error"]["message"]
    empty = client.post("/api/games", json={"scouted_team": "A"}).json()["id"]
    assert client.get(f"/api/games/{empty}/tracks/1/preview.jpg").status_code == 404


def test_a_new_analysis_drops_the_old_pictures(client, ffmpeg):
    game_id, track_id = _analysed_game(client)
    assert client.get(f"/api/games/{game_id}/tracks/{track_id}/preview.jpg").status_code == 200
    old = storage.previews_dir(game_id) / f"{track_id}-0-small.jpg"
    assert old.is_file()
    tracking, _ = synthetic.generate_synthetic_game(seed=99, duration_s=60)
    storage.write_json(storage.tracking_path(game_id), tracking.model_dump_json())  # as a Full re-analysis installs
    index = previews.load_index(game_id)
    assert not old.exists() and set(index["views"]) == {str(t.track_id) for t in tracking.tracks if t.samples}
    assert db.get_game(game_id) is not None
