"""Game time: the stretches of the film that are the game (docs/ARCHITECTURE.md, "Game time").

A recording usually starts with warm-ups, has more of them at halftime and runs on after the
final horn. The coach marks where the game is (``Game.play_ranges``, in film seconds); then

* ``clip_tracking`` keeps only what the GPU saw inside the marks, so warm-up shots are not
  stats, time on the floor is game time, and a jersey number read off a warm-up top is not used;
* ``cut_film`` + ``restore_film_times`` send only the marked stretches to the GPU (less film:
  faster and cheaper) and then put the results back on the whole film's clock, so every event
  still points at the right moment of the film the coach watches.

The film itself is never changed.
"""

from __future__ import annotations

import logging
import shutil
import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from scout.errors import ErrorCode, ScoutError
from scout.schemas import PipelineWarning, RawEventType, TimeRange, TrackingResult

logger = logging.getLogger(__name__)

MAX_RANGES = 8
MIN_RANGE_S = 5.0
GAME_TIME_CODE = "GAME_TIME_ONLY"
CUT_TIMEOUT_S = 3600.0
_STRUCTURE = frozenset({RawEventType.PERIOD_START, RawEventType.PERIOD_END})


def check_ranges(ranges: Sequence[TimeRange]) -> list[TimeRange]:
    """The marks in film order, or VALIDATION_FAILED when they overlap or run backwards."""
    ordered = sorted(ranges, key=lambda r: r.start_s)
    if len(ordered) > MAX_RANGES:
        raise ScoutError(ErrorCode.VALIDATION_FAILED, f"At most {MAX_RANGES} stretches of game time can be marked.")
    previous_end = 0.0
    for index, item in enumerate(ordered):
        if item.end_s - item.start_s < MIN_RANGE_S:
            raise ScoutError(
                ErrorCode.VALIDATION_FAILED,
                f"Each stretch of game time must end after it starts ({clock(item.start_s)} to {clock(item.end_s)}).",
            )
        if index and item.start_s < previous_end:
            raise ScoutError(ErrorCode.VALIDATION_FAILED, "The stretches of game time overlap.", hint="Halftime must end after it starts.")
        previous_end = item.end_s
    return ordered


