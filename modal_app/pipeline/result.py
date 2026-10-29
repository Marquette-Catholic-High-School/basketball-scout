"""Serialise perception + events into the TrackingResult dict (docs/TRACKING_SCHEMA.md).

The output must validate as ``scout.schemas.TrackingResult`` on the server, but this
module cannot import ``scout`` (the Modal image only ships ``modal_app``), so it
sanitises defensively: unknown event types are dropped, confidences clamped, floats
rounded to 2 decimals, and every value made JSON-native.

Size: one track sample is ~85 bytes of JSON (~20 bytes gzipped). ``choose_sample_stride``
thins track samples so a 60-minute game stays well under ~30 MB gzipped.
"""

from __future__ import annotations

import gzip
import json
import logging
import math
import os
from pathlib import Path
from typing import Any

from modal_app.pipeline.types import BallObs, HomographySeg, Perception, RimObs, TrackData, TrackObs, VideoMeta

logger = logging.getLogger(__name__)

TRACKING_SCHEMA_VERSION = "1.0"
MAX_TRACK_SAMPLES = 1_200_000  # ~25 MB gzipped
RAW_EVENT_TYPES = frozenset(
    {
        "shot", "free_throw", "rebound", "pass", "turnover", "foul",
        "screen", "jump_ball", "period_start", "period_end", "timeout",
    }
)  # fmt: skip
_ROLES = frozenset({"player", "referee", "unknown"})
_SEVERITIES = frozenset({"info", "warning", "error"})
_HOMOGRAPHY_SOURCES = frozenset({"model", "manual", "classical"})


def build_tracking_result(
    perception: Perception,
    events: list[dict[str, Any]],
    *,
    job_id: str | None,
    pipeline_info: dict[str, Any],
    artifacts: dict[str, str] | None = None,
    sample_stride: int = 1,
) -> dict[str, Any]:
    """JSON-serialisable dict that validates as ``scout.schemas.TrackingResult``.

    ``sample_stride`` thins track samples (every n-th analysed frame, always keeping a
    track's last sample) to bound size; keypoints are not included (too large).
    """
    stride = max(1, int(sample_stride))
    tracks = sorted((t for t in perception.tracks.values() if t.obs), key=lambda t: t.track_id)
    return {
        "schema_version": TRACKING_SCHEMA_VERSION,
        "job_id": job_id,
        "video": _video(perception.video),
        "pipeline": _pipeline(pipeline_info),
        "court": {
            "length_ft": _r(perception.court_length_ft),
            "width_ft": _r(perception.court_width_ft),
            "homographies": [_homography(h) for h in perception.homographies],
        },
        "teams": [_team(t) for t in perception.teams],
        "tracks": [_track(t, stride) for t in tracks],
        "ball": [_ball(b) for b in sorted(perception.ball, key=lambda b: b.frame)],
        "events": _events(events),
        "rims": [_rim(r) for r in perception.rims],
        "warnings": [_warning(w) for w in perception.warnings],
        "artifacts": {str(k): str(v) for k, v in (artifacts or {}).items()},
    }


def choose_sample_stride(perception: Perception, max_samples: int = MAX_TRACK_SAMPLES) -> int:
    """Smallest stride that keeps the total number of track samples under ``max_samples``."""
    total = sum(len(t.obs) for t in perception.tracks.values())
    return max(1, math.ceil(total / max_samples))


