"""Exports (FastScout, timeline, analysis JSON) and Claude reports, collaborators faked."""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from scout import db
from scout.export import fastscout
from scout.main import create_app
from scout.reporting import render
from scout.schemas import GameCreate, JobKind, JobStatus, TeamSide
from tests.test_api_support import make_app, save_report, write_analysis


@pytest.fixture
def client(auth_headers):
    with TestClient(create_app(), headers=auth_headers) as c:
        yield c


@pytest.fixture
def dated_game(game):
    return db.update_game(game.id, game_date=date(2026, 1, 9))


@pytest.fixture
def fake_fastscout(monkeypatch):
    calls: list[tuple] = []

    def paste_block(analysis, game, side=TeamSide.SCOUTED, config=None):
        calls.append(("paste", analysis.game_id, side))
        return "NAME\tPTS\nJordan Smith\t12\n"

    def custom_csv(analysis, game, side=TeamSide.SCOUTED, table=None, config=None):
        calls.append(("csv", side, table))
        return "Name,PTS\r\nJordan Smith,12\r\n"

    monkeypatch.setattr(fastscout, "build_paste_block", paste_block)
    monkeypatch.setattr(fastscout, "build_custom_table_csv", custom_csv)
    monkeypatch.setattr(fastscout, "build_timeline_csv", lambda analysis: "t,type\r\n1.0,shot_made\r\n")
    monkeypatch.setattr(fastscout, "list_custom_tables", lambda config=None: ["Box Score", "Shooting Zones"])
    return calls


EXPORTS = ["fastscout.txt", "fastscout.csv", "timeline.csv", "analysis.json"]


@pytest.mark.parametrize("name", EXPORTS)
def test_exports_need_an_analysis(client, game, fake_fastscout, name):
    r = client.get(f"/api/games/{game.id}/export/{name}")
    assert r.status_code == 409 and r.json()["error"]["code"] == "ANALYSIS_NOT_READY"


def test_paste_block(client, dated_game, fake_fastscout, monkeypatch):
    write_analysis(dated_game, monkeypatch)
    r = client.get(f"/api/games/{dated_game.id}/export/fastscout.txt")
    assert r.status_code == 200 and r.text.startswith("NAME\tPTS")
    assert r.headers["content-type"] == "text/plain; charset=utf-8"
    assert "content-disposition" not in r.headers
    r = client.get(f"/api/games/{dated_game.id}/export/fastscout.txt", params={"side": "other", "download": "1"})
    assert r.headers["content-disposition"] == 'attachment; filename="fastscout_rival-hs_2026-01-09.txt"'
    assert fake_fastscout == [("paste", dated_game.id, TeamSide.SCOUTED), ("paste", dated_game.id, TeamSide.OTHER)]
    assert client.get(f"/api/games/{dated_game.id}/export/fastscout.txt", params={"side": "home"}).status_code == 422


def test_custom_table_csv(client, dated_game, fake_fastscout, monkeypatch):
    write_analysis(dated_game, monkeypatch)
    r = client.get(f"/api/games/{dated_game.id}/export/fastscout.csv")
    assert r.status_code == 200 and r.headers["content-type"] == "text/csv; charset=utf-8"
    r = client.get(
        f"/api/games/{dated_game.id}/export/fastscout.csv", params={"table": "Shooting Zones", "download": "true"}
    )
    assert r.headers["content-disposition"] == 'attachment; filename="fastscout_shooting-zones_opponent-hs_2026-01-09.csv"'
    assert fake_fastscout == [("csv", TeamSide.SCOUTED, None), ("csv", TeamSide.SCOUTED, "Shooting Zones")]
    r = client.get(f"/api/games/{dated_game.id}/export/fastscout.csv", params={"table": "Nope"})
    assert r.status_code == 422 and "Box Score" in r.json()["error"]["hint"]


def test_table_list(client, fake_fastscout):
    assert client.get("/api/export/fastscout/tables").json() == ["Box Score", "Shooting Zones"]


