"""Run OpenHoopVision (OHV) as a subprocess and describe how it was run.

OHV (https://github.com/feifeifei85/OpenHoopVision) is the computer-vision engine:
RF-DETR detection, RTMPose-S skeletons, MobileNetV4 court keypoints, a McByte/ByteTrack
tracker with OSNet ReID, SVTRv2-B jersey OCR and its own shot/pass/rebound/turnover
events. We never import it into this process: ``python main.py`` runs in its checkout
(``OHV_HOME``, default ``/opt/openhoopvision``) through a tiny bootstrap that first
patches OHV's NBA-only court template with the real gym's dimensions (the court-keypoint
model finds painted features, so the template must match the floor or every court
coordinate is wrong).

Progress comes from counting lines of the growing per-frame JSONL; stdout/stderr are
captured for warnings and error messages. CUDA out-of-memory crashes are retried with
smaller batches (``OOM_LADDER``) before giving up with GPU_OOM.

Licence note: OHV's README says Apache-2.0, but the pinned commit has no LICENSE file
(GitHub reports ``license: null``). Confirm with the author before redistributing it.
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
from collections import deque
from collections.abc import Callable
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import IO, Any

from modal_app.pipeline import errors
from modal_app.pipeline.errors import PipelineError

logger = logging.getLogger(__name__)

FractionProgress = Callable[[float, str], None]  # (fraction 0..1, message)

OHV_REPO_URL = "https://github.com/feifeifei85/OpenHoopVision.git"
OHV_COMMIT = "ec969037b2c02b983a77b260c50cb9eb36fe9fc1"  # 2026-10-26; pinned, OHV is 2 weeks old
DEFAULT_OHV_HOME = "/opt/openhoopvision"

# The GPU stack validated by OHV's requirements.lock (CUDA 13.0), exactly. OpenCV stays the
# GUI build the lock names: supervision / rfdetr depend on opencv-python themselves, so a
# headless swap would install two cv2 builds over each other. Its cv2 needs libGL.so.1
# (libgl1 in the Modal image).
TORCH_INDEX_URL = "https://download.pytorch.org/whl/cu130"
TORCH_REQUIREMENTS = ("torch==2.12.1+cu130", "torchvision==0.27.1+cu130")
OHV_REQUIREMENTS = (
    "rfdetr==1.10.1",
    "supervision==0.30.1",
    "numpy==2.3.5",
    "opencv-python==5.0.0.93",
    "scipy==1.18.1",
    "pillow==10.2.0",
    "tqdm==4.70.0",
)


@dataclass(frozen=True)
class WeightFile:
    """One OHV checkpoint. OHV stores them as Git LFS objects and never downloads them itself."""

    name: str
    sha256: str
    size: int
    flag: str  # main.py option that points at it

    @property
    def url(self) -> str:
        return f"https://media.githubusercontent.com/media/feifeifei85/OpenHoopVision/{OHV_COMMIT}/weights/{self.name}"


# sha256 + size from the LFS pointer files at OHV_COMMIT.
WEIGHTS: tuple[WeightFile, ...] = (
    WeightFile("rf-detr-basketball.pth", "69409cbefc4b92c3cd194fb7f877c6e58e52548909e05e3b5467fe0e2fe188c5", 129499889, "--model"),
    WeightFile("rtmpose-s_simcc-aic-coco.pth", "59ce6cc5c4c3bd31566c51f1b9b3bf390eb7677f8caa1f75b8f8090b1271b8a9", 22051059, "--pose-checkpoint"),
    WeightFile("osnet_x1_0_msmt17.pt", "48df972f72887b95cf3b43b3a07c3a7d2398381aea0f9cae64a7ef11d512b727", 17273805, "--reid-model"),
    WeightFile("basketball_jersey_number.ckpt", "c80048eaa1fb746dae88e71c208ef543d10f0427729e928aee84c3af34e73cbf", 79108911, "--jersey-ocr-model"),
    WeightFile("court_mobilenetv4_896x512.pt", "49c3ce2d9228a5b5458d2f54ff4462725206e02d349624b526a1903071c1f11c", 5668267, "--court-model"),
)  # fmt: skip

# Every option the pinned main.py accepts. build_command never passes anything else.
OHV_FLAGS = frozenset(
    {
        "--video", "--model", "--pose-checkpoint", "--reid-model", "--jersey-ocr-model", "--court-model",
        "--output", "--tracks", "--events", "--player-threshold", "--ball-threshold", "--rim-threshold",
        "--holder-threshold", "--scorer-threshold", "--referee-threshold", "--ball-in-basket-threshold",
        "--short-side", "--detector-batch-size", "--cmc-interval", "--track-buffer", "--trail-length",
        "--pose-batch-size", "--pose-interval", "--team-cache-ttl-seconds", "--court-interval",
        "--holder-hold-frames", "--max-frames",
    }
)  # fmt: skip

NO_CUDA_EXIT_CODE = 86  # bootstrap exit code when OHV_REQUIRE_CUDA=1 but torch sees no GPU
STALL_TIMEOUT_S = 30 * 60  # no output / no file growth for this long -> assume OHV hung
OOM_RECOVERED = "GPU_OOM_RECOVERED"

_FT = 0.3048
# Frame-count options in main.py are tuned for ~30 fps film.
_REFERENCE_FPS = 30.0
# tracking.court.COURT_MAP_MAX_AGE_FRAMES: a court map older than this is ignored, so court
# keypoints must be re-run at least this often.
_COURT_MAP_MAX_AGE_FRAMES = 5


# ---------------------------------------------------------------------------
# Court geometry patch
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CourtSpec:
    """The gym's floor in feet (NFHS / high-school defaults, see config/court.yaml)."""

    length_ft: float = 84.0
    width_ft: float = 50.0
    lane_width_ft: float = 12.0
    ft_line_from_baseline_ft: float = 19.0
    basket_from_baseline_ft: float = 5.25
    three_pt_radius_ft: float = 19.75
    three_pt_corner_lateral_ft: float = 19.75
    ft_circle_radius_ft: float = 6.0
    restricted_radius_ft: float = 4.0
    sideline_mark_ft: float = 28.0  # coaching-box / throw-in mark on the sideline

    def to_ohv_patch(self) -> dict[str, Any]:
        """Values for OHV's ``tracking.court`` (metres; key names are OHV's).

        OHV keypoint meaning (``default_nba_court_vertices``): ``baseline_offset_m`` is the
        sideline-to-straight-corner-three distance, ``baseline_key_distance_m`` is where the
        straight corner segment meets the arc, ``three_point_corner_x_m`` is the sideline
        hash mark (OHV: 8.35 m) and ``three_point_center_x_m`` the top of the arc.
        """
        width_m = self.width_ft * _FT
        basket_m = self.basket_from_baseline_ft * _FT
        radius_m = self.three_pt_radius_ft * _FT
        # NFHS corners are straight lines at the arc radius from the basket. Nudged 1 um
        # inside so OHV's sqrt(r^2 - d^2) never sees a negative rounding error.
        lateral_m = min(self.three_pt_corner_lateral_ft, self.three_pt_radius_ft) * _FT - 1e-6
        return {
            "length_m": self.length_ft * _FT,
            "width_m": width_m,
            "geometry": {
                "lane_half_width_m": self.lane_width_ft * _FT / 2,
                "paint_width_m": self.lane_width_ft * _FT,
                "baseline_offset_m": width_m / 2 - lateral_m,
                "baseline_key_distance_m": basket_m + math.sqrt(max(0.0, radius_m**2 - lateral_m**2)),
                "free_throw_line_m": self.ft_line_from_baseline_ft * _FT,
                "free_throw_radius_m": self.ft_circle_radius_ft * _FT,
                "basket_offset_m": basket_m,
                "restricted_area_radius_m": self.restricted_radius_ft * _FT,
                "three_point_radius_m": radius_m,
                "three_point_center_x_m": basket_m + radius_m,
                "three_point_corner_x_m": self.sideline_mark_ft * _FT,
            },
        }


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class OhvParams:
    """main.py tuning options (defaults are OHV's)."""

    detector_batch_size: int = 16
    pose_batch_size: int = 32
    short_side: int = 768
    court_interval: int = 5
    cmc_interval: int = 2
    track_buffer: int = 30
    holder_hold_frames: int = 12
    trail_length: int = 16
    max_frames: int | None = None

    def scaled_for_fps(self, fps: float) -> OhvParams:
        """Rescale the frame-count options (tuned at ~30 fps) to ``fps``.

        ``track_buffer`` is left alone: OHV's tracker already multiplies it by fps / 30.
        The court interval never exceeds the court map's 5-frame freshness window.
        """
        ratio = max(fps, 1.0) / _REFERENCE_FPS
        return replace(
            self,
            court_interval=min(_COURT_MAP_MAX_AGE_FRAMES, max(1, round(self.court_interval * ratio))),
            cmc_interval=min(4, max(1, round(self.cmc_interval * ratio))),
            holder_hold_frames=max(1, round(self.holder_hold_frames * ratio)),
            trail_length=max(4, round(self.trail_length * ratio)),
        )

    def capped(self, *, detector_batch_size: int, pose_batch_size: int, short_side: int) -> OhvParams:
        """Lower (never raise) the GPU-memory-hungry options."""
        return replace(
            self,
            detector_batch_size=min(self.detector_batch_size, detector_batch_size),
            pose_batch_size=min(self.pose_batch_size, pose_batch_size),
            short_side=min(self.short_side, short_side),
        )


