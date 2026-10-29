"""Cross-module integration tests: synthetic film -> transform -> exports -> report -> API + worker.

These exercise the real modules together (no monkeypatching of project code); only the
outside world (Modal, Anthropic) is faked.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from scout import db, storage
from scout.analysis import pipeline
from scout.analysis.synthetic import generate_synthetic_game, synthetic_rosters
from scout.export import fastscout
from scout.reporting import claude_report
from scout.schemas import (
    EventType,
    GameStatus,
    JobKind,
    JobStatus,
    PlayType,
    ScoutingReport,
    TeamSide,
)


@pytest.fixture(scope="module")
def synthetic():
    return generate_synthetic_game(seed=11, duration_s=420.0)


def _analyze(game, tracking, rosters):
    for roster in rosters.values():
        db.save_roster(roster.model_copy(update={"game_id": game.id}))
    return pipeline.analyze_game(tracking, game, db.get_rosters(game.id), [])


def test_transform_matches_synthetic_truth(game, synthetic):
    tracking, truth = synthetic
    game = db.update_game(game.id, team_id_map={0: TeamSide.SCOUTED, 1: TeamSide.OTHER})
    analysis = _analyze(game, tracking, synthetic_rosters(game.id, seed=11))

    scouted = analysis.box_score(TeamSide.SCOUTED)
    other = analysis.box_score(TeamSide.OTHER)
    assert scouted is not None and other is not None
    # Team points must be exact: they come straight from the raw events.
    assert scouted.totals.pts == truth.score["scouted"]
    assert other.totals.pts == truth.score["other"]
    assert analysis.team(TeamSide.SCOUTED).score == truth.score["scouted"]

    # Most players' points should be attributed to the right jersey despite OCR noise.
    by_jersey = {line.player.jersey: line for line in scouted.players if line.player.jersey}
    checked = matched = 0
    for key, stats in truth.box.items():
        side, jersey = key.split(":#")
        if side != "scouted" or not stats.get("pts"):
            continue
        checked += 1
        line = by_jersey.get(jersey)
        if line is not None and line.pts == stats["pts"]:
            matched += 1
    assert checked and matched / checked >= 0.7, (matched, checked)

    # Timeline is chronological, carries the possession indicator and a running score.
    times = [e.t for e in analysis.timeline]
    assert times == sorted(times)
    scoring = [e for e in analysis.timeline if e.type in (EventType.SHOT_MADE, EventType.FT_MADE)]
    assert scoring and all(e.possession_side is not None for e in scoring)
    last = analysis.timeline[-1]
    assert (last.score_scouted, last.score_other) == (truth.score["scouted"], truth.score["other"])

    # Play recognition found offensive plays and labelled half-court defense.
    offensive = {p.type for p in analysis.plays if p.category == "offense"}
    assert {PlayType.PICK_AND_ROLL, PlayType.FAST_BREAK} & offensive
    assert any(p.category == "defense" for p in analysis.plays)
    assert analysis.play_summary

    assert analysis.data_quality.homography_available
    assert analysis.data_quality.jersey_match_rate > 0.5


def test_analysis_roundtrip_and_exports(game, synthetic, tmp_path):
    tracking, _ = synthetic
    game = db.update_game(game.id, team_id_map={0: TeamSide.SCOUTED, 1: TeamSide.OTHER})
    analysis = _analyze(game, tracking, synthetic_rosters(game.id, seed=11))
    path = tmp_path / "analysis.json"
    pipeline.save_analysis(analysis, path)
    assert pipeline.load_analysis(path).model_dump() == analysis.model_dump()

    block = fastscout.build_paste_block(analysis, game, TeamSide.SCOUTED)
    header, *rows = block.strip("\n").split("\n")
    assert header.split("\t")[0] == "NAME" and "\t" in header
    assert rows and all(len(r.split("\t")) == len(header.split("\t")) for r in rows)
    assert all(not any(ch.isdigit() for ch in r.split("\t")[0]) for r in rows)

    for table in fastscout.list_custom_tables():
        csv_text = fastscout.build_custom_table_csv(analysis, game, TeamSide.SCOUTED, table)
        assert csv_text.endswith("\r\n") and not csv_text.startswith("﻿")
    timeline_csv = fastscout.build_timeline_csv(analysis)
    assert len(timeline_csv.splitlines()) == len(analysis.timeline) + 1


class _FakeStream:
    def __init__(self, message):
        self._message = message

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def get_final_message(self):
        return self._message


class _FakeClient:
    def __init__(self, report_json: str):
        self.calls: list[dict] = []
        message = SimpleNamespace(
            content=[SimpleNamespace(type="text", text=report_json)],
            stop_reason="end_turn",
            stop_details=None,
            model="claude-opus-5-5",
            usage=SimpleNamespace(input_tokens=1000, output_tokens=500, cache_read_input_tokens=0, cache_creation_input_tokens=0),
        )
        outer = self

        class _Messages:
            def stream(self, **kwargs):
                outer.calls.append(kwargs)
                return _FakeStream(message)

        self.beta = SimpleNamespace(messages=_Messages())
        self.messages = _Messages()


def _sample_report() -> ScoutingReport:
    return ScoutingReport(
        headline="Guard-driven team that lives on the pick and roll",
        executive_summary="They run high pick and roll for #3.",
        offensive_identity=["High pick and roll"],
        defensive_identity=["2-3 zone after made baskets"],
        key_players=[],
        play_tendencies=[],
        transition=["Push after defensive rebounds"],
        special_situations=[],
        keys_to_win=["Hedge the ball screen"],
        defensive_game_plan=["Ice side pick and rolls"],
        offensive_game_plan=["Attack the zone from the high post"],
        practice_emphasis=["Zone offense"],
        data_caveats=["Computer-vision stats are approximate."],
    )


def test_report_from_real_analysis(game, synthetic, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    from scout import config

    config.reset_settings()
    tracking, _ = synthetic
    analysis = _analyze(game, tracking, synthetic_rosters(game.id, seed=11))
    payload = claude_report.build_report_payload(analysis, game, db.get_rosters(game.id))
    assert json.dumps(payload, sort_keys=True)  # serialisable

    client = _FakeClient(_sample_report().model_dump_json())
    record = claude_report.generate_report(analysis, game, db.get_rosters(game.id), coach_focus="We play man", client=client)
    assert record.report.headline.startswith("Guard-driven")
    assert "# " in record.markdown
    sent = client.calls[0]
    assert sent["model"] == "claude-opus-5-5"
    assert "temperature" not in sent and "top_p" not in sent
    assert sent["thinking"] == {"type": "adaptive"}


def _fake_mp4(size: int = 4096) -> bytes:
    head = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 12
    return head + b"\x11" * (size - len(head))


def test_api_upload_worker_flow(auth_headers, monkeypatch):
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    from scout import config

    config.reset_settings()
    from scout.main import create_app
    from scout.worker import Worker

    with TestClient(create_app()) as client:
        r = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North", "scouted_color": "dark"}, headers=auth_headers)
        assert r.status_code == 201, r.text
        game_id = r.json()["id"]

        data = _fake_mp4()
        r = client.post(f"/api/games/{game_id}/uploads", json={"filename": "game.mp4", "size": len(data)}, headers=auth_headers)
        assert r.status_code == 201, r.text
        upload = r.json()
        half = len(data) // 2
        for offset, chunk in ((0, data[:half]), (half, data[half:])):
            r = client.put(
                f"/api/uploads/{upload['id']}/chunk",
                params={"offset": offset},
                content=chunk,
                headers={**auth_headers, "Content-Type": "application/octet-stream"},
            )
            assert r.status_code == 200, r.text
        r = client.post(f"/api/uploads/{upload['id']}/complete", headers=auth_headers)
        assert r.status_code == 200, r.text
        job = r.json()["job"]
        assert job and job["kind"] == JobKind.ANALYZE

        worker = Worker(worker_id="test-worker")
        assert worker.run_once(timeout=2)
        finished = db.get_job(job["id"])
        assert finished.status == JobStatus.SUCCEEDED, finished.error
        assert db.get_game(game_id).status == GameStatus.READY
        assert storage.analysis_path(game_id).exists()

        r = client.get(f"/api/games/{game_id}/analysis", headers=auth_headers)
        assert r.status_code == 200
        assert r.json()["box_scores"]
        r = client.get(f"/api/games/{game_id}/export/fastscout.txt", headers=auth_headers)
        assert r.status_code == 200 and r.text.startswith("NAME\t")
        r = client.get(f"/api/games/{game_id}/export/timeline.csv", headers=auth_headers)
        assert r.status_code == 200

        r = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}, headers=auth_headers)
        assert r.status_code == 201, r.text
        assert worker.run_once(timeout=2)
        assert db.get_job(r.json()["id"]).status == JobStatus.SUCCEEDED

        for page in ("/", "/upload", f"/games/{game_id}", f"/games/{game_id}/roster"):
            r = client.get(page, headers=auth_headers)
            assert r.status_code == 200 and "<html" in r.text.lower(), page
        assert client.get("/", headers={}).status_code == 401