def write_tracking_result(result: dict[str, Any], path: str | os.PathLike[str]) -> int:
    """Write ``result`` as gzipped JSON atomically; return the compressed size in bytes."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    payload = json.dumps(result, separators=(",", ":"), allow_nan=False).encode("utf-8")
    with gzip.open(tmp, "wb", compresslevel=6) as fh:
        fh.write(payload)
    os.replace(tmp, path)
    return path.stat().st_size


# ---------------------------------------------------------------------------
# Field serialisers
# ---------------------------------------------------------------------------


def _r(value: float, digits: int = 2) -> float:
    number = float(value)
    return round(number, digits) if math.isfinite(number) else 0.0


def _point(xy: Any) -> list[float] | None:
    if xy is None:
        return None
    x, y = float(xy[0]), float(xy[1])
    return [round(x, 2), round(y, 2)] if math.isfinite(x) and math.isfinite(y) else None


def _unit(value: Any, default: float = 0.5) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return round(min(1.0, max(0.0, number)), 3) if math.isfinite(number) else default


def _opt_int(value: Any) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _video(video: VideoMeta) -> dict[str, Any]:
    return {
        "filename": video.filename,
        "fps": round(float(video.fps), 6),
        "width": int(video.width),
        "height": int(video.height),
        "frame_count": max(0, int(video.frame_count)),
        "duration_s": _r(video.duration_s, 3),
        "analysis_fps": round(float(video.analysis_fps), 6),
        "codec": video.codec,
    }


def _pipeline(info: dict[str, Any]) -> dict[str, Any]:
    elapsed = info.get("elapsed_s")
    return {
        "name": str(info.get("name") or "openhoopvision"),
        "version": str(info.get("version") or "0"),
        "models": {str(k): str(v) for k, v in (info.get("models") or {}).items()},
        "gpu": None if info.get("gpu") is None else str(info["gpu"]),
        "elapsed_s": None if elapsed is None else _r(elapsed, 1),
        "options": _jsonable(info.get("options") or {}),
    }


def _homography(seg: HomographySeg) -> dict[str, Any]:
    return {
        "frame_start": int(seg.frame_start),
        "frame_end": _opt_int(seg.frame_end),
        "matrix": [[float(v) for v in row] for row in seg.matrix],  # full precision: tiny terms matter
        "reprojection_error_px": None if seg.error_px is None else _r(seg.error_px),
        "source": seg.source if seg.source in _HOMOGRAPHY_SOURCES else "model",
    }


def _team(team: dict[str, Any]) -> dict[str, Any]:
    rgb = team.get("color_rgb")
    return {
        "team_id": int(team["team_id"]),
        "color_rgb": [int(c) for c in rgb] if rgb is not None else None,
        "color_name": team.get("color_name"),
        "track_count": int(team.get("track_count") or 0),
    }


def _sample(obs: TrackObs) -> dict[str, Any]:
    return {
        "f": int(obs.frame),
        "bbox": [_r(v) for v in obs.bbox],
        "court_xy": _point(obs.court_xy),
        "conf": _unit(obs.conf, 1.0),
    }


def _track(track: TrackData, stride: int) -> dict[str, Any]:
    obs = sorted(track.obs, key=lambda o: o.frame)
    kept = obs[::stride]
    if kept[-1] is not obs[-1]:
        kept.append(obs[-1])
    return {
        "track_id": int(track.track_id),
        "team_id": _opt_int(track.team_id),
        "role": track.role if track.role in _ROLES else "unknown",
        "jersey_reads": [
            {"frame": int(f), "text": str(text), "conf": _unit(conf)} for f, text, conf in track.jersey_reads
        ],
        "samples": [_sample(o) for o in kept],
    }


def _ball(ball: BallObs) -> dict[str, Any]:
    return {
        "f": int(ball.frame),
        "xy": _point(ball.xy) or [0.0, 0.0],
        "court_xy": _point(ball.court_xy),
        "conf": _unit(ball.conf, 1.0),
        "holder_track_id": _opt_int(ball.holder_track_id),
        "interpolated": bool(ball.interpolated),
    }


def _rim(rim: RimObs) -> dict[str, Any]:
    return {
        "side": rim.side if rim.side in ("left", "right") else "left",
        "xy_px": _point(rim.xy_px),
        "frame_start": int(rim.frame_start),
        "frame_end": _opt_int(rim.frame_end),
    }


def _warning(warning: dict[str, str]) -> dict[str, str]:
    severity = warning.get("severity", "warning")
    return {
        "code": str(warning.get("code") or "WARNING"),
        "message": str(warning.get("message") or ""),
        "severity": severity if severity in _SEVERITIES else "warning",
    }


def _events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Keep well-formed RawEvents (others are logged and dropped), sorted by frame."""
    clean = []
    for event in events:
        try:
            if event["type"] not in RAW_EVENT_TYPES:
                raise ValueError(f"unknown event type {event['type']!r}")
            frame = int(event["frame"])
            clean.append(
                {
                    "event_id": str(event["event_id"]),
                    "type": str(event["type"]),
                    "frame": frame,
                    "t": _r(event.get("t", 0.0), 3),
                    "track_id": _opt_int(event.get("track_id")),
                    "team_id": _opt_int(event.get("team_id")),
                    "conf": _unit(event.get("conf")),
                    "attrs": _jsonable(event.get("attrs") or {}),
                }
            )
        except (KeyError, TypeError, ValueError) as exc:
            label = event.get("event_id") if isinstance(event, dict) else event
            logger.warning("dropping malformed event %r: %s", label, exc)
    clean.sort(key=lambda e: e["frame"])
    return clean


def _jsonable(value: Any) -> Any:
    """Plain JSON types only (tuples -> lists, numpy-ish scalars -> Python, NaN -> None)."""
    if isinstance(value, dict):
        return {str(k): _jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set, frozenset)):
        return [_jsonable(v) for v in value]
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return value
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return round(value, 4) if math.isfinite(value) else None
    if hasattr(value, "item"):  # numpy scalar
        return _jsonable(value.item())
    return str(value)