# Retry settings after a CUDA out-of-memory crash. OHV already halves its detector batch on
# OOM inside detection; these cover OOM elsewhere (pose batches, OCR, ReID, batch size 1).
OOM_LADDER: tuple[dict[str, int], ...] = (
    {"detector_batch_size": 16, "pose_batch_size": 32, "short_side": 768},
    {"detector_batch_size": 4, "pose_batch_size": 8, "short_side": 640},
    {"detector_batch_size": 1, "pose_batch_size": 2, "short_side": 640},
)


def build_command(
    *,
    python: str,
    bootstrap: Path,
    court_file: Path,
    video: Path,
    tracks: Path,
    events: Path,
    output: Path | None,
    params: OhvParams,
    weights: dict[str, Path],
) -> list[str]:
    """Full OHV command line. Output paths are always explicit (OHV defaults write into
    the checkout's parent directory)."""
    options: list[tuple[str, Any]] = [
        ("--video", video),
        ("--output", output if output is not None else "none"),
        ("--tracks", tracks),
        ("--events", events),
        ("--detector-batch-size", params.detector_batch_size),
        ("--pose-batch-size", params.pose_batch_size),
        ("--short-side", params.short_side),
        ("--court-interval", params.court_interval),
        ("--cmc-interval", params.cmc_interval),
        ("--track-buffer", params.track_buffer),
        ("--holder-hold-frames", params.holder_hold_frames),
        ("--trail-length", params.trail_length),
    ]
    if params.max_frames is not None:
        options.append(("--max-frames", params.max_frames))
    options += [(weight.flag, weights[weight.name]) for weight in WEIGHTS]
    unknown = {flag for flag, _ in options} - OHV_FLAGS
    if unknown:  # programming error: the pinned main.py would reject the run
        raise ValueError(f"not OpenHoopVision options: {sorted(unknown)}")
    cmd = [python, str(bootstrap), str(court_file)]
    for flag, value in options:
        cmd += [flag, str(value)]
    return cmd