def clock(seconds: float) -> str:
    whole = max(0, round(seconds))
    hours, rest = divmod(whole, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def describe(ranges: Sequence[TimeRange]) -> str:
    return ", ".join(f"{clock(r.start_s)}-{clock(r.end_s)}" for r in ranges)


# ---------------------------------------------------------------------------
# Counting only game time
# ---------------------------------------------------------------------------


def clip_tracking(tracking: TrackingResult, ranges: Sequence[TimeRange]) -> TrackingResult:
    """``tracking`` with only what lies inside ``ranges``; the periods are found again on what is left
    (the gap between two stretches is the halftime the coach marked)."""
    if not ranges:
        return tracking
    fps = tracking.video.fps
    windows = [(round(r.start_s * fps), round(r.end_s * fps)) for r in check_ranges(ranges)]

    def inside(frame: int) -> bool:
        return any(a <= frame <= b for a, b in windows)

    tracks = []
    for track in tracking.tracks:
        samples = [s for s in track.samples if inside(s.f)]
        if samples:
            reads = [r for r in track.jersey_reads if inside(r.frame)]
            tracks.append(track.model_copy(update={"samples": samples, "jersey_reads": reads}))
    kept = {t.track_id for t in tracks}
    events = [
        e
        for e in tracking.events
        if inside(e.frame)
        and e.type not in _STRUCTURE
        and not (e.type == RawEventType.TIMEOUT and e.attrs.get("inferred"))
        and (e.track_id is None or e.track_id in kept)
    ]
    ball = [b for b in tracking.ball if inside(b.f)]
    warnings = [w for w in tracking.warnings if w.code != GAME_TIME_CODE]
    warnings.append(
        PipelineWarning(
            code=GAME_TIME_CODE,
            message=f"Only the marked game time is counted: {describe(ranges)}. Warm-ups and breaks outside it are left out.",
            severity="info",
        )
    )
    clipped = tracking.model_copy(update={"tracks": tracks, "ball": ball, "events": events, "warnings": warnings})
    from scout.analysis.live_merge import rebuild_periods  # it imports the GPU package's detector lazily

    return rebuild_periods(clipped)


# ---------------------------------------------------------------------------
# Sending only game time to the GPU
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Piece:
    """One stretch as it was cut: where it starts in the whole film, and how long the cut is.

    A cut without re-encoding starts on the key frame before the mark, so it can begin a moment early."""

    start_s: float
    duration_s: float


@dataclass(frozen=True)
class CutFilm:
    path: Path
    pieces: list[Piece]
    film_duration_s: float


def cut_film(source: Path, ranges: Sequence[TimeRange], work_dir: Path) -> CutFilm | None:
    """Copy the marked stretches of ``source`` into one shorter film (no re-encoding).

    None when it cannot be done (no ffmpeg or ffprobe here, or they failed): the whole film is
    analysed then, and ``clip_tracking`` still leaves the rest out of the stats.
    """
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if ffmpeg is None or ffprobe is None:
        logger.info("ffmpeg is not installed: the whole film goes to the GPU")
        return None
    shutil.rmtree(work_dir, ignore_errors=True)
    work_dir.mkdir(parents=True)
    try:
        film_duration = _duration(ffprobe, source)
        pieces: list[Piece] = []
        names: list[str] = []
        for index, item in enumerate(check_ranges(ranges)):
            end = min(item.end_s, film_duration)
            if end - item.start_s < 1.0:
                continue
            name = f"piece-{index:02d}{source.suffix.lower() or '.mp4'}"
            command = [
                ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                "-ss", f"{item.start_s:.3f}", "-to", f"{end:.3f}", "-i", str(source),
                "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-avoid_negative_ts", "make_zero", name,
            ]  # fmt: skip
            subprocess.run(command, capture_output=True, text=True, timeout=CUT_TIMEOUT_S, check=True, cwd=work_dir)
            length = _duration(ffprobe, work_dir / name)
            pieces.append(Piece(start_s=max(0.0, end - length), duration_s=length))
            names.append(name)
        if not pieces:
            return None
        listing = work_dir / "pieces.txt"
        listing.write_text("".join(f"file '{name}'\n" for name in names), encoding="utf-8")
        target = work_dir / f"game-time{source.suffix.lower() or '.mp4'}"
        join = [
            ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-f", "concat", "-safe", "0", "-i", listing.name, "-c", "copy", target.name,
        ]  # fmt: skip
        subprocess.run(join, capture_output=True, text=True, timeout=CUT_TIMEOUT_S, check=True, cwd=work_dir)
        for name in names:
            (work_dir / name).unlink(missing_ok=True)
        listing.unlink(missing_ok=True)
        return CutFilm(path=target, pieces=pieces, film_duration_s=film_duration)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        logger.warning("Could not cut the film to the game time (%s): the whole film goes to the GPU", str(detail).strip()[-300:])
        shutil.rmtree(work_dir, ignore_errors=True)
        return None


def _duration(ffprobe: str, path: Path) -> float:
    command = [ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)]
    out = subprocess.run(command, capture_output=True, text=True, timeout=120, check=True).stdout
    seconds = float(out.strip())
    if not seconds > 0:
        raise ValueError(f"no duration for {path.name}")
    return seconds


def restore_film_times(tracking: TrackingResult, pieces: Sequence[Piece], film_duration_s: float) -> TrackingResult:
    """Results for a film cut with ``cut_film``, moved back onto the whole film's clock."""
    fps = tracking.video.fps
    starts: list[tuple[float, float]] = []  # (where the piece begins in the cut film, in the whole film)
    at = 0.0
    for piece in pieces:
        starts.append((at, piece.start_s))
        at += piece.duration_s

    def frame(f: int) -> int:
        t = f / fps
        cut_start, film_start = starts[0]
        for candidate in starts:
            if t + 1e-6 >= candidate[0]:
                cut_start, film_start = candidate
        return round((film_start + (t - cut_start)) * fps)

    tracks = [
        track.model_copy(
            update={
                "samples": [s.model_copy(update={"f": frame(s.f)}) for s in track.samples],
                "jersey_reads": [r.model_copy(update={"frame": frame(r.frame)}) for r in track.jersey_reads],
            }
        )
        for track in tracking.tracks
    ]
    events = []
    for event in tracking.events:
        moved = frame(event.frame)
        events.append(event.model_copy(update={"frame": moved, "t": round(moved / fps, 3)}))
    span = lambda item: {  # noqa: E731
        "frame_start": frame(item.frame_start),
        "frame_end": None if item.frame_end is None else frame(item.frame_end),
    }
    court = tracking.court.model_copy(update={"homographies": [h.model_copy(update=span(h)) for h in tracking.court.homographies]})
    video = tracking.video.model_copy(update={"frame_count": round(film_duration_s * fps), "duration_s": round(film_duration_s, 3)})
    return tracking.model_copy(
        update={
            "video": video,
            "tracks": tracks,
            "ball": [b.model_copy(update={"f": frame(b.f)}) for b in tracking.ball],
            "events": events,
            "court": court,
            "rims": [r.model_copy(update=span(r)) for r in tracking.rims],
        }
    )