def test_timeline_and_analysis_downloads(client, game, fake_fastscout, monkeypatch):
    write_analysis(game, monkeypatch)
    r = client.get(f"/api/games/{game.id}/export/timeline.csv", params={"download": "1"})
    assert r.text.startswith("t,type") and r.headers["content-type"] == "text/csv; charset=utf-8"
    assert r.headers["content-disposition"].startswith('attachment; filename="timeline_opponent-hs_')
    r = client.get(f"/api/games/{game.id}/export/analysis.json", params={"download": "1"})
    assert r.headers["content-type"] == "application/json" and r.json()["game_id"] == game.id
    assert r.headers["content-disposition"].startswith('attachment; filename="analysis_opponent-hs_')


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------


def test_request_report_queues_a_job(auth_headers, game, monkeypatch):
    write_analysis(game, monkeypatch)
    with TestClient(make_app(monkeypatch, ANTHROPIC_API_KEY="sk-ant-test"), headers=auth_headers) as c:
        r = c.post(f"/api/games/{game.id}/reports", json={"coach_focus": "We play a 2-3 zone"})
        assert r.status_code == 202
        job = r.json()
        assert job["kind"] == JobKind.REPORT and job["status"] == JobStatus.QUEUED
        assert job["params"] == {"coach_focus": "We play a 2-3 zone"}
        assert c.post(f"/api/games/{game.id}/reports", json={}).status_code == 409  # one at a time
        r = c.post(f"/api/games/{game.id}/reports", json={"coach_focus": "x" * 2001})
        assert r.status_code == 422


def test_request_report_without_api_key(client, game, monkeypatch):
    write_analysis(game, monkeypatch)
    r = client.post(f"/api/games/{game.id}/reports", json={})
    assert r.status_code == 503 and r.json()["error"]["code"] == "REPORT_NOT_CONFIGURED"


def test_list_and_get_reports(client, game):
    now = datetime.now(UTC)
    older = save_report(game.id, "Older report", now - timedelta(hours=1))
    newer = save_report(game.id, "Newer report", now)
    assert [r["id"] for r in client.get(f"/api/games/{game.id}/reports").json()] == [newer.id, older.id]
    body = client.get(f"/api/reports/{older.id}").json()
    assert body["report"]["headline"] == "Older report" and body["model"] == "claude-opus-5-5"
    assert client.get("/api/reports/r_000000").status_code == 404


def test_report_markdown(client, dated_game, monkeypatch):
    monkeypatch.setattr(
        render, "report_to_markdown", lambda report, game, model=None: f"# {report.headline}\n\n{game.display_title} ({model})\n"
    )
    r = client.get(f"/api/games/{dated_game.id}/export/report.md")
    assert r.status_code == 404 and "No scouting report" in r.json()["error"]["message"]

    now = datetime.now(UTC)
    older = save_report(dated_game.id, "Older report", now - timedelta(hours=1))
    save_report(dated_game.id, "Newer report", now)
    r = client.get(f"/api/games/{dated_game.id}/export/report.md")
    assert r.status_code == 200 and r.text.startswith("# Newer report")
    assert r.headers["content-type"] == "text/markdown; charset=utf-8"
    assert "Opponent HS vs Rival HS (claude-opus-5-5)" in r.text
    r = client.get(f"/api/games/{dated_game.id}/export/report.md", params={"report_id": older.id, "download": "1"})
    assert r.text.startswith("# Older report")
    assert r.headers["content-disposition"] == 'attachment; filename="scouting_report_opponent-hs_2026-01-09.md"'
    assert client.get(f"/api/games/{dated_game.id}/export/report.md", params={"report_id": "../etc"}).status_code == 404

    other_game = db.create_game(GameCreate(scouted_team="Someone Else"))
    foreign = save_report(other_game.id, "Not this game", now)
    r = client.get(f"/api/games/{dated_game.id}/export/report.md", params={"report_id": foreign.id})
    assert r.status_code == 404