_BOOTSTRAP = '''"""Launch OpenHoopVision with the real gym's court (written by modal_app.pipeline.ohv).

Usage, from the OpenHoopVision checkout: python ohv_bootstrap.py COURT_JSON [main.py options]

Several OHV modules copy court constants at import time (``from tracking.court import
COURT_LENGTH_M``), so tracking.court is patched before anything else is imported.
"""
import json
import os
import sys


def main():
    court_file = sys.argv[1]
    sys.argv = ["main.py"] + sys.argv[2:]
    sys.path.insert(0, os.getcwd())
    with open(court_file, encoding="utf-8") as fh:
        patch = json.load(fh)

    import tracking.court as court

    court.COURT_LENGTH_M = float(patch["length_m"])
    court.COURT_WIDTH_M = float(patch["width_m"])
    court.COURT_GEOMETRY.update(patch["geometry"])
    court.COURT_PATHS = court.court_paths()
    print("ohv-bootstrap: court %.2f x %.2f m" % (court.COURT_LENGTH_M, court.COURT_WIDTH_M), flush=True)

    if os.environ.get("OHV_REQUIRE_CUDA") == "1":
        import torch

        if not torch.cuda.is_available():
            print("ohv-bootstrap: PyTorch cannot see a CUDA GPU", flush=True)
            sys.exit(@NO_CUDA_EXIT_CODE@)

    import main as ohv_main

    ohv_main.main()


if __name__ == "__main__":
    main()
'''.replace("@NO_CUDA_EXIT_CODE@", str(NO_CUDA_EXIT_CODE))


