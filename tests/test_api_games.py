"""Games CRUD, pages, health, court landmarks and the JSON error contract."""

from __future__ import annotations

import logging
import shutil
import time

import pytest
from fastapi.testclient import TestClient

from scout import __version__, db, storage
from scout.api import pages
from scout.jobs import queue as job_queue
from scout.main import create_app
from scout.schemas import GameStatus, JobKind, UploadSession
from tests.test_api_support import make_app, write_analysis, write_source_video


@pytest.fixture
def client(auth_headers):
    with TestClient(create_app(), headers=auth_headers) as c:
        yield c


# ---------------------------------------------------------------------------
# Games
# ---------------------------------------------------------------------------


def test_create_list_get(client):
    first = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North"})
    assert first.status_code == 201
    assert first.json()["status"] == GameStatus.DRAFT and first.json()["display_title"] == "Central vs North"
    second = client.post("/api/games", json={"scouted_team": "West", "game_date": "2026-01-09"}).json()
    assert [g["id"] for g in client.get("/api/games").json()] == [second["id"], first.json()["id"]]
    assert client.get(f"/api/games/{second['id']}").json()["game_date"] == "2026-01-09"


def test_validation_errors_are_readable(client):
    r = client.post("/api/games", json={"other_team": "North", "game_date": "someday"})
    assert r.status_code == 422
    error = r.json()["error"]
    assert error["code"] == "VALIDATION_FAILED"
    assert error["detail"].startswith("scouted_team: Field required; game_date: ")
    r = client.post("/api/games", content=b"{not json", headers={"Content-Type": "application/json"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "VALIDATION_FAILED"


def test_patch_changes_only_sent_fields(client, game):
    r = client.patch(f"/api/games/{game.id}", json={"notes": "Watch #3", "title": None, "team_id_map": {"0": "other"}})
    assert r.status_code == 200
    body = r.json()
    assert body["notes"] == "Watch #3" and body["title"] == "" and body["scouted_team"] == "Opponent HS"
    assert body["team_id_map"] == {"0": "other"}
    assert client.patch(f"/api/games/{game.id}", json={"team_id_map": None}).json()["team_id_map"] == {}
    r = client.patch(f"/api/games/{game.id}", json={"scouted_team": None})
    assert r.status_code == 422 and "scouted_team" in r.json()["error"]["detail"]


def test_delete_game_cancels_jobs_and_removes_files(client, game, monkeypatch):
    write_source_video(game.id)
    job = db.create_job(game.id, JobKind.ANALYZE)
    upload = db.save_upload(UploadSession(game_id=game.id, filename="a.mp4", size=10, chunk_size=10))
    storage.upload_part_path(upload.id).write_bytes(b"12345")
    cancelled = []
    real_cancel = db.request_cancel
    monkeypatch.setattr(db, "request_cancel", lambda job_id: cancelled.append(job_id) or real_cancel(job_id))

    assert client.delete(f"/api/games/{game.id}").status_code == 204
    assert cancelled == [job.id]
    assert client.get(f"/api/games/{game.id}").status_code == 404
    assert not storage.game_dir(game.id).exists()
    assert not storage.upload_part_path(upload.id).exists()
    assert db.get_job(job.id) is None and db.get_upload(upload.id) is None


def test_analysis_route(client, game, monkeypatch):
    r = client.get(f"/api/games/{game.id}/analysis")
    assert r.status_code == 409 and r.json()["error"]["code"] == "ANALYSIS_NOT_READY"
    write_analysis(game, monkeypatch)
    r = client.get(f"/api/games/{game.id}/analysis")
    assert r.status_code == 200
    assert r.json()["game_id"] == game.id and r.json()["track_assignments"][0]["track_id"] == 7


# ---------------------------------------------------------------------------
# Error contract
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("path", "code"),
    [
        ("/api/games/G_ABC", "NOT_FOUND"),
        ("/api/games/g_not-hex", "NOT_FOUND"),
        ("/api/games/g_123abc", "NOT_FOUND"),  # well formed, but no such game
        ("/api/jobs/x_1", "NOT_FOUND"),
        ("/api/uploads/u_zz", "UPLOAD_NOT_FOUND"),
        ("/api/reports/r_..", "NOT_FOUND"),
        ("/api/no/such/route", "NOT_FOUND"),
    ],
)
def test_bad_ids_and_unknown_routes_are_json_404s(client, path, code):
    r = client.get(path)
    assert r.status_code == 404
    assert r.json()["error"]["code"] == code


def test_wrong_method_is_json(client):
    r = client.put("/api/games")
    assert r.status_code == 405 and "error" in r.json()


def test_unexpected_errors_hide_details(auth_headers, monkeypatch, caplog):
    def explode():
        raise RuntimeError("secret internals")

    monkeypatch.setattr(db, "list_games", explode)
    with caplog.at_level(logging.ERROR), TestClient(create_app(), headers=auth_headers, raise_server_exceptions=False) as c:
        r = c.get("/api/games")
    assert r.status_code == 500
    assert r.json()["error"]["code"] == "INTERNAL_ERROR"
    assert "secret internals" not in r.text
    assert "secret internals" in caplog.text  # the traceback is logged on the server


# ---------------------------------------------------------------------------
# Pages and static files
# ---------------------------------------------------------------------------


def test_pages_and_static_files(auth_headers, monkeypatch, tmp_path):
    for name in ("index.html", "upload.html", "game.html", "roster.html"):
        (tmp_path / name).write_text(f"<html>{name}</html>")
    (tmp_path / "js").mkdir()
    (tmp_path / "js" / "app.js").write_text("console.log('hi');")
    monkeypatch.setattr(pages, "STATIC_DIR", tmp_path)
    with TestClient(create_app(), headers=auth_headers) as c:
        for path, name in [("/", "index"), ("/upload", "upload"), ("/games/g_unknown1", "game"), ("/games/x/roster", "roster")]:
            r = c.get(path)
            assert r.status_code == 200 and f"{name}.html" in r.text, path
            assert r.headers["content-type"].startswith("text/html")
            assert r.headers["cache-control"] == "no-cache"
        r = c.get("/static/js/app.js")
        assert r.status_code == 200 and r.headers["cache-control"] == "no-cache"
        assert c.get("/static/js/missing.js").json()["error"]["code"] == "NOT_FOUND"
        (tmp_path / "game.html").unlink()
        r = c.get("/games/g_123")
        assert r.status_code == 503 and "not installed" in r.text


# ---------------------------------------------------------------------------
# Health and court geometry
# ---------------------------------------------------------------------------


def test_health_reports_components(client):
    body = client.get("/api/health").json()
    assert body["version"] == __version__ and body["processor"] == "mock" and body["queue_backend"] == "sqlite"
    assert body["queue_ok"] is True and body["auth_enabled"] is True and body["claude_configured"] is False
    assert body["ffmpeg_available"] == (shutil.which("ffmpeg") is not None)
    assert body["status"] == "degraded" and body["worker_last_seen_s"] is None  # no worker yet

    db.record_worker_heartbeat("w1")
    body = client.get("/api/health").json()
    assert body["status"] == "ok" and 0 <= body["worker_last_seen_s"] < 5


def test_health_degraded_for_stale_worker_or_missing_modal(auth_headers, monkeypatch):
    with db.session() as conn:
        conn.execute("INSERT INTO worker_heartbeats(worker_id, seen_at) VALUES ('old', ?)", (time.time() - 600,))
    with TestClient(create_app(), headers=auth_headers) as c:
        assert c.get("/api/health").json()["status"] == "degraded"
    db.record_worker_heartbeat("w1")
    with TestClient(make_app(monkeypatch, SCOUT_PROCESSOR="modal"), headers=auth_headers) as c:
        body = c.get("/api/health").json()
    assert body["status"] == "degraded" and body["modal_configured"] is False


def test_health_degraded_when_queue_down(client, monkeypatch):
    class DownQueue:
        def ping(self) -> bool:
            raise ConnectionError("redis is down")

    db.record_worker_heartbeat("w1")
    monkeypatch.setattr(job_queue, "get_queue", lambda settings=None: DownQueue())
    body = client.get("/api/health").json()
    assert body["queue_ok"] is False and body["status"] == "degraded"


def test_court_landmarks(client):
    body = client.get("/api/court/landmarks").json()
    assert body["court"]["length_ft"] == 84.0 and body["court"]["width_ft"] == 50.0
    assert body["landmarks"]["center"] == [42.0, 25.0]
    assert body["landmarks"]["right_ft_line_near"] == [65.0, 19.0]


def test_app_does_no_disk_work_until_startup(auth_headers, monkeypatch, tmp_path):
    data_dir = tmp_path / "fresh-data"
    app = make_app(monkeypatch, SCOUT_DATA_DIR=str(data_dir))
    assert not data_dir.exists()
    with TestClient(app, headers=auth_headers) as c:
        assert data_dir.is_dir() and (data_dir / "scout.db").is_file()
        assert c.get("/api/games").json() == []
