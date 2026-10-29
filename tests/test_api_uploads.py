"""Chunked, resumable film uploads and video links."""

from __future__ import annotations

import subprocess
from collections.abc import Iterator
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from scout import db, storage
from scout.api import uploads
from scout.schemas import GameStatus, JobKind, JobStatus, TrackOverride
from tests.test_api_support import fake_mp4, make_app, write_source_video

MB = 1024 * 1024
OCTETS = {"Content-Type": "application/octet-stream"}


@pytest.fixture
def client(auth_headers, monkeypatch):
    """1 MB chunks so a multi-chunk upload stays small."""
    with TestClient(make_app(monkeypatch, SCOUT_UPLOAD_CHUNK_MB="1"), headers=auth_headers) as c:
        yield c


def start_upload(client: TestClient, game_id: str, size: int, filename: str = "vs-central.mp4") -> dict:
    r = client.post(f"/api/games/{game_id}/uploads", json={"filename": filename, "size": size})
    assert r.status_code == 201, r.text
    return r.json()


def put_chunk(client: TestClient, upload_id: str, offset: int, data: bytes):
    return client.put(f"/api/uploads/{upload_id}/chunk", params={"offset": offset}, content=data, headers=OCTETS)


def upload_all(client: TestClient, game_id: str, data: bytes, filename: str = "vs-central.mp4") -> dict:
    upload = start_upload(client, game_id, len(data), filename)
    for offset in range(0, len(data), upload["chunk_size"]):
        assert put_chunk(client, upload["id"], offset, data[offset : offset + upload["chunk_size"]]).status_code == 200
    return upload


def test_chunked_upload_with_resume_after_conflict(client, game):
    data = fake_mp4(2 * MB + 12345)
    upload = start_upload(client, game.id, len(data))
    assert upload["chunk_size"] == MB and upload["received"] == 0 and upload["status"] == "open"
    assert storage.upload_part_path(upload["id"]).read_bytes() == b""

    assert put_chunk(client, upload["id"], 0, data[:MB]).json()["received"] == MB
    # The browser lost the response and resends the first chunk: 409 tells it where to resume.
    r = put_chunk(client, upload["id"], 0, data[:MB])
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "CONFLICT" and r.json()["upload"]["received"] == MB
    resume_at = client.get(f"/api/uploads/{upload['id']}").json()["received"]
    for offset in range(resume_at, len(data), MB):
        assert put_chunk(client, upload["id"], offset, data[offset : offset + MB]).status_code == 200

    r = client.post(f"/api/uploads/{upload['id']}/complete")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["job"]["kind"] == JobKind.ANALYZE and body["job"]["status"] == JobStatus.QUEUED
    assert body["game"]["status"] == GameStatus.QUEUED and body["game"]["latest_job_id"] == body["job"]["id"]
    assert body["game"]["has_video"] and body["game"]["video_filename"] == "vs-central.mp4"
    assert body["game"]["video_size"] == len(data)
    assert storage.find_source_video(game.id).read_bytes() == data
    assert not storage.upload_part_path(upload["id"]).exists()
    assert client.get(f"/api/uploads/{upload['id']}").json()["status"] == "complete"

    again = client.post(f"/api/uploads/{upload['id']}/complete")  # retried complete: same answer
    assert again.status_code == 200 and again.json()["job"]["id"] == body["job"]["id"]


def test_complete_without_auto_start(client, game):
    upload = upload_all(client, game.id, fake_mp4(5000), filename="C:\\fakepath\\Film.MOV")
    assert upload["filename"] == "Film.MOV"
    body = client.post(f"/api/uploads/{upload['id']}/complete", params={"auto_start": "false"}).json()
    assert body["job"] is None and body["game"]["status"] == GameStatus.UPLOADED
    assert storage.find_source_video(game.id).name == "source.mov"
    assert db.list_jobs(game_id=game.id) == []