def write_launch_files(work_dir: Path, court: CourtSpec) -> tuple[Path, Path]:
    """Write the bootstrap script and the court patch JSON into ``work_dir``."""
    bootstrap = work_dir / "ohv_bootstrap.py"
    bootstrap.write_text(_BOOTSTRAP, encoding="utf-8")
    court_file = work_dir / "ohv_court.json"
    court_file.write_text(json.dumps(court.to_ohv_patch(), indent=2), encoding="utf-8")
    return bootstrap, court_file


# ---------------------------------------------------------------------------
# Output parsing / failure classification
# ---------------------------------------------------------------------------


_TQDM_LINE = re.compile(r"^\s*Processing\b.*%\|")
# tqdm redraws its bar as "\r<bar>" with no newline, so the next line OHV prints mid-run is
# glued onto the bar: "Processing x.mp4:  12%|█▏ | 120/1000 [00:10<01:15, 11.70frame/s]warning: ...".
_TQDM_BAR = re.compile(r"^\s*Processing\b.*?(?:\d%\|[^|]*\|[^\[]*|\d[\d.]*[kMG]?frames?\s*)\[[^\]]*\]\s*")
_TEAM_COLORS = re.compile(r"team colors \(BGR\): \[(.*?)\]")
_RGB_TRIPLE = re.compile(r"\((\d+),\s*(\d+),\s*(\d+)\)")
_FRAMES_LINE = re.compile(r"^frames: (\d+), processing: [\d.]+s, fps: ([\d.]+)")
_MODEL_LOAD_MARKERS = (
    "checkpoint not found",
    "error(s) in loading state_dict",
    "invalid load key",
    "unpicklingerror",
    "court checkpoint must use",
    "from_checkpoint",
)


@dataclass
class OhvSummary:
    """Facts OHV prints at the end of a run (all optional)."""

    team_colors_bgr: list[tuple[int, int, int]] | None = None
    detector_batch_reductions: int = 0
    frames: int | None = None
    processing_fps: float | None = None
    ocr_error: str | None = None
    reid_error: str | None = None


def parse_summary(lines: list[str]) -> OhvSummary:
    summary = OhvSummary()
    for line in lines:
        if colors := _TEAM_COLORS.search(line):
            triples = [tuple(int(v) for v in m) for m in _RGB_TRIPLE.findall(colors.group(1))]
            if len(triples) == 2:
                summary.team_colors_bgr = triples  # type: ignore[assignment]
        elif "detector batch size reduced" in line:
            summary.detector_batch_reductions += 1
        elif match := _FRAMES_LINE.match(line):
            summary.frames, summary.processing_fps = int(match.group(1)), float(match.group(2))
        elif line.startswith("warning: jersey-number OCR is unavailable"):
            summary.ocr_error = line.split(":", 2)[-1].strip()
        elif line.startswith(("warning: OSNet ReID is unavailable", "warning: OSNet ReID inference failed")):
            summary.reid_error = line.split(":", 2)[-1].strip()  # a failed batch disables ReID for the rest
    return summary


def summary_warnings(summary: OhvSummary) -> list[dict[str, str]]:
    found: list[dict[str, str]] = []
    if summary.detector_batch_reductions:
        message = "The GPU ran low on memory; player detection continued with smaller batches."
        found.append(_warning(OOM_RECOVERED, message))
    if summary.ocr_error:
        message = "Jersey numbers could not be read (the OCR model did not load); match players to the roster by hand."
        found.append(_warning("OCR_UNAVAILABLE", message))
    if summary.reid_error:
        message = "Player re-identification was unavailable; one player may show up as several tracks."
        found.append(_warning("REID_UNAVAILABLE", message))
    return found


def _warning(code: str, message: str, severity: str = "warning") -> dict[str, str]:
    return {"code": code, "message": message, "severity": severity}


def is_oom_text(text: str) -> bool:
    """True when OHV output shows a CUDA out-of-memory crash."""
    lowered = text.lower()
    return (
        "outofmemoryerror" in lowered
        or "cudaerrormemoryallocation" in lowered
        or "cublas_status_alloc_failed" in lowered
        or ("out of memory" in lowered and ("cuda" in lowered or "gpu" in lowered))
    )


