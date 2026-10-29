"""Helpers shared by the API tests (this module has no tests of its own).

Collaborators owned by other modules (transform, exports, reports, roster import) are
faked with monkeypatch so the HTTP layer is tested on its own.
"""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi import FastAPI

from scout import config, db, storage
from scout.analysis import pipeline
from scout.main import create_app
from scout.schemas import (
    Game,
    GameAnalysis,
    PipelineInfo,
    ReportRecord,
    ScoutingReport,
    TeamSide,
    TeamSummary,
    TrackAssignment,
)
from tests import helpers


def make_app(monkeypatch: pytest.MonkeyPatch, **env: str) -> FastAPI:
    """Build the app after setting env overrides (settings are read when the app is built)."""
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    config.reset_settings()
    return create_app()


def fake_mp4(size: int = 4096) -> bytes:
    """Bytes that pass the MP4 header sniff (``ftyp`` at offset 4)."""
    head = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 12
    return head + bytes(i % 251 for i in range(size - len(head)))


def write_source_video(game_id: str, data: bytes = b"", suffix: str = ".mp4") -> Path:
    path = storage.source_video_path(game_id, suffix)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data or fake_mp4())
    return path


def write_analysis(game: Game, monkeypatch: pytest.MonkeyPatch) -> GameAnalysis:
    """Store a small analysis.json and make ``load_analysis`` read it with pydantic."""
    analysis = GameAnalysis(
        game_id=game.id,
        generated_at=datetime.now(UTC),
        video=helpers.video_info(),
        pipeline=PipelineInfo(name="test"),
        teams=[
            TeamSummary(side=TeamSide.SCOUTED, name=game.scouted_team),
            TeamSummary(side=TeamSide.OTHER, name=game.other_team),
        ],
        track_assignments=[TrackAssignment(track_id=7, side=TeamSide.SCOUTED, jersey="3", method="exact")],
    )
    path = storage.analysis_path(game.id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(analysis.model_dump_json())
    monkeypatch.setattr(pipeline, "load_analysis", lambda p: GameAnalysis.model_validate_json(Path(p).read_text()))
    return analysis


def sample_report(headline: str = "Guard-driven team") -> ScoutingReport:
    return ScoutingReport(
        headline=headline,
        executive_summary="They run high pick and roll.",
        offensive_identity=["High pick and roll"],
        defensive_identity=["2-3 zone"],
        key_players=[],
        play_tendencies=[],
        transition=[],
        special_situations=[],
        keys_to_win=["Hedge ball screens"],
        defensive_game_plan=[],
        offensive_game_plan=[],
        practice_emphasis=[],
        data_caveats=["Computer-vision stats are approximate."],
    )


def save_report(game_id: str, headline: str, created_at: datetime) -> ReportRecord:
    record = ReportRecord(
        game_id=game_id,
        created_at=created_at,
        model="claude-opus-5-5",
        report=sample_report(headline),
        markdown=f"# {headline}\n",
    )
    return db.save_report(record)