def test_new_film_replaces_old_film_and_results(client, game):
    write_source_video(game.id, suffix=".mov")
    for path in (storage.tracking_path(game.id), storage.analysis_path(game.id), storage.annotated_video_path(game.id)):
        path.write_bytes(b"old")
    db.set_track_override(game.id, TrackOverride(track_id=3, ignore=True))
    db.update_game(game.id, has_analysis=True, has_annotated_video=True, status=GameStatus.READY)

    upload = upload_all(client, game.id, fake_mp4(3000))
    game_json = client.post(f"/api/uploads/{upload['id']}/complete", params={"auto_start": "false"}).json()["game"]
    assert sorted(p.name for p in storage.game_dir(game.id).iterdir()) == ["source.mp4"]
    assert db.list_track_overrides(game.id) == []
    assert not game_json["has_analysis"] and not game_json["has_annotated_video"] and game_json["error"] is None


def test_upload_init_rejections(client, game, monkeypatch):
    r = client.post(f"/api/games/{game.id}/uploads", json={"filename": "notes.pdf", "size": 10})
    assert r.status_code == 422 and r.json()["error"]["code"] == "VIDEO_INVALID"
    r = client.post(f"/api/games/{game.id}/uploads", json={"filename": "a.mp4", "size": 0})
    assert r.status_code == 422 and r.json()["error"]["code"] == "VALIDATION_FAILED"
    r = client.post(f"/api/games/{game.id}/uploads", json={"filename": "a.mp4", "size": 13 * 1024**3})
    assert r.status_code == 413 and r.json()["error"]["code"] == "UPLOAD_TOO_LARGE"
    assert client.post("/api/games/g_000000/uploads", json={"filename": "a.mp4", "size": 10}).status_code == 404

    monkeypatch.setattr(uploads.shutil, "disk_usage", lambda path: SimpleNamespace(free=500 * MB))
    r = client.post(f"/api/games/{game.id}/uploads", json={"filename": "a.mp4", "size": 10 * MB})
    assert r.status_code == 413 and "free disk space" in r.json()["error"]["message"]


def test_chunk_size_limits(client, game):
    data = fake_mp4(3 * MB)
    upload = start_upload(client, game.id, len(data))
    r = put_chunk(client, upload["id"], 0, data[: 2 * MB + 1])
    assert r.status_code == 413 and "at most" in r.json()["error"]["message"]
    assert put_chunk(client, upload["id"], 0, data[:MB]).status_code == 200
    r = put_chunk(client, upload["id"], MB, data[MB:] + b"extra")
    assert r.status_code == 413 and "past the end" in r.json()["error"]["message"]
    assert client.get(f"/api/uploads/{upload['id']}").json()["received"] == MB
    assert storage.upload_part_path(upload["id"]).stat().st_size == MB


def test_streamed_chunk_without_content_length_is_still_limited(client, game):
    upload = start_upload(client, game.id, 3 * MB)

    def body() -> Iterator[bytes]:
        for _ in range(3):
            yield b"\x01" * MB

    r = client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=body(), headers=OCTETS)
    assert r.status_code == 413
    assert storage.upload_part_path(upload["id"]).stat().st_size == 0  # cut back to the offset


def test_complete_requires_all_bytes(client, game):
    data = fake_mp4(4000)
    upload = start_upload(client, game.id, len(data))
    put_chunk(client, upload["id"], 0, data[:1000])
    r = client.post(f"/api/uploads/{upload['id']}/complete")
    assert r.status_code == 409 and r.json()["error"]["code"] == "UPLOAD_INCOMPLETE"


def test_complete_rejects_files_that_are_not_video(client, game):
    upload = upload_all(client, game.id, b"%PDF-1.7 definitely not a video" * 10)
    r = client.post(f"/api/uploads/{upload['id']}/complete")
    assert r.status_code == 422 and r.json()["error"]["code"] == "VIDEO_INVALID"
    assert not storage.upload_part_path(upload["id"]).exists()
    assert client.get(f"/api/uploads/{upload['id']}").json()["status"] == "aborted"
    assert put_chunk(client, upload["id"], 0, b"x").status_code == 409
    assert db.get_game(game.id).has_video is False