def classify_failure(returncode: int, lines: list[str], frames_written: int) -> PipelineError:
    """Map a failed OHV run to the PipelineError the coach will see.

    OHV's ``warning:`` lines report problems it carried on after (e.g. the jersey OCR model
    failing to load with a CUDA OOM); they never explain the crash itself, so they are not
    searched (a recovered OOM must not make a disk-full crash rerun the film as GPU_OOM).
    """
    tail = "\n".join(lines[-40:])[-6000:]
    text = "\n".join(line for line in lines if not line.startswith("warning:")).lower()
    if returncode == NO_CUDA_EXIT_CODE:
        message = "The GPU worker could not use its GPU (PyTorch sees no CUDA device)."
        return PipelineError(errors.PIPELINE_FAILED, message, tail)
    if is_oom_text(text):
        return PipelineError(errors.GPU_OOM, "The GPU ran out of memory while analysing the film.", tail)
    if "cannot open video" in text:
        return PipelineError(errors.VIDEO_DECODE_FAILED, "OpenHoopVision could not open the video.", tail)
    if frames_written == 0 and any(marker in text for marker in _MODEL_LOAD_MARKERS):
        return PipelineError(errors.MODEL_LOAD_FAILED, "A computer-vision model could not be loaded.", tail)
    if returncode in (-9, 137):
        return PipelineError(
            errors.PIPELINE_FAILED, "The analysis process was killed (usually the worker ran out of RAM).", tail
        )
    message = f"OpenHoopVision stopped with an error (exit code {returncode})."
    return PipelineError(errors.PIPELINE_FAILED, message, tail)


class _OutputCollector(threading.Thread):
    """Drain the child's merged stdout/stderr; keep recent lines and log them."""

    def __init__(self, stream: IO[bytes], *, keep: int = 400) -> None:
        super().__init__(daemon=True)
        self.stream = stream
        self.lines: deque[str] = deque(maxlen=keep)
        self.bytes_read = 0

    def run(self) -> None:
        pending = b""
        read = getattr(self.stream, "read1", self.stream.read)
        while chunk := read(65536):
            self.bytes_read += len(chunk)
            *complete, pending = re.split(rb"[\r\n]", pending + chunk)
            for raw in complete:
                self._add(raw)
        self._add(pending)

    def _add(self, raw: bytes) -> None:
        line = raw.decode("utf-8", "replace").rstrip()
        if bar := _TQDM_BAR.match(line):  # tqdm bars: progress comes from the JSONL instead
            line = line[bar.end() :]  # keep what OHV printed after it (OCR / ReID / OOM warnings)
        if not line or _TQDM_LINE.match(line):
            return
        self.lines.append(line)
        logger.info("ohv: %s", line)


