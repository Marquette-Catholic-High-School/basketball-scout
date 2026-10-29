"""On-disk layout for game files.

::

    <data_dir>/
      scout.db
      uploads/<upload_id>.part          in-progress chunked uploads
      games/<game_id>/
        source.mp4                      original film (extension kept from upload)
        tracking.json.gz                raw TrackingResult from the GPU pipeline
        annotated.mp4                   rendered overlay video (optional)
        analysis.json                   latest GameAnalysis
"""

from __future__ import annotations

import gzip
import json
import os
import shutil
import tempfile
from pathlib import Path
from typing import Any

from scout.config import get_settings

VIDEO_EXTENSIONS = (".mp4", ".mov", ".m4v")


def game_dir(game_id: str, *, create: bool = False) -> Path:
    path = get_settings().games_dir / _safe(game_id)
    if create:
        path.mkdir(parents=True, exist_ok=True)
    return path


def source_video_path(game_id: str, suffix: str = ".mp4") -> Path:
    suffix = suffix.lower() if suffix.lower() in VIDEO_EXTENSIONS else ".mp4"
    return game_dir(game_id) / f"source{suffix}"


def find_source_video(game_id: str) -> Path | None:
    for ext in VIDEO_EXTENSIONS:
        candidate = game_dir(game_id) / f"source{ext}"
        if candidate.exists():
            return candidate
    return None


def annotated_video_path(game_id: str) -> Path:
    return game_dir(game_id) / "annotated.mp4"


def tracking_path(game_id: str) -> Path:
    return game_dir(game_id) / "tracking.json.gz"


def analysis_path(game_id: str) -> Path:
    return game_dir(game_id) / "analysis.json"


def upload_part_path(upload_id: str) -> Path:
    return get_settings().uploads_dir / f"{_safe(upload_id)}.part"


def remove_game_files(game_id: str) -> None:
    shutil.rmtree(game_dir(game_id), ignore_errors=True)


def write_bytes_atomic(path: Path, data: bytes) -> None:
    """Write via a temp file + rename so readers never see a half-written file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def write_text_atomic(path: Path, text: str) -> None:
    write_bytes_atomic(path, text.encode("utf-8"))


def write_json(path: Path, data: Any, *, compress: bool | None = None) -> None:
    """Write JSON (gzip when the path ends in .gz or ``compress`` is True)."""
    payload = data if isinstance(data, str) else json.dumps(data, separators=(",", ":"), default=str)
    raw = payload.encode("utf-8")
    if compress if compress is not None else path.suffix == ".gz":
        raw = gzip.compress(raw, compresslevel=6)
    write_bytes_atomic(path, raw)


def read_json(path: Path) -> Any:
    """Read JSON, transparently handling gzip (by magic bytes, not extension)."""
    raw = path.read_bytes()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return json.loads(raw)


def _safe(name: str) -> str:
    """Reject path traversal in ids used as file names."""
    if not name or any(c in name for c in "/\\") or name in {".", ".."} or "\x00" in name:
        raise ValueError(f"unsafe path component: {name!r}")
    return name
