"""Job rules: preconditions, one active analysis per game, cancel, retry, queue failures."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from scout import config, db, storage
from scout.errors import ErrorCode, ScoutError
from scout.jobs import queue as job_queue
from scout.main import create_app
from scout.schemas import GameStatus, JobKind, JobStatus
from tests.test_api_support import make_app, write_analysis, write_source_video


@pytest.fixture
def client(auth_headers):
    with TestClient(create_app(), headers=auth_headers) as c:
        yield c


def post_job(client: TestClient, game_id: str, kind: str, **params):
    return client.post(f"/api/games/{game_id}/jobs", json={"kind": kind, "params": params})


def error_code(response) -> str:
    return response.json()["error"]["code"]


def test_analyze_needs_film(client, game):
    r = post_job(client, game.id, "analyze")
    assert r.status_code == 409 and error_code(r) == "VIDEO_MISSING"
    assert db.get_game(game.id).status == GameStatus.DRAFT


def test_analyze_queues_and_marks_game(client, game):
    write_source_video(game.id)
    r = post_job(client, game.id, "analyze", note="first run")
    assert r.status_code == 201
    job = r.json()
    assert job["kind"] == JobKind.ANALYZE and job["status"] == JobStatus.QUEUED and job["params"] == {"note": "first run"}
    stored = db.get_game(game.id)
    assert stored.status == GameStatus.QUEUED and stored.latest_job_id == job["id"]
    assert [j["id"] for j in client.get(f"/api/games/{game.id}/jobs").json()] == [job["id"]]
    assert client.get(f"/api/jobs/{job['id']}").json()["kind"] == JobKind.ANALYZE


def test_analyze_from_video_url(client, game):
    db.update_game(game.id, video_url="https://example.com/film.mp4")
    assert post_job(client, game.id, "analyze").status_code == 201


def test_only_one_analysis_job_at_a_time(client, game):
    write_source_video(game.id)
    storage.tracking_path(game.id).write_bytes(b"{}")
    first = post_job(client, game.id, "analyze").json()
    for kind in ("analyze", "reanalyze"):
        r = post_job(client, game.id, kind)
        assert r.status_code == 409 and error_code(r) == "CONFLICT", kind
        assert first["id"] in r.json()["error"]["detail"]
    db.claim_job("w1", 60)  # running jobs block too
    assert post_job(client, game.id, "reanalyze").status_code == 409
    db.update_job(first["id"], status=JobStatus.SUCCEEDED)
    assert post_job(client, game.id, "reanalyze").status_code == 201


def test_reanalyze_needs_tracking_data(client, game):
    r = post_job(client, game.id, "reanalyze")
    assert r.status_code == 409 and error_code(r) == "ANALYSIS_NOT_READY"
    storage.game_dir(game.id, create=True)
    storage.tracking_path(game.id).write_bytes(b"{}")
    assert post_job(client, game.id, "reanalyze").status_code == 201


def test_report_job_rules(auth_headers, game, monkeypatch):
    with TestClient(create_app(), headers=auth_headers) as c:
        r = post_job(c, game.id, "report")
        assert r.status_code == 409 and error_code(r) == "ANALYSIS_NOT_READY"
        write_analysis(game, monkeypatch)
        r = post_job(c, game.id, "report")
        assert r.status_code == 503 and error_code(r) == "REPORT_NOT_CONFIGURED"
    with TestClient(make_app(monkeypatch, ANTHROPIC_API_KEY="sk-ant-test"), headers=auth_headers) as c:
        r = post_job(c, game.id, "report", coach_focus="we play zone")
        assert r.status_code == 201 and r.json()["params"] == {"coach_focus": "we play zone"}
        assert db.get_game(game.id).status == GameStatus.DRAFT  # reports do not touch the game status
        r = post_job(c, game.id, "report")
        assert r.status_code == 409 and "report" in r.json()["error"]["message"]


def test_report_waits_for_a_running_analysis(auth_headers, game, monkeypatch):
    write_analysis(game, monkeypatch)
    storage.tracking_path(game.id).write_bytes(b"{}")
    with TestClient(make_app(monkeypatch, ANTHROPIC_API_KEY="sk-ant-test"), headers=auth_headers) as c:
        reanalysis = post_job(c, game.id, "reanalyze").json()
        r = post_job(c, game.id, "report")
        assert r.status_code == 409 and "being analysed" in r.json()["error"]["message"]
        db.update_job(reanalysis["id"], status=JobStatus.SUCCEEDED)
        assert post_job(c, game.id, "report").status_code == 201
        assert post_job(c, game.id, "reanalyze").status_code == 201  # a pending report does not block analysis


def test_cancel_queued_job_puts_game_back(client, game):
    write_source_video(game.id)
    job = post_job(client, game.id, "analyze").json()
    r = client.post(f"/api/jobs/{job['id']}/cancel")
    assert r.status_code == 200 and r.json()["status"] == JobStatus.CANCELLED
    assert db.get_game(game.id).status == GameStatus.UPLOADED
    assert client.post(f"/api/jobs/{job['id']}/cancel").json()["status"] == JobStatus.CANCELLED  # idempotent


def test_cancel_running_job_flags_it_for_the_worker(client, game):
    write_source_video(game.id)
    job = post_job(client, game.id, "analyze").json()
    db.claim_job("w1", 60)
    body = client.post(f"/api/jobs/{job['id']}/cancel").json()
    assert body["status"] == JobStatus.RUNNING and body["cancel_requested"] is True
    assert db.get_game(game.id).status == GameStatus.QUEUED  # the worker settles it


def test_cancelled_reanalysis_returns_game_to_ready(client, game, monkeypatch):
    write_analysis(game, monkeypatch)
    storage.tracking_path(game.id).write_bytes(b"{}")
    job = post_job(client, game.id, "reanalyze").json()
    client.post(f"/api/jobs/{job['id']}/cancel")
    assert db.get_game(game.id).status == GameStatus.READY


def test_retry_copies_kind_and_params(client, game):
    write_source_video(game.id)
    job = post_job(client, game.id, "analyze", render_video=False).json()
    r = client.post(f"/api/jobs/{job['id']}/retry")
    assert r.status_code == 409 and "failed or cancelled" in r.json()["error"]["message"]
    db.update_job(job["id"], status=JobStatus.FAILED)
    r = client.post(f"/api/jobs/{job['id']}/retry")
    assert r.status_code == 200
    retried = r.json()
    assert retried["id"] != job["id"] and retried["kind"] == JobKind.ANALYZE
    assert retried["params"] == {"render_video": False}
    assert db.get_game(game.id).latest_job_id == retried["id"]


def test_unknown_jobs_404(client):
    assert client.get("/api/jobs/j_abcdef").status_code == 404
    assert client.post("/api/jobs/j_abcdef/cancel").status_code == 404
    assert client.post("/api/jobs/j_abcdef/retry").status_code == 404


class _DownQueue(job_queue.SQLiteJobQueue):
    def enqueue(self, job_id: str) -> None:
        raise ScoutError(ErrorCode.QUEUE_UNAVAILABLE)


def test_queue_outage_does_not_leave_a_blocking_job(client, game):
    write_source_video(game.id)
    db.update_game(game.id, status=GameStatus.UPLOADED)
    job_queue.set_queue(_DownQueue(config.get_settings()))
    r = post_job(client, game.id, "analyze")
    assert r.status_code == 503 and error_code(r) == "QUEUE_UNAVAILABLE"
    orphan = db.list_jobs(game_id=game.id)[0]
    assert orphan.status == JobStatus.FAILED and orphan.error.code == "QUEUE_UNAVAILABLE"
    assert db.get_game(game.id).status == GameStatus.UPLOADED

    job_queue.set_queue(None)  # queue is back
    assert post_job(client, game.id, "analyze").status_code == 201
