"""Video playback (HTTP Range) and manual court calibration."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from scout import db, storage
from scout.analysis import geometry
from scout.main import create_app
from tests.test_api_support import write_source_video

# A fixed camera: court feet -> image pixels (perspective, w stays positive on the court).
CAMERA = [[18.0, 4.0, 160.0], [0.6, -11.0, 900.0], [0.0001, 0.0035, 1.0]]


@pytest.fixture
def client(auth_headers):
    with TestClient(create_app(), headers=auth_headers) as c:
        yield c


def pixel(landmark: str) -> list[float]:
    """Where a court landmark appears in the synthetic camera's image."""
    court = geometry.landmarks(geometry.CourtConfig())[landmark]
    return list(geometry.apply_homography(CAMERA, court))


# ---------------------------------------------------------------------------
# Video
# ---------------------------------------------------------------------------


def test_original_video_supports_range_requests(client, game):
    data = bytes(range(256)) * 40
    write_source_video(game.id, data)
    r = client.get(f"/api/games/{game.id}/video")
    assert r.status_code == 200 and r.content == data
    assert r.headers["content-type"] == "video/mp4" and r.headers["accept-ranges"] == "bytes"
    assert "content-disposition" not in r.headers

    r = client.get(f"/api/games/{game.id}/video", headers={"Range": "bytes=100-199"})
    assert r.status_code == 206
    assert r.content == data[100:200]
    assert r.headers["content-range"] == f"bytes 100-199/{len(data)}"

    r = client.get(f"/api/games/{game.id}/video", params={"download": "1"})
    assert r.headers["content-disposition"] == f'attachment; filename="{game.id}_original.mp4"'


def test_mov_film_is_served_as_mp4(client, game):
    write_source_video(game.id, b"\x00\x00\x00\x14ftypqt  " + b"\x00" * 100, suffix=".mov")
    r = client.get(f"/api/games/{game.id}/video")
    assert r.status_code == 200 and r.headers["content-type"] == "video/mp4"


def test_annotated_video(client, game):
    r = client.get(f"/api/games/{game.id}/video", params={"variant": "annotated"})
    assert r.status_code == 404 and "annotated" in r.json()["error"]["message"]
    storage.game_dir(game.id, create=True)
    storage.annotated_video_path(game.id).write_bytes(b"annotated-bytes")
    r = client.get(f"/api/games/{game.id}/video", params={"variant": "annotated"})
    assert r.status_code == 200 and r.content == b"annotated-bytes"


def test_missing_film_messages(client, game):
    r = client.get(f"/api/games/{game.id}/video")
    assert r.status_code == 404 and "No film" in r.json()["error"]["message"]
    db.update_game(game.id, video_url="https://example.com/film.mp4")
    r = client.get(f"/api/games/{game.id}/video")
    assert r.status_code == 404
    error = r.json()["error"]
    assert "link" in error["message"] and "https://example.com/film.mp4" in error["hint"]
    assert client.get(f"/api/games/{game.id}/video", params={"variant": "raw"}).status_code == 422


# ---------------------------------------------------------------------------
# Calibration
# ---------------------------------------------------------------------------


def test_calibration_recovers_the_camera(client, game):
    names = ["left_baseline_near_corner", "left_baseline_far_corner", "midcourt_near", "midcourt_far", "left_ft_line_near", "center"]
    body = {
        "points": [{"landmark": n, "px": pixel(n)} for n in names],
        "frame_t": 12.5,
        "video_width": 1920,
        "video_height": 1080,
    }
    r = client.put(f"/api/games/{game.id}/calibration", json=body)
    assert r.status_code == 200, r.text
    calibration = r.json()
    assert calibration["reprojection_error_ft"] < 1e-3
    assert calibration["frame_t"] == 12.5 and calibration["video_width"] == 1920 and calibration["created_at"]
    # A landmark that was NOT clicked lands where it should on the court.
    court = geometry.apply_homography(calibration["matrix"], pixel("right_three_top"))
    expected = geometry.landmarks(geometry.CourtConfig())["right_three_top"]
    assert court == pytest.approx(expected, abs=1e-3)

    stored = db.get_game(game.id).calibration
    assert stored is not None and stored.matrix == calibration["matrix"]
    assert client.delete(f"/api/games/{game.id}/calibration").status_code == 204
    assert db.get_game(game.id).calibration is None


@pytest.mark.parametrize(
    ("names", "message"),
    [
        (["left_baseline_near_corner", "left_baseline_far_corner", "center"], "at least 4"),
        (["left_baseline_near_corner", "left_baseline_far_corner", "center", "free_throw_somewhere"], "free_throw_somewhere"),
        (["center", "center", "midcourt_near", "midcourt_far"], "once"),
    ],
)
def test_calibration_input_errors(client, game, names, message):
    points = [{"landmark": n, "px": [100.0 * i, 50.0 * i * i]} for i, n in enumerate(names)]
    r = client.put(f"/api/games/{game.id}/calibration", json={"points": points})
    assert r.status_code == 422
    error = r.json()["error"]
    assert error["code"] == "CALIBRATION_INVALID" and message in error["message"]
    assert db.get_game(game.id).calibration is None


def test_calibration_rejects_points_on_one_line(client, game):
    names = ["left_baseline_near_corner", "left_lane_baseline_near", "left_lane_baseline_far", "left_baseline_far_corner"]
    points = [{"landmark": n, "px": [100.0, 100.0 + 50 * i]} for i, n in enumerate(names)]
    r = client.put(f"/api/games/{game.id}/calibration", json={"points": points})
    assert r.status_code == 422 and r.json()["error"]["code"] == "CALIBRATION_INVALID"
    assert r.json()["error"]["detail"]