def test_too_long_film_is_rejected_when_ffprobe_exists(client, game, monkeypatch):
    monkeypatch.setattr(uploads, "probe_duration_s", lambda path: 151 * 60.0)
    upload = upload_all(client, game.id, fake_mp4(3000))
    r = client.post(f"/api/uploads/{upload['id']}/complete")
    assert r.status_code == 422 and r.json()["error"]["code"] == "VIDEO_TOO_LONG"
    assert not storage.upload_part_path(upload["id"]).exists()


def test_probe_duration(monkeypatch, tmp_path):
    monkeypatch.setattr(uploads.shutil, "which", lambda name: None)
    assert uploads.probe_duration_s(tmp_path / "x.mp4") is None
    monkeypatch.setattr(uploads.shutil, "which", lambda name: "/usr/bin/ffprobe")
    monkeypatch.setattr(uploads.subprocess, "run", lambda *a, **k: SimpleNamespace(stdout="5400.25\n"))
    assert uploads.probe_duration_s(tmp_path / "x.mp4") == 5400.25

    def fail(*args, **kwargs):
        raise subprocess.CalledProcessError(1, "ffprobe")

    monkeypatch.setattr(uploads.subprocess, "run", fail)
    assert uploads.probe_duration_s(tmp_path / "x.mp4") is None


def test_film_cannot_change_while_analysis_runs(client, game):
    write_source_video(game.id)
    job = client.post(f"/api/games/{game.id}/jobs", json={"kind": "analyze"}).json()
    r = client.post(f"/api/games/{game.id}/uploads", json={"filename": "a.mp4", "size": 100})
    assert r.status_code == 409 and r.json()["error"]["code"] == "CONFLICT"
    r = client.post(f"/api/games/{game.id}/video-url", json={"url": "https://example.com/film.mp4"})
    assert r.status_code == 409
    client.post(f"/api/jobs/{job['id']}/cancel")
    assert client.post(f"/api/games/{game.id}/uploads", json={"filename": "a.mp4", "size": 100}).status_code == 201


def test_delete_upload_and_missing_part_file(client, game):
    upload = start_upload(client, game.id, 5000)
    assert client.delete(f"/api/uploads/{upload['id']}").status_code == 204
    assert not storage.upload_part_path(upload["id"]).exists()
    r = client.get(f"/api/uploads/{upload['id']}")
    assert r.status_code == 404 and r.json()["error"]["code"] == "UPLOAD_NOT_FOUND"
    assert client.delete(f"/api/uploads/{upload['id']}").status_code == 404

    other = start_upload(client, game.id, 5000)
    storage.upload_part_path(other["id"]).unlink()  # e.g. someone cleaned data/uploads
    r = put_chunk(client, other["id"], 0, b"abc")
    assert r.status_code == 404 and r.json()["error"]["code"] == "UPLOAD_NOT_FOUND"
    assert client.get(f"/api/uploads/{other['id']}").json()["status"] == "aborted"


def test_video_url(client, game):
    r = client.post(f"/api/games/{game.id}/video-url", json={"url": "https://films.example.com/2026/vs%20north.mp4?sig=1"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["game"]["video_url"].startswith("https://films.example.com/")
    assert body["game"]["video_filename"] == "vs north.mp4" and body["game"]["has_video"] is False
    assert body["job"]["kind"] == JobKind.ANALYZE and body["game"]["status"] == GameStatus.QUEUED

    other = client.post("/api/games", json={"scouted_team": "B"}).json()
    r = client.post(
        f"/api/games/{other['id']}/video-url",
        params={"auto_start": "false"},
        json={"url": "http://192.168.1.20/film", "filename": "Game 3.mp4"},
    )
    assert r.json()["job"] is None and r.json()["game"]["video_filename"] == "Game 3.mp4"
    assert r.json()["game"]["status"] == GameStatus.UPLOADED


@pytest.mark.parametrize("url", ["ftp://example.com/film.mp4", "file:///etc/passwd", "https://", "javascript:alert(1)"])
def test_video_url_must_be_http(client, game, url):
    r = client.post(f"/api/games/{game.id}/video-url", json={"url": url})
    assert r.status_code == 422
    assert db.get_game(game.id).video_url is None