class _LineCounter:
    """Count newline-terminated records in a file that is still being written (or replaced)."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.lines = 0
        self._offset = 0
        self._inode: tuple[int, int] | None = None

    def count(self) -> int:
        try:
            stat = self.path.stat()
        except FileNotFoundError:
            return self.lines
        inode = (stat.st_dev, stat.st_ino)
        if inode != self._inode or stat.st_size < self._offset:  # OHV rewrites the file at the end
            self._inode, self._offset, self.lines = inode, 0, 0
        if stat.st_size > self._offset:
            with open(self.path, "rb") as fh:
                fh.seek(self._offset)
                while chunk := fh.read(1 << 20):
                    self.lines += chunk.count(b"\n")
                self._offset = fh.tell()
        return self.lines


def _dir_size(path: Path) -> int:
    total = 0
    for entry in path.iterdir():
        try:
            total += entry.stat().st_size if entry.is_file() else 0
        except FileNotFoundError:  # temp files come and go
            continue
    return total


# ---------------------------------------------------------------------------
# Running OHV
# ---------------------------------------------------------------------------


@dataclass
class OhvRun:
    """Where OHV wrote its outputs and how it got there."""

    tracks_path: Path
    events_path: Path
    output_video: Path | None
    params: OhvParams
    attempts: int
    summary: OhvSummary
    warnings: list[dict[str, str]] = field(default_factory=list)
    elapsed_s: float = 0.0
    log_tail: list[str] = field(default_factory=list)


def ohv_home(override: str | os.PathLike[str] | None = None) -> Path:
    return Path(override or os.environ.get("OHV_HOME") or DEFAULT_OHV_HOME)


def resolve_weights(home: Path, overrides: dict[str, str] | None = None) -> dict[str, Path]:
    """Checkpoint paths by file name; MODEL_LOAD_FAILED when one is missing or an LFS pointer.

    Paths are absolute: OHV runs in its checkout, so it would resolve a relative override from
    there instead of from where this process checked it.
    """
    paths: dict[str, Path] = {}
    for weight in WEIGHTS:
        path = Path(os.path.abspath((overrides or {}).get(weight.name) or home / "weights" / weight.name))
        if not path.is_file():
            raise PipelineError(errors.MODEL_LOAD_FAILED, f"Model file {weight.name} is missing.", detail=str(path))
        if path.stat().st_size < 1024:  # Git LFS pointer files are ~130 bytes
            raise PipelineError(
                errors.MODEL_LOAD_FAILED,
                f"Model file {weight.name} is a Git LFS placeholder, not the real weights.",
                detail=f"{path} ({path.stat().st_size} bytes); run `python -m modal_app.pipeline.ohv install`",
            )
        paths[weight.name] = path
    return paths


def run_ohv(
    video_path: str | os.PathLike[str],
    work_dir: str | os.PathLike[str],
    *,
    analysis_fps: float,
    expected_frames: int,
    court: CourtSpec,
    render: bool,
    weight_overrides: dict[str, str] | None = None,
    max_frames: int | None = None,
    progress: FractionProgress | None = None,
    home: str | os.PathLike[str] | None = None,
    python: str | None = None,
    stall_timeout_s: float = STALL_TIMEOUT_S,
    poll_interval_s: float = 2.0,
) -> OhvRun:
    """Analyse ``video_path`` with OHV; outputs land in ``work_dir``.

    Raises PipelineError: GPU_OOM (after the OOM ladder), MODEL_LOAD_FAILED,
    VIDEO_DECODE_FAILED or PIPELINE_FAILED (with the last output lines as detail).
    """
    started = time.monotonic()
    root = ohv_home(home)
    if not (root / "main.py").is_file():
        message = "OpenHoopVision is not installed on the GPU worker."
        raise PipelineError(errors.MODEL_LOAD_FAILED, message, detail=str(root))
    weights = resolve_weights(root, weight_overrides)
    work = Path(work_dir)
    work.mkdir(parents=True, exist_ok=True)
    bootstrap, court_file = write_launch_files(work, court)
    tracks, events = work / "ohv_tracks.jsonl", work / "ohv_events.json"
    output = work / "ohv_annotated.mp4" if render else None
    env = {**os.environ, "PYTHONUNBUFFERED": "1"}
    base = OhvParams(max_frames=max_frames).scaled_for_fps(analysis_fps)
    if max_frames is not None:
        expected_frames = min(expected_frames, max_frames)

    log: list[str] = []
    for attempt, limits in enumerate(OOM_LADDER, start=1):
        params = base.capped(**limits)
        for stale in (tracks, events, output):
            if stale is not None:
                stale.unlink(missing_ok=True)
        cmd = build_command(
            python=python or sys.executable, bootstrap=bootstrap, court_file=court_file, video=Path(video_path),
            tracks=tracks, events=events, output=output, params=params, weights=weights,
        )  # fmt: skip
        logger.info("starting OpenHoopVision (attempt %d): %s", attempt, " ".join(cmd))
        returncode, log, frames = _run_once(
            cmd, cwd=root, env=env, tracks=tracks, work_dir=work, expected_frames=expected_frames,
            progress=progress, stall_timeout_s=stall_timeout_s, poll_interval_s=poll_interval_s,
        )  # fmt: skip
        if returncode == 0:
            break
        failure = classify_failure(returncode, log, frames)
        if failure.code != errors.GPU_OOM:
            raise failure
        if attempt == len(OOM_LADDER):
            message = (
                f"Out of GPU memory even at detector batch size {params.detector_batch_size} "
                f"and {params.short_side}px."
            )
            raise PipelineError(errors.GPU_OOM, message, failure.detail)
        logger.warning("CUDA out of memory with %s; retrying with smaller batches", limits)

    summary = parse_summary(log)
    run_warnings = summary_warnings(summary)
    if attempt > 1:
        run_warnings.insert(
            0,
            _warning(
                OOM_RECOVERED,
                f"The GPU ran out of memory; the film was re-analysed with smaller batches "
                f"(detector batch {params.detector_batch_size}, {params.short_side}px).",
            ),
        )
    if output is not None and not output.is_file():
        output = None
    return OhvRun(
        tracks_path=tracks,
        events_path=events,
        output_video=output,
        params=params,
        attempts=attempt,
        summary=summary,
        warnings=run_warnings,
        elapsed_s=round(time.monotonic() - started, 1),
        log_tail=log[-200:],
    )


def _run_once(
    cmd: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    tracks: Path,
    work_dir: Path,
    expected_frames: int,
    progress: FractionProgress | None,
    stall_timeout_s: float,
    poll_interval_s: float,
) -> tuple[int, list[str], int]:
    """Run OHV once; return (exit code, output lines, JSONL records written)."""
    proc = subprocess.Popen(
        cmd, cwd=str(cwd), env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    assert proc.stdout is not None
    collector = _OutputCollector(proc.stdout)
    collector.start()
    counter = _LineCounter(tracks)
    fingerprint: tuple[int, int, int] | None = None
    last_change = time.monotonic()
    try:
        while proc.poll() is None:
            time.sleep(poll_interval_s)
            frames = counter.count()
            current = (frames, collector.bytes_read, _dir_size(work_dir))
            now = time.monotonic()
            if current != fingerprint:
                fingerprint, last_change = current, now
            elif now - last_change > stall_timeout_s:
                proc.kill()
                raise PipelineError(
                    errors.PIPELINE_FAILED,
                    f"OpenHoopVision stopped making progress for {stall_timeout_s / 60:.0f} minutes.",
                    detail="\n".join(list(collector.lines)[-40:]),
                )
            if progress is not None:
                progress(*_progress_point(frames, expected_frames))
        returncode = proc.wait()
    finally:
        if proc.poll() is None:  # cancelled or stalled: never leave OHV running on the GPU
            proc.kill()
            proc.wait()
        collector.join(timeout=30)
    return returncode, list(collector.lines), counter.count()


def _progress_point(frames: int, expected: int) -> tuple[float, str]:
    """Frames are 92% of OHV's work; the rest is jersey consensus and the overlay rewrite."""
    if expected > 0 and frames < expected:
        return 0.92 * frames / expected, f"Tracking players and the ball (frame {frames:,} of {expected:,})"
    return 0.92, "Finishing jersey numbers and video overlays"


