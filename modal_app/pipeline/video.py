"""Video probing, validation, download and the optional analysis pre-transcode.

Everything that shells out (ffprobe / ffmpeg / HTTP) is a thin wrapper around a pure
helper (``parse_ffprobe_json``, ``plan_analysis``, ``build_transcode_command``,
``parse_progress_frame`` ...) so the logic is unit-testable without ffmpeg or a network.

Why pre-transcode: OpenHoopVision analyses EVERY decoded frame. Re-encoding a 30 fps
1080p game to 15 fps / 1280 px before the GPU stage halves GPU time. The copy keeps the
same duration, so analysed frame ``k`` is original frame ``k * step`` (see ``FrameMap``)
and pixel coordinates scale back by ``FrameMap.scale_x/scale_y``.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Any

from modal_app.pipeline import errors
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.types import BBox, VideoMeta

logger = logging.getLogger(__name__)

FractionProgress = Callable[[float, str], None]  # (fraction 0..1, message)

DEFAULT_MAX_DOWNLOAD_BYTES = 20 * 1024**3
_DOWNLOAD_CHUNK = 8 * 1024 * 1024
_DOWNLOAD_ATTEMPTS = 3
_PROBE_TIMEOUT_S = 120
# Codecs OpenCV decodes reliably as they are. Anything else (HEVC / 10-bit phone film,
# ProRes, VP9 ...) is normalised to 8-bit H.264 by the pre-transcode.
_PASSTHROUGH_CODECS = frozenset({"h264"})


# ---------------------------------------------------------------------------
# Probe
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class VideoProbe:
    """What ffprobe says about a film (dimensions are in display orientation)."""

    path: str
    fps: float
    fps_rational: str  # e.g. "30000/1001", used verbatim for the ffmpeg fps filter
    width: int
    height: int
    duration_s: float
    frame_count: int
    codec: str | None = None
    format_name: str | None = None
    size_bytes: int | None = None
    rotation: int = 0


def parse_rate(text: str | None) -> Fraction | None:
    """``"30000/1001"`` / ``"25"`` -> Fraction; ``None`` for empty, zero or garbage rates."""
    if not text:
        return None
    try:
        rate = Fraction(str(text).strip())
    except (ValueError, ZeroDivisionError):
        return None
    return rate if 1 <= rate <= 240 else None


def _rotation(stream: dict[str, Any]) -> int:
    raw = (stream.get("tags") or {}).get("rotate")
    for side in stream.get("side_data_list") or ():
        if "rotation" in side:
            raw = side["rotation"]
    try:
        return int(float(raw)) % 360 if raw is not None else 0
    except (TypeError, ValueError):
        return 0


def _to_float(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def parse_ffprobe_json(data: dict[str, Any], *, path: str) -> VideoProbe:
    """Turn ``ffprobe -show_format -show_streams -of json`` output into a VideoProbe.

    fps comes from ``avg_frame_rate`` (falls back to ``r_frame_rate``); the frame count is
    the container's ``nb_frames`` when present, else ``duration * fps``.
    """
    streams = data.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video" and not _is_cover_art(s)), None)
    if video is None:
        raise PipelineError(errors.VIDEO_INVALID, "The file has no video track.")
    fmt = data.get("format") or {}

    rate = parse_rate(video.get("avg_frame_rate")) or parse_rate(video.get("r_frame_rate"))
    width, height = int(video.get("width") or 0), int(video.get("height") or 0)
    if rate is None or width <= 0 or height <= 0:
        raise PipelineError(
            errors.VIDEO_DECODE_FAILED,
            "The video's frame rate or size could not be read.",
            detail=f"avg_frame_rate={video.get('avg_frame_rate')} width={width} height={height}",
        )
    rotation = _rotation(video)
    if rotation in (90, 270):
        width, height = height, width

    fps = float(rate)
    duration = _to_float(fmt.get("duration")) or _to_float(video.get("duration")) or 0.0
    nb_frames = int(_to_float(video.get("nb_frames")) or 0)
    frame_count = nb_frames if nb_frames > 0 else int(round(duration * fps))
    if duration <= 0 and nb_frames > 0:
        duration = nb_frames / fps
    size = _to_float(fmt.get("size"))
    return VideoProbe(
        path=path,
        fps=fps,
        fps_rational=f"{rate.numerator}/{rate.denominator}",
        width=width,
        height=height,
        duration_s=round(duration, 3),
        frame_count=frame_count,
        codec=video.get("codec_name"),
        format_name=fmt.get("format_name"),
        size_bytes=int(size) if size else None,
        rotation=rotation,
    )


def _is_cover_art(stream: dict[str, Any]) -> bool:
    return bool((stream.get("disposition") or {}).get("attached_pic"))


def probe_video(path: str | os.PathLike[str]) -> VideoProbe:
    """Run ffprobe on ``path`` (raises PipelineError VIDEO_INVALID / VIDEO_DECODE_FAILED)."""
    path = str(path)
    if not os.path.isfile(path):
        raise PipelineError(errors.VIDEO_INVALID, "The video file was not found.", detail=path)
    cmd = ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=_PROBE_TIMEOUT_S, check=False)
    except FileNotFoundError as exc:
        raise PipelineError(errors.PIPELINE_FAILED, "ffprobe is not installed on the GPU worker.") from exc
    except subprocess.TimeoutExpired as exc:
        raise PipelineError(errors.VIDEO_DECODE_FAILED, "Reading the video's details timed out.") from exc
    if proc.returncode != 0:
        raise PipelineError(
            errors.VIDEO_INVALID,
            "The file is not a video that can be read.",
            detail=proc.stderr.decode("utf-8", "replace")[-2000:],
        )
    try:
        data = json.loads(proc.stdout or b"{}")
    except json.JSONDecodeError as exc:
        raise PipelineError(errors.VIDEO_INVALID, "The file is not a video that can be read.") from exc
    return parse_ffprobe_json(data, path=path)


def validate_probe(probe: VideoProbe, *, max_duration_s: float | None) -> None:
    """Reject empty or over-long films before any GPU time is spent."""
    if probe.duration_s <= 0 or probe.frame_count <= 0:
        raise PipelineError(errors.VIDEO_DECODE_FAILED, "The video has no readable frames.")
    if max_duration_s and probe.duration_s > max_duration_s:
        raise PipelineError(
            errors.VIDEO_TOO_LONG,
            f"The film is {probe.duration_s / 60:.0f} minutes long; the limit is {max_duration_s / 60:.0f} minutes.",
        )


def check_decodable(path: str | os.PathLike[str]) -> None:
    """Decode the first few frames so corrupt files fail fast (VIDEO_DECODE_FAILED)."""
    cmd = [
        "ffmpeg", "-hide_banner", "-nostdin", "-v", "error",
        "-i", str(path), "-map", "0:v:0", "-frames:v", "3", "-f", "null", "-",
    ]  # fmt: skip
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=_PROBE_TIMEOUT_S, check=False)
    except FileNotFoundError as exc:
        raise PipelineError(errors.PIPELINE_FAILED, "ffmpeg is not installed on the GPU worker.") from exc
    except subprocess.TimeoutExpired as exc:
        raise PipelineError(errors.VIDEO_DECODE_FAILED, "Decoding the first frames timed out.") from exc
    if proc.returncode != 0:
        raise PipelineError(
            errors.VIDEO_DECODE_FAILED,
            "The video could not be decoded.",
            detail=proc.stderr.decode("utf-8", "replace")[-2000:],
        )


# ---------------------------------------------------------------------------
# Analysis plan + frame mapping
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class FrameMap:
    """Maps frames and pixels of the analysed copy back to the ORIGINAL video."""

    source_fps: float
    analysed_fps: float
    scale_x: float = 1.0
    scale_y: float = 1.0

    @classmethod
    def identity(cls, fps: float) -> FrameMap:
        return cls(source_fps=fps, analysed_fps=fps)

    def to_original(self, analysed_frame: int) -> int:
        """0-based analysed frame -> 0-based original frame (same timestamp)."""
        if self.analysed_fps == self.source_fps:
            return int(analysed_frame)
        return int(round(analysed_frame * self.source_fps / self.analysed_fps))

    def point(self, x: float, y: float) -> tuple[float, float]:
        return (float(x) * self.scale_x, float(y) * self.scale_y)

    def bbox(self, box: BBox) -> BBox:
        x1, y1, x2, y2 = box
        return (x1 * self.scale_x, y1 * self.scale_y, x2 * self.scale_x, y2 * self.scale_y)


@dataclass(frozen=True)
class AnalysisPlan:
    """How the film will be analysed: rate, size, and whether a pre-transcode is needed."""

    meta: VideoMeta  # the ORIGINAL video (frames/pixels in results refer to it)
    step: int  # analyse every step-th original frame
    fps_rational: str  # analysed frame rate for ffmpeg, e.g. "30000/2002"
    width: int  # analysed resolution
    height: int
    transcode: bool
    frame_map: FrameMap

    @property
    def analysed_fps(self) -> float:
        return self.meta.analysis_fps

    @property
    def expected_frames(self) -> int:
        """Frames OpenHoopVision will see (used for progress)."""
        return max(1, int(round(self.meta.duration_s * self.analysed_fps)))


def _even(value: float) -> int:
    return max(2, int(round(value / 2.0)) * 2)


def plan_analysis(
    probe: VideoProbe,
    *,
    filename: str,
    analysis_fps: float = 15.0,
    max_side: int = 1280,
    force_transcode: bool = False,
) -> AnalysisPlan:
    """Choose the analysis rate/size. ``step = round(fps / analysis_fps)`` like the server."""
    step = max(1, int(round(probe.fps / analysis_fps))) if analysis_fps > 0 else 1
    rate = Fraction(probe.fps_rational) / step
    longest = max(probe.width, probe.height)
    if max_side and longest > max_side:
        factor = max_side / longest
        width, height = _even(probe.width * factor), _even(probe.height * factor)
    else:
        width, height = probe.width - probe.width % 2, probe.height - probe.height % 2
    resized = (width, height) != (probe.width, probe.height)
    transcode = force_transcode or step > 1 or resized or (probe.codec or "").lower() not in _PASSTHROUGH_CODECS
    if not transcode:
        width, height = probe.width, probe.height
    analysed_fps = float(rate) if transcode else probe.fps
    meta = VideoMeta(
        path=probe.path,
        filename=filename,
        fps=probe.fps,
        width=probe.width,
        height=probe.height,
        frame_count=probe.frame_count,
        duration_s=probe.duration_s,
        analysis_fps=analysed_fps,
        step=step if transcode else 1,
        codec=probe.codec,
    )
    frame_map = FrameMap(
        source_fps=probe.fps,
        analysed_fps=analysed_fps,
        scale_x=probe.width / width,
        scale_y=probe.height / height,
    )
    return AnalysisPlan(
        meta=meta,
        step=meta.step,
        fps_rational=f"{rate.numerator}/{rate.denominator}" if transcode else probe.fps_rational,
        width=width,
        height=height,
        transcode=transcode,
        frame_map=frame_map,
    )


# ---------------------------------------------------------------------------
# ffmpeg helpers (shared with render.py)
# ---------------------------------------------------------------------------


def parse_progress_frame(line: str) -> int | None:
    """``frame=123`` from ``ffmpeg -progress pipe:1`` output -> 123."""
    key, _, value = line.strip().partition("=")
    if key != "frame":
        return None
    try:
        return int(value)
    except ValueError:
        return None


def run_ffmpeg(
    cmd: list[str],
    *,
    expected_frames: int = 0,
    progress: FractionProgress | None = None,
    message: str = "",
    error_code: str = errors.PIPELINE_FAILED,
    error_message: str = "ffmpeg failed.",
) -> None:
    """Run an ffmpeg command that writes ``-progress pipe:1``; raise PipelineError on failure."""
    with tempfile.TemporaryFile() as stderr_file:
        try:
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=stderr_file)
        except FileNotFoundError as exc:
            raise PipelineError(errors.PIPELINE_FAILED, "ffmpeg is not installed on the GPU worker.") from exc
        try:
            assert proc.stdout is not None
            for raw in proc.stdout:
                frame = parse_progress_frame(raw.decode("utf-8", "replace"))
                if frame is not None and progress is not None and expected_frames > 0:
                    progress(min(1.0, frame / expected_frames), message)
            returncode = proc.wait()
        finally:
            if proc.poll() is None:  # cancelled (e.g. Modal InputCancellation): stop ffmpeg too
                proc.kill()
                proc.wait()
        if returncode != 0:
            stderr_file.seek(0)
            tail = stderr_file.read()[-4000:].decode("utf-8", "replace")
            raise PipelineError(error_code, error_message, detail=tail.strip() or f"ffmpeg exit code {returncode}")


def build_transcode_command(src: str, dst: str, plan: AnalysisPlan) -> list[str]:
    """ffmpeg command for the analysis copy: constant analysed fps, even size, H.264, no audio."""
    filters = [f"fps={plan.fps_rational}"]
    if (plan.width, plan.height) != (plan.meta.width, plan.meta.height):
        filters.append(f"scale={plan.width}:{plan.height}:flags=bicubic")
    return [
        "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
        "-i", src,
        "-map", "0:v:0", "-an", "-sn", "-dn",
        "-vf", ",".join(filters),
        "-pix_fmt", "yuv420p",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-progress", "pipe:1", "-nostats",
        dst,
    ]  # fmt: skip


def transcode_for_analysis(
    src: str | os.PathLike[str],
    dst: str | os.PathLike[str],
    plan: AnalysisPlan,
    *,
    progress: FractionProgress | None = None,
) -> Path:
    """Write the analysis copy described by ``plan`` (VIDEO_DECODE_FAILED on failure)."""
    dst = Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    run_ffmpeg(
        build_transcode_command(str(src), str(dst), plan),
        expected_frames=plan.expected_frames,
        progress=progress,
        message=f"Preparing the film for analysis ({plan.width}x{plan.height}, {plan.analysed_fps:.1f} fps)",
        error_code=errors.VIDEO_DECODE_FAILED,
        error_message="The film could not be decoded while preparing it for analysis.",
    )
    return dst


# ---------------------------------------------------------------------------
# URL download
# ---------------------------------------------------------------------------


def download_video(
    url: str,
    dest: str | os.PathLike[str],
    *,
    max_bytes: int = DEFAULT_MAX_DOWNLOAD_BYTES,
    timeout_s: float = 60.0,
    progress: FractionProgress | None = None,
) -> Path:
    """Stream ``url`` to ``dest`` (via ``dest.part``). Reuses a finished download.

    Raises PipelineError(VIDEO_DOWNLOAD_FAILED) with a coach-readable reason.
    """
    dest = Path(dest)
    if not url.lower().startswith(("http://", "https://")):
        raise PipelineError(errors.VIDEO_DOWNLOAD_FAILED, "Only http(s) video links are supported.", detail=url[:200])
    if dest.is_file() and dest.stat().st_size > 0:
        logger.info("reusing finished download %s", dest)
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    last_error: PipelineError | None = None
    for attempt in range(1, _DOWNLOAD_ATTEMPTS + 1):
        try:
            _download_once(url, dest, max_bytes=max_bytes, timeout_s=timeout_s, progress=progress)
            return dest
        except _RetryableDownloadError as exc:
            last_error = exc.error
            logger.warning("download attempt %d/%d failed: %s", attempt, _DOWNLOAD_ATTEMPTS, exc.error.detail)
            if attempt < _DOWNLOAD_ATTEMPTS:
                time.sleep(2.0 * attempt)
    assert last_error is not None
    raise last_error


class _RetryableDownloadError(Exception):
    def __init__(self, error: PipelineError) -> None:
        super().__init__(error.message)
        self.error = error


def _download_once(
    url: str, dest: Path, *, max_bytes: int, timeout_s: float, progress: FractionProgress | None
) -> None:
    part = dest.with_name(dest.name + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "basketball-scout/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=timeout_s) as response:
            content_type = (response.headers.get("Content-Type") or "").lower()
            if content_type.startswith(("text/html", "application/json", "text/plain")):
                raise PipelineError(
                    errors.VIDEO_DOWNLOAD_FAILED,
                    "The link opens a web page, not a video file. Use a direct MP4 download link.",
                    detail=f"Content-Type: {content_type}",
                )
            total = int(response.headers.get("Content-Length") or 0)
            if total > max_bytes:
                raise PipelineError(
                    errors.VIDEO_DOWNLOAD_FAILED, _too_large(max_bytes), detail=f"Content-Length: {total}"
                )
            received = 0
            with open(part, "wb") as fh:
                while chunk := response.read(_DOWNLOAD_CHUNK):
                    received += len(chunk)
                    if received > max_bytes:
                        raise PipelineError(errors.VIDEO_DOWNLOAD_FAILED, _too_large(max_bytes))
                    fh.write(chunk)
                    if progress is not None and total:
                        message = f"Downloading film ({received / 1e6:.0f} of {total / 1e6:.0f} MB)"
                        progress(min(1.0, received / total), message)
        if received == 0:
            raise PipelineError(errors.VIDEO_DOWNLOAD_FAILED, "The link returned an empty file.")
        if total and received < total:
            stopped = PipelineError(
                errors.VIDEO_DOWNLOAD_FAILED,
                "The download stopped before the end of the file.",
                detail=f"{received}/{total} bytes",
            )
            raise _RetryableDownloadError(stopped)
        os.replace(part, dest)
    except urllib.error.HTTPError as exc:
        error = PipelineError(
            errors.VIDEO_DOWNLOAD_FAILED, f"The video link returned HTTP {exc.code}.", detail=str(exc.reason)
        )
        if exc.code >= 500 or exc.code == 429:
            raise _RetryableDownloadError(error) from exc
        raise error from exc
    except OSError as exc:  # URLError, timeouts, resets, local disk errors
        raise _RetryableDownloadError(
            PipelineError(errors.VIDEO_DOWNLOAD_FAILED, "The video link could not be reached.", detail=str(exc)[:500])
        ) from exc
    finally:
        part.unlink(missing_ok=True)


def _too_large(max_bytes: int) -> str:
    return f"The video is larger than the {max_bytes / 1024**3:.0f} GB download limit."
