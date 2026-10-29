"""Shared pytest fixtures: every test runs against a fresh temp data dir with
SCOUT_PROCESSOR=mock, the SQLite queue, and no real credentials."""

from __future__ import annotations

import base64
import os
from pathlib import Path

# Must happen before scout.config is imported anywhere: never read the developer's .env.
os.environ["SCOUT_ENV_FILE"] = str(Path(__file__).parent / "fixtures" / "does-not-exist.env")

import pytest  # noqa: E402

from scout import config, db  # noqa: E402
from scout.jobs import queue as job_queue  # noqa: E402
from scout.schemas import GameCreate  # noqa: E402

TEST_USER = "coach"
TEST_PASSWORD = "test-password-123"
_LEAKY_VARS = ("ANTHROPIC_API_KEY", "MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET", "MODAL_PROFILE")


@pytest.fixture(autouse=True)
def isolated_env(tmp_path, monkeypatch):
    for name in list(os.environ):
        if name.startswith("SCOUT_") and name != "SCOUT_ENV_FILE":
            monkeypatch.delenv(name, raising=False)
    for name in _LEAKY_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("MODAL_CONFIG_PATH", str(tmp_path / "no-modal.toml"))
    monkeypatch.setenv("SCOUT_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("SCOUT_PROCESSOR", "mock")
    monkeypatch.setenv("SCOUT_QUEUE_BACKEND", "sqlite")
    monkeypatch.setenv("SCOUT_AUTH_USERNAME", TEST_USER)
    monkeypatch.setenv("SCOUT_AUTH_PASSWORD", TEST_PASSWORD)
    monkeypatch.setenv("SCOUT_AUTO_REPORT", "false")
    config.reset_settings()
    db.reset_db_cache()
    job_queue.set_queue(None)
    config.get_settings().ensure_dirs()
    yield
    job_queue.set_queue(None)
    config.reset_settings()
    db.reset_db_cache()


@pytest.fixture
def settings():
    return config.get_settings()


@pytest.fixture
def game():
    return db.create_game(GameCreate(scouted_team="Opponent HS", other_team="Rival HS", scouted_color="dark"))


@pytest.fixture
def auth_headers():
    token = base64.b64encode(f"{TEST_USER}:{TEST_PASSWORD}".encode()).decode()
    return {"Authorization": f"Basic {token}"}
