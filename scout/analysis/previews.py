"""Pictures of tracked players, cut from the film.

To tell who an unnamed track is, the coach needs to see him. For every track the best few
moments are chosen from the tracking (where his box is largest and clearly inside the picture,
spread over the time he is tracked), and a picture of one is cut from the film with ffmpeg the
first time it is asked for, then kept in the game folder.

The pictures show students: they are served only behind the sign-in, live in the game's folder
and go when the game or its film is deleted.
"""

from __future__ import annotations

import logging
import shutil
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path

from scout import storage
from scout.analysis import pipeline
from scout.errors import ErrorCode, ScoutError
from scout.schemas import TrackingResult

logger = logging.getLogger(__name__)

MAX_VIEWS = 3
HEIGHTS = {"small": 120, "large": 360}
MARGIN_X, MARGIN_Y = 0.35, 0.12  # room around the player's box, as shares of its width / height
CUT_TIMEOUT_S = 30.0
_cutting = threading.BoundedSemaphore(3)  # ffmpeg processes at once: a page asks for many pictures together
_index_locks: dict[str, threading.Lock] = {}
_index_guard = threading.Lock()


@dataclass(frozen=True)
class View:
    frame: int
    box: tuple[float, float, float, float]


def choose_views(tracking: TrackingResult) -> dict[int, list[View]]:
    """Up to ``MAX_VIEWS`` moments per track, best first: the largest, surest boxes that do not touch
    the picture's edge, one from each third of the time the track is seen."""
    width, height = tracking.video.width, tracking.video.height
    views: dict[int, list[View]] = {}
    for track in tracking.tracks:
        samples = track.samples
        if not samples:
            continue
        first, last = samples[0].f, samples[-1].f
        span = max(1, last - first + 1)
        best: dict[int, tuple[float, View]] = {}
        for sample in samples:
            x1, y1, x2, y2 = sample.bbox
            score = max(0.0, x2 - x1) * max(0.0, y2 - y1) * max(0.05, sample.conf)
            if x1 <= 2 or y1 <= 2 or x2 >= width - 2 or y2 >= height - 2:
                score *= 0.4  # partly out of the picture
            third = min(MAX_VIEWS - 1, (sample.f - first) * MAX_VIEWS // span)
            if third not in best or score > best[third][0]:
                best[third] = (score, View(sample.f, (x1, y1, x2, y2)))
        views[track.track_id] = [view for _, view in sorted(best.values(), key=lambda item: -item[0])]
    return views


def _index_path(game_id: str) -> Path:
    return storage.previews_dir(game_id) / "index.json"


def load_index(game_id: str) -> dict:
    """The game's chosen moments, built from ``tracking.json.gz`` the first time and whenever that
    file has changed (a new analysis numbers the tracks again: the old pictures go)."""
    tracking_file = storage.tracking_path(game_id)
    if not tracking_file.is_file():
        raise ScoutError(ErrorCode.NOT_FOUND, "This game has no analysis yet, so there are no pictures of its players.")
    stamp = tracking_file.stat().st_mtime_ns
    with _index_guard:
        lock = _index_locks.setdefault(game_id, threading.Lock())
    with lock:
        path = _index_path(game_id)
        if path.is_file():
            try:
                index = storage.read_json(path)
                if index.get("tracking") == stamp:
                    return index
            except (OSError, ValueError):
                pass
        shutil.rmtree(storage.previews_dir(game_id), ignore_errors=True)
        tracking = pipeline.load_tracking(tracking_file)
        index = {
            "tracking": stamp,
            "fps": tracking.video.fps,
            "width": tracking.video.width,
            "height": tracking.video.height,
            "views": {str(tid): [[v.frame, *v.box] for v in items] for tid, items in choose_views(tracking).items()},
        }
        storage.write_json(path, index)
        logger.info("Game %s: chose preview moments for %d tracks", game_id, len(index["views"]))
        return index


def crop_filter(box: tuple[float, float, float, float], width: int, height: int, out_height: int) -> str:
    """ffmpeg's video filter for a picture of ``box`` with some room around it."""
    x1, y1, x2, y2 = box
    pad_x, pad_y = (x2 - x1) * MARGIN_X, (y2 - y1) * MARGIN_Y
    left, top = max(0, int(x1 - pad_x)), max(0, int(y1 - pad_y))
    right, bottom = min(width, int(x2 + pad_x + 0.5)), min(height, int(y2 + pad_y + 0.5))
    w, h = max(2, (right - left) // 2 * 2), max(2, (bottom - top) // 2 * 2)
    return f"crop={w}:{h}:{left}:{top},scale=-2:{out_height}"


def preview_image(game_id: str, track_id: int, view: int = 0, size: str = "small") -> Path:
    """The picture file for one track's ``view`` (0 is the best moment), cut from the film now if it is
    not there yet. NOT_FOUND for a view the track does not have (a short track has one or two)."""
    if size not in HEIGHTS:
        raise ScoutError(ErrorCode.VALIDATION_FAILED, "size must be small or large.")
    index = load_index(game_id)
    views = index["views"].get(str(track_id))
    if not views:
        raise ScoutError(ErrorCode.NOT_FOUND, f"Track {track_id} is not in this game's analysis.")
    if view >= len(views):
        raise ScoutError(ErrorCode.NOT_FOUND, f"Track {track_id} has {len(views)} picture(s).")
    number = view
    target = storage.previews_dir(game_id) / f"{track_id}-{number}-{size}.jpg"
    if target.is_file():
        return target
    film = storage.find_source_video(game_id)
    if film is None:
        raise ScoutError(
            ErrorCode.NOT_FOUND,
            "The film is not stored on this server, so there is no picture of this player.",
            hint="A film given as a link, or a live game that has not ended, has no pictures.",
        )
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise ScoutError(ErrorCode.NOT_FOUND, "Pictures of players need ffmpeg on the server.", hint="sudo apt install ffmpeg")
    frame, *box = views[number]
    seconds = max(0.0, (frame + 0.5) / float(index["fps"]))
    partial = target.with_suffix(f".{threading.get_ident()}.part.jpg")
    command = [
        ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
        "-ss", f"{seconds:.3f}", "-i", str(film), "-frames:v", "1",
        "-vf", crop_filter(tuple(box), int(index["width"]), int(index["height"]), HEIGHTS[size]),
        "-q:v", "4", "-f", "image2", str(partial),
    ]  # fmt: skip
    with _cutting:
        if target.is_file():  # another request cut it while this one waited
            return target
        try:
            subprocess.run(command, capture_output=True, text=True, timeout=CUT_TIMEOUT_S, check=True)
            partial.replace(target)
        except (OSError, subprocess.SubprocessError) as exc:
            partial.unlink(missing_ok=True)
            detail = getattr(exc, "stderr", "") or str(exc)
            logger.warning("Game %s: no picture of track %s: %s", game_id, track_id, str(detail).strip()[-300:])
            raise ScoutError(ErrorCode.NOT_FOUND, "The picture could not be cut from the film.") from exc
    return target
