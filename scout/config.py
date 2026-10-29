"""Runtime settings, read from environment variables and ``.env``.

All app settings use the ``SCOUT_`` prefix. Third-party SDK credentials keep their
own names (``ANTHROPIC_API_KEY``, ``MODAL_TOKEN_ID``, ``MODAL_TOKEN_SECRET``) and are
exported into ``os.environ`` by :func:`load_env_file` so the SDKs can find them.

Relative paths are resolved against the repository root, not the working directory,
so systemd units and ad-hoc shells behave the same.
"""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import AliasChoices, Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

BASE_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = Path(os.environ.get("SCOUT_ENV_FILE", BASE_DIR / ".env"))

__all__ = ["BASE_DIR", "Settings", "get_settings", "load_env_file", "reset_settings"]


def load_env_file(path: Path | None = None, *, override: bool = False) -> bool:
    """Export KEY=VALUE pairs from ``.env`` into ``os.environ`` (existing vars win unless ``override``)."""
    from dotenv import load_dotenv

    target = path or ENV_FILE
    if not target.exists():
        return False
    return load_dotenv(target, override=override)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SCOUT_",
        env_file=str(ENV_FILE),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- server -------------------------------------------------------------
    host: str = "0.0.0.0"
    port: int = 8000
    log_level: str = "info"
    data_dir: Path = Path("data")
    db_path: Path | None = None
    public_base_url: str | None = Field(default=None, description="Used in log messages only, e.g. https://scout.school.org")

    # --- auth ---------------------------------------------------------------
    auth_username: str = "coach"
    auth_password: str | None = None
    auth_password_hash: str | None = Field(default=None, description="pbkdf2_sha256$<iterations>$<salt>$<hex digest> (see scout.auth)")
    auth_disabled: bool = False

    # --- uploads ------------------------------------------------------------
    max_upload_gb: float = 12.0
    upload_chunk_mb: int = 16
    max_video_minutes: float = 150.0

    # --- queue / worker -----------------------------------------------------
    queue_backend: Literal["sqlite", "redis"] = "sqlite"
    redis_url: str = "redis://localhost:6379/0"
    redis_prefix: str = "scout"
    worker_concurrency: int = Field(default=2, ge=1, le=16)
    job_lease_seconds: int = Field(default=300, ge=30)
    job_max_attempts: int = Field(default=3, ge=1)

    # --- video processing ---------------------------------------------------
    processor: Literal["modal", "mock", "local"] = "modal"
    modal_app_name: str = "basketball-scout"
    modal_function_name: str = "process_video"
    modal_volume_name: str = "basketball-scout-data"
    modal_progress_dict: str = "basketball-scout-progress"
    modal_environment: str | None = None
    modal_poll_seconds: float = Field(default=10.0, ge=1.0)
    modal_max_wait_hours: float = Field(default=8.0, gt=0)
    modal_cleanup: bool = True
    analysis_fps: float = Field(default=15.0, gt=0, le=60)
    analysis_max_side: int = Field(default=1280, ge=320, le=3840)
    render_annotated_video: bool = True
    render_height: int = Field(default=720, ge=240, le=2160)
    detector_weights: str | None = None
    court_keypoint_weights: str | None = None
    mock_seconds: float = Field(default=8.0, ge=0, description="Simulated GPU time for SCOUT_PROCESSOR=mock.")

    # --- Claude scouting report ---------------------------------------------
    anthropic_api_key: str | None = Field(
        default=None, validation_alias=AliasChoices("ANTHROPIC_API_KEY", "SCOUT_ANTHROPIC_API_KEY")
    )
    claude_model: str = "claude-opus-5-5"
    claude_effort: Literal["low", "medium", "high", "xhigh", "max"] = "high"
    claude_max_tokens: int = Field(default=32000, ge=2048, le=128000)
    claude_fallbacks: bool = True
    claude_timeout_s: float = Field(default=900.0, gt=0)
    auto_report: bool = True

    # --- config files -------------------------------------------------------
    fastscout_config: Path = Path("config/fastscout_columns.yaml")
    court_config: Path = Path("config/court.yaml")
    play_rules_config: Path = Path("config/play_rules.yaml")

    @field_validator("data_dir", "db_path", "fastscout_config", "court_config", "play_rules_config", mode="after")
    @classmethod
    def _resolve(cls, value: Path | None) -> Path | None:
        if value is None:
            return None
        value = value.expanduser()
        return value if value.is_absolute() else (BASE_DIR / value).resolve()

    # --- derived paths ------------------------------------------------------
    @property
    def database_path(self) -> Path:
        return self.db_path or (self.data_dir / "scout.db")

    @property
    def games_dir(self) -> Path:
        return self.data_dir / "games"

    @property
    def uploads_dir(self) -> Path:
        return self.data_dir / "uploads"

    @property
    def max_upload_bytes(self) -> int:
        return int(self.max_upload_gb * 1024**3)

    @property
    def upload_chunk_bytes(self) -> int:
        return self.upload_chunk_mb * 1024 * 1024

    @property
    def modal_configured(self) -> bool:
        """True when Modal credentials are available via env vars or ~/.modal.toml."""
        if os.environ.get("MODAL_TOKEN_ID") and os.environ.get("MODAL_TOKEN_SECRET"):
            return True
        return Path(os.environ.get("MODAL_CONFIG_PATH", Path.home() / ".modal.toml")).expanduser().exists()

    @property
    def claude_configured(self) -> bool:
        return bool(self.anthropic_api_key)

    @property
    def auth_enabled(self) -> bool:
        return not self.auth_disabled

    def ensure_dirs(self) -> None:
        for d in (self.data_dir, self.games_dir, self.uploads_dir, self.database_path.parent):
            d.mkdir(parents=True, exist_ok=True)


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    load_env_file()
    return Settings()


def reset_settings() -> None:
    """Forget cached settings (tests change env vars between cases)."""
    get_settings.cache_clear()
