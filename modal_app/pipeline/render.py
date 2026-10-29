"""Re-encode OpenHoopVision's annotated video for web playback.

OHV writes its overlay video with ``libx264 -preset ultrafast -crf 18`` at the analysed
resolution: big files that start playing only after a full download. This makes an
H.264 / yuv420p MP4 at ``render_height`` (never upscaled), CRF ~26, ``+faststart``.
NVENC is used when ffmpeg can actually open it inside the container (probed once,
undocumented on Modal); otherwise libx264 ``veryfast``. The frame rate and frame count
are untouched, so the duration -- and every timestamp -- matches the source film.
"""

from __future__ import annotations

import functools
import logging
import os
import subprocess
from pathlib import Path

from modal_app.pipeline import errors
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.video import FractionProgress, run_ffmpeg

logger = logging.getLogger(__name__)

NVENC = "h264_nvenc"
X264 = "libx264"
_ENCODER_OPTIONS = {
    NVENC: ["-c:v", NVENC, "-preset", "p5", "-rc", "vbr", "-cq", "28", "-b:v", "0", "-profile:v", "high"],
    X264: ["-c:v", X264, "-preset", "veryfast", "-crf", "26", "-profile:v", "high"],
}


@functools.lru_cache(maxsize=1)
def nvenc_available() -> bool:
    """True when this machine's ffmpeg can encode with NVENC (tested with a tiny clip)."""
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=256x144:r=10",
        "-frames:v", "5", "-c:v", NVENC, "-f", "null", "-",
    ]  # fmt: skip
    try:
        ok = subprocess.run(cmd, capture_output=True, timeout=60, check=False).returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        ok = False
    logger.info("NVENC %s", "available" if ok else "not available; using libx264")
    return ok


def build_render_command(
    src: str, dst: str, *, target_height: int, source_height: int | None, encoder: str
) -> list[str]:
    """ffmpeg command for the web copy. Scales down only when the source is taller."""
    cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
    cmd += ["-i", src, "-map", "0:v:0", "-an", "-sn", "-dn"]
    if source_height is None or source_height > target_height:
        cmd += ["-vf", f"scale=-2:'min({target_height},ih)'"]
    cmd += ["-pix_fmt", "yuv420p", *_ENCODER_OPTIONS[encoder], "-movflags", "+faststart"]
    cmd += ["-progress", "pipe:1", "-nostats", dst]
    return cmd


def render_web_video(
    src: str | os.PathLike[str],
    dst: str | os.PathLike[str],
    *,
    target_height: int = 720,
    source_height: int | None = None,
    expected_frames: int = 0,
    progress: FractionProgress | None = None,
) -> str:
    """Encode ``src`` to ``dst`` (atomically); return the encoder used.

    Tries NVENC first when available and falls back to libx264; raises PipelineError
    (PIPELINE_FAILED) if both fail.
    """
    dst = Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(f".{dst.stem}.tmp.mp4")
    encoders = [NVENC, X264] if nvenc_available() else [X264]
    failure: PipelineError | None = None
    for encoder in encoders:
        cmd = build_render_command(
            str(src), str(tmp), target_height=target_height, source_height=source_height, encoder=encoder
        )
        try:
            run_ffmpeg(
                cmd,
                expected_frames=expected_frames,
                progress=progress,
                message="Encoding the annotated video",
                error_code=errors.PIPELINE_FAILED,
                error_message="The annotated video could not be encoded.",
            )
        except PipelineError as exc:
            logger.warning("%s encode failed: %s", encoder, exc.detail)
            tmp.unlink(missing_ok=True)
            failure = exc
            continue
        os.replace(tmp, dst)
        return encoder
    assert failure is not None
    raise failure