def gpu_name() -> str | None:
    """Name of the first NVIDIA GPU (None without nvidia-smi)."""
    try:
        proc = subprocess.run(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"], capture_output=True, timeout=15, check=False
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    names = proc.stdout.decode("utf-8", "replace").strip().splitlines()
    return names[0].strip() if proc.returncode == 0 and names else None


# ---------------------------------------------------------------------------
# Install / verify (image build, SCOUT_PROCESSOR=local, warmup)
# ---------------------------------------------------------------------------


def weight_download_commands(weights_dir: str) -> list[str]:
    """Shell commands that download every checkpoint and fail the build on a bad sha256."""
    commands = [f"mkdir -p {weights_dir}"]
    for weight in WEIGHTS:
        target = f"{weights_dir}/{weight.name}"
        commands.append(
            f"curl -fsSL --retry 5 --retry-delay 5 -o {target}.part {weight.url}"
            f" && echo '{weight.sha256}  {target}.part' | sha256sum -c -"
            f" && mv {target}.part {target}"
        )
    return commands


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def verify_weights(home: str | os.PathLike[str] | None = None) -> list[str]:
    """Problems with the installed checkpoints (empty list = all present and intact)."""
    weights_dir = ohv_home(home) / "weights"
    problems = []
    for weight in WEIGHTS:
        path = weights_dir / weight.name
        if not path.is_file():
            problems.append(f"{weight.name}: missing")
        elif path.stat().st_size != weight.size or _sha256(path) != weight.sha256:
            problems.append(f"{weight.name}: wrong size or checksum (re-download it)")
    return problems


def install_openhoopvision(home: str | os.PathLike[str] | None = None) -> Path:
    """Clone OHV at OHV_COMMIT into ``home`` and download + verify its weights (local GPU boxes)."""
    root = ohv_home(home)
    git_env = {**os.environ, "GIT_LFS_SKIP_SMUDGE": "1"}  # weights come from WEIGHTS urls, checksum-verified
    if not (root / ".git").is_dir():
        subprocess.run(["git", "clone", OHV_REPO_URL, str(root)], check=True, env=git_env)
    has_commit = ["git", "-C", str(root), "cat-file", "-e", f"{OHV_COMMIT}^{{commit}}"]
    if subprocess.run(has_commit, check=False, env=git_env, capture_output=True).returncode != 0:
        # An older clone predates the pinned commit: checking it out would fail with "reference is not a tree".
        subprocess.run(["git", "-C", str(root), "fetch", "--quiet", "origin"], check=True, env=git_env)
    subprocess.run(["git", "-C", str(root), "checkout", "--detach", OHV_COMMIT], check=True, env=git_env)
    for weight in WEIGHTS:
        target = root / "weights" / weight.name
        if target.is_file() and target.stat().st_size == weight.size and _sha256(target) == weight.sha256:
            continue
        logger.info("downloading %s (%.0f MB)", weight.name, weight.size / 1e6)
        part = target.with_name(target.name + ".part")
        with urllib.request.urlopen(weight.url, timeout=120) as response, open(part, "wb") as fh:
            while chunk := response.read(1 << 20):
                fh.write(chunk)
        if _sha256(part) != weight.sha256:
            part.unlink(missing_ok=True)
            raise RuntimeError(f"checksum mismatch for {weight.name}")
        os.replace(part, target)
    return root


_MODEL_CHECK = """
import json, sys
import torch
sys.path.insert(0, ".")
weights = sys.argv[1]
cuda = torch.cuda.is_available()
device = 0 if cuda else "cpu"
named = "cuda:0" if cuda else "cpu"
report = {"cuda": cuda, "torch": torch.__version__, "device": torch.cuda.get_device_name(0) if cuda else None}
from rfdetr import from_checkpoint
from models.appearance import OSNetReIDEncoder
from models.court import CourtPoseDetector
from models.jersey_number import JerseyNumberReader
from models.rtmpose import RTMPosePlayerEstimator
detector = from_checkpoint(weights + "/rf-detr-basketball.pth")
names = detector.class_names
report["detector_classes"] = sorted(map(str, names.values() if isinstance(names, dict) else names))
RTMPosePlayerEstimator(weights + "/rtmpose-s_simcc-aic-coco.pth", 4, device)
CourtPoseDetector(weights + "/court_mobilenetv4_896x512.pt", device)
reid = OSNetReIDEncoder(named, weights + "/osnet_x1_0_msmt17.pt")
report["reid_loaded"] = reid._load()  # lazy loaders: force them now
ocr = JerseyNumberReader({"checkpoint": weights + "/basketball_jersey_number.ckpt"}, named)
report["ocr_loaded"] = ocr._load()
report["gpu_memory_mb"] = round(torch.cuda.max_memory_allocated() / 1e6) if cuda else None
print("OHV_MODEL_CHECK " + json.dumps(report), flush=True)
"""


def check_models(home: str | os.PathLike[str] | None = None, *, timeout_s: float = 900) -> dict[str, Any]:
    """Load all five OHV models once (warmup / deployment smoke test)."""
    root = ohv_home(home)
    proc = subprocess.run(
        [sys.executable, "-c", _MODEL_CHECK, str(root / "weights")],
        cwd=str(root), capture_output=True, timeout=timeout_s, check=False,
        env={**os.environ, "PYTHONUNBUFFERED": "1"},
    )  # fmt: skip
    output = proc.stdout.decode("utf-8", "replace")
    for line in output.splitlines():
        if line.startswith("OHV_MODEL_CHECK "):
            return {"ok": True, **json.loads(line.removeprefix("OHV_MODEL_CHECK "))}
    return {"ok": False, "error": (output + proc.stderr.decode("utf-8", "replace"))[-4000:]}


def smoke_run(work_dir: str | os.PathLike[str], *, home: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    """Run the whole OHV CLI on a 2-second synthetic clip (no players) to prove it starts."""
    work = Path(work_dir)
    clip = work / "smoke.mp4"
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=15:duration=2",
         "-pix_fmt", "yuv420p", "-c:v", "libx264", str(clip)],
        check=True, capture_output=True, timeout=120,
    )  # fmt: skip
    run = run_ohv(clip, work / "ohv", analysis_fps=15.0, expected_frames=30, court=CourtSpec(), render=True, home=home)
    frames = _LineCounter(run.tracks_path).count()
    return {"ok": True, "frames": frames, "elapsed_s": run.elapsed_s, "params": asdict(run.params)}


def main(argv: list[str] | None = None) -> int:
    """``python -m modal_app.pipeline.ohv install|verify [--home DIR]``."""
    import argparse

    parser = argparse.ArgumentParser(description="Install or verify OpenHoopVision for SCOUT_PROCESSOR=local.")
    parser.add_argument("command", choices=["install", "verify"])
    parser.add_argument("--home", default=None, help=f"checkout directory (default $OHV_HOME or {DEFAULT_OHV_HOME})")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    if args.command == "install":
        root = install_openhoopvision(args.home)
        logger.info("OpenHoopVision %s installed in %s", OHV_COMMIT[:12], root)
    problems = verify_weights(args.home)
    for problem in problems:
        logger.error(problem)
    if not problems:
        logger.info("all %d OpenHoopVision weights verified", len(WEIGHTS))
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
