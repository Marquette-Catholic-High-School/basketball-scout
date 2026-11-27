"""Modal app: the GPU half of Basketball Scout.

    modal deploy modal_app/app.py                   # deploy (scripts/update.sh --deploy-modal does this)
    modal run modal_app/app.py::warmup              # build the image and load every model once on the GPU
    modal run modal_app/app.py --video game.mp4     # analyse a local film end to end -> ./modal_output/

The server (``scout.processing.modal_client``) uploads film to the Volume, spawns
``process_video`` and polls the progress Dict; the request/response dicts are documented
in docs/TRACKING_SCHEMA.md. ``process_video`` runs in a CPU container: it prepares the film,
has ``analyse_piece`` track the players in pieces of the film on several GPUs at once
(``modal_app.pipeline.split``) and builds the results from the joined pieces.

Deploy-time settings come from the environment, using the same names as ``.env``:
SCOUT_MODAL_GPU (default L40S), SCOUT_MODAL_TIMEOUT_S (default 21600),
SCOUT_MODAL_MAX_CONTAINERS (films at once), SCOUT_MODAL_MAX_GPUS (GPUs at once),
SCOUT_MODAL_PIECE_MINUTES, SCOUT_MODAL_MAX_PIECES, SCOUT_MODAL_APP_NAME,
SCOUT_MODAL_VOLUME_NAME and SCOUT_MODAL_PROGRESS_DICT.

Importing this module needs only ``modal``: the computer vision runs in an OpenHoopVision
subprocess inside the container (see ``modal_app/pipeline/ohv.py``).
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import tempfile
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any

import modal

from modal_app.pipeline import errors, ohv, pieces
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.progress import ProgressSink
from modal_app.pipeline.runner import VOLUME_ROOT, PipelineProgress, run_pipeline
from modal_app.pipeline.split import PieceCalls, SplitPerceiver, SplitSettings, progress_key, run_piece
from modal_app.pipeline.video import DEFAULT_MAX_DOWNLOAD_BYTES, download_video

logger = logging.getLogger(__name__)


def _env(name: str, default: str) -> str:
    """A deploy-time setting. Blank values count as unset: `dotenv run -- modal deploy` turns
    a ``SCOUT_MODAL_GPU=`` line in .env into an empty string, like the server ignores them."""
    return os.environ.get(name, "").strip() or default


APP_NAME = _env("SCOUT_MODAL_APP_NAME", "basketball-scout")
VOLUME_NAME = _env("SCOUT_MODAL_VOLUME_NAME", "basketball-scout-data")
PROGRESS_DICT_NAME = _env("SCOUT_MODAL_PROGRESS_DICT", "basketball-scout-progress")
# 48 GB, about $1.95/h. The A10G (24 GB, about $1.10/h) analysed a 75-minute film in 95 minutes
# on one GPU; the L40S is a newer, faster card (not measured here yet).
GPU_TYPE = _env("SCOUT_MODAL_GPU", "L40S")

# Time budget per film. OpenHoopVision analyses every frame of the 15 fps analysis copy with
# five networks plus per-player tracking, team-colour and OCR logic in Python, one frame after
# another: on one A10G a 75-minute film took 95 minutes. The film is therefore analysed in
# pieces of about SCOUT_MODAL_PIECE_MINUTES on up to SCOUT_MODAL_MAX_PIECES GPUs at once, so a
# game takes about as long as one piece. The 6-hour default leaves headroom for long film, few
# GPUs and out-of-memory retries (each restarts OHV). Modal's hard limit is 24 hours.
DEFAULT_TIMEOUT_S = 6 * 3600
MAX_TIMEOUT_S = 24 * 3600


def _timeout_from_env() -> int:
    raw = os.environ.get("SCOUT_MODAL_TIMEOUT_S", "")
    try:
        value = int(float(raw)) if raw.strip() else DEFAULT_TIMEOUT_S
    except ValueError:
        value = DEFAULT_TIMEOUT_S
    return max(600, min(MAX_TIMEOUT_S, value))


def _positive_int(name: str, default: int) -> int:
    try:
        return max(1, int(_env(name, str(default))))
    except ValueError:
        return default


def _max_containers_from_env() -> int:
    return _positive_int("SCOUT_MODAL_MAX_CONTAINERS", 2)


def _split_from_env() -> SplitSettings:
    try:
        minutes = float(_env("SCOUT_MODAL_PIECE_MINUTES", str(pieces.DEFAULT_PIECE_S / 60)))
    except ValueError:
        minutes = pieces.DEFAULT_PIECE_S / 60
    minutes = max(pieces.MIN_PIECE_S / 60, minutes)
    return SplitSettings(piece_s=minutes * 60, max_pieces=_positive_int("SCOUT_MODAL_MAX_PIECES", pieces.DEFAULT_MAX_PIECES))


PROCESS_TIMEOUT_S = _timeout_from_env()
STARTUP_TIMEOUT_S = 20 * 60  # cold start pulls a ~10 GB image
WARMUP_TIMEOUT_S = 30 * 60
CPU_CORES = 8.0  # decoding, ffmpeg and OHV's per-player Python work are CPU-bound
MEMORY_MB = 32768  # OHV keeps every frame's player records in RAM while finalising
MAX_CONTAINERS = _max_containers_from_env()  # films at once (process_video containers)
SPLIT = _split_from_env()
# Cost cap: GPU containers at once, over all films. One film uses up to SPLIT.max_pieces; with
# fewer GPUs its pieces wait for a free one (slower, not more expensive).
MAX_GPUS = _positive_int("SCOUT_MODAL_MAX_GPUS", 8)


def build_image() -> modal.Image:
    """Debian + ffmpeg, the CUDA 13 torch stack, OHV at its pinned commit and its weights."""
    home = ohv.DEFAULT_OHV_HOME
    return (
        modal.Image.debian_slim(python_version="3.12")
        # libgl1: OpenCV's cv2 (opencv-python, as OHV's lock pins it) needs libGL.so.1 to import.
        .apt_install("ffmpeg", "git", "git-lfs", "curl", "ca-certificates", "libgl1")
        # OpenCV needs glib; Debian trixie (image builder 2026.10) renamed the package.
        .run_commands(
            "apt-get update && (apt-get install -y --no-install-recommends libglib2.0-0t64"
            " || apt-get install -y --no-install-recommends libglib2.0-0) && rm -rf /var/lib/apt/lists/*"
        )
        # torch gets its own (large, rarely changing) layer.
        .uv_pip_install(*ohv.TORCH_REQUIREMENTS, index_url=ohv.TORCH_INDEX_URL)
        .uv_pip_install(
            *ohv.OHV_REQUIREMENTS,
            *ohv.TORCH_REQUIREMENTS,  # re-pinned so no resolver step can swap the CUDA build
            extra_index_url=ohv.TORCH_INDEX_URL,
            extra_options="--index-strategy unsafe-best-match",
        )
        .run_commands(
            f"git clone --filter=blob:none {ohv.OHV_REPO_URL} {home}",
            f"git -C {home} checkout --detach {ohv.OHV_COMMIT}",
            f"rm -rf {home}/assets",
            env={"GIT_LFS_SKIP_SMUDGE": "1"},
        )
        # Weights are baked into the image (sha256-checked) so runs never touch Git LFS.
        .run_commands(*ohv.weight_download_commands(f"{home}/weights"))
        .env(
            {
                "OHV_HOME": home,
                "OHV_REQUIRE_CUDA": "1",
                "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True",
                "PYTHONUNBUFFERED": "1",
                "SCOUT_MODAL_VOLUME_NAME": VOLUME_NAME,  # the container must use the same names
                "SCOUT_MODAL_PROGRESS_DICT": PROGRESS_DICT_NAME,
            }
        )
        .add_local_python_source("modal_app")  # must stay last (attached at container start)
    )


image = build_image()
app = modal.App(APP_NAME)
vol = modal.Volume.from_name(VOLUME_NAME, create_if_missing=True)
progress_dict = modal.Dict.from_name(PROGRESS_DICT_NAME, create_if_missing=True)


# ---------------------------------------------------------------------------
# Request handling (plain functions so they are testable without Modal)
# ---------------------------------------------------------------------------

_JOB_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$")
_VIDEO_SUFFIXES = (".mp4", ".mov", ".m4v", ".mkv", ".webm")
# A link film is downloaded as "<name>.part" and a file name may have 255 bytes at most.
_MAX_NAME_CHARS = 100
_MAX_SUFFIX_CHARS = 10  # longer is not an extension (".mp4", ".webm", ".m2ts")


@dataclass(frozen=True)
class ParsedRequest:
    job_id: str
    filename: str
    output_dir: str  # relative to the volume root
    options: dict[str, Any] = field(default_factory=dict)
    volume_path: str | None = None  # set for {"type": "volume"}
    url: str | None = None  # set for {"type": "url"}


def _bad_request(reason: str) -> PipelineError:
    return PipelineError(errors.PIPELINE_FAILED, f"Invalid processing request: {reason}.")


def parse_request(request: Any) -> ParsedRequest:
    """Validate the processing request (docs/TRACKING_SCHEMA.md)."""
    if not isinstance(request, dict):
        raise _bad_request("the request must be an object")
    job_id = str(request.get("job_id") or "")
    if not _JOB_ID.match(job_id):
        raise _bad_request(f"invalid job_id {job_id!r}")
    options = request.get("options") or {}
    if not isinstance(options, dict):
        raise _bad_request("'options' must be an object")
    output_dir = str(request.get("output_dir") or f"results/{job_id}")
    source = request.get("video")
    if not isinstance(source, dict):
        raise _bad_request("'video' must be an object")
    if source.get("type") == "volume":
        path = str(source.get("path") or "")
        if not path:
            raise _bad_request("video.path is missing")
        filename = str(source.get("filename") or PurePosixPath(path).name)
        return ParsedRequest(job_id, filename, output_dir, options, volume_path=path)
    if source.get("type") == "url":
        url = str(source.get("url") or "")
        if not url:
            raise _bad_request("video.url is missing")
        filename = str(source.get("filename") or _filename_from_url(url))
        return ParsedRequest(job_id, filename, output_dir, options, url=url)
    raise _bad_request(f"unknown video type {source.get('type')!r}")


def resolve_volume_path(root: Path, relative: str, *, must_exist: bool = False) -> Path:
    """``relative`` (to the volume root) -> absolute path, refusing anything outside the volume."""
    parts = PurePosixPath(relative.lstrip("/")).parts
    if not parts or ".." in parts:
        raise _bad_request(f"path {relative!r} is not inside the volume")
    path = root.joinpath(*parts)
    if must_exist and not path.is_file():
        raise PipelineError(errors.VIDEO_INVALID, "The uploaded film was not found on the GPU volume.", detail=relative)
    return path


def _filename_from_url(url: str) -> str:
    name = PurePosixPath(urllib.parse.urlparse(url).path).name
    return name if name.lower().endswith(_VIDEO_SUFFIXES) else "film.mp4"


def _safe_name(name: str) -> str:
    """A plain file name for ``name``: no folders or odd characters, at most 100 characters
    (the extension is kept)."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", PurePosixPath(name).name).lstrip(".")
    if len(cleaned) > _MAX_NAME_CHARS:
        suffix = PurePosixPath(cleaned).suffix
        suffix = suffix if len(suffix) <= _MAX_SUFFIX_CHARS else ""
        cleaned = cleaned[: _MAX_NAME_CHARS - len(suffix)] + suffix
    return cleaned or "film.mp4"


def dict_sink(store: Any, job_id: str) -> ProgressSink:
    """Progress sink writing ``{"stage", "pct", "message", "updated_at"}`` under the job id.

    Calls arrive throttled (ProgressTracker emits at most every 2 s): each Dict write costs
    tens of milliseconds.
    """

    def sink(stage: str, pct: float, message: str) -> None:
        store[job_id] = {"stage": stage, "pct": pct, "message": message, "updated_at": time.time()}

    return sink


def handle_request(
    request: Any,
    *,
    volume: Any,
    progress_store: Any,
    root: Path = Path(VOLUME_ROOT),
    piece_calls: PieceCalls | None = None,
    split: SplitSettings | None = None,
) -> dict[str, Any]:
    """Body of ``process_video``: resolve the film, run the pipeline, persist the outputs.

    With ``piece_calls`` the players are tracked in pieces on several GPUs
    (``split.SplitPerceiver``; the analysis copy is written to the volume for them), without it
    on this machine. Never raises for expected failures (they become ``{"status": "error"}``).
    Modal's ``InputCancellation`` is a BaseException and is deliberately not caught.
    """
    job_id = str(request.get("job_id") or "unknown") if isinstance(request, dict) else "unknown"
    sink = dict_sink(progress_store, job_id)
    download_dir: Path | None = None
    analysis_dir: Path | None = None
    try:
        parsed = parse_request(request)
        volume.reload()  # see files uploaded after this container mounted the volume
        if parsed.url:
            download_dir = root / "tmp" / parsed.job_id
            progress = PipelineProgress(sink)
            max_bytes = int(parsed.options.get("max_download_bytes") or DEFAULT_MAX_DOWNLOAD_BYTES)
            source = download_video(
                parsed.url,
                download_dir / _safe_name(parsed.filename),
                max_bytes=max_bytes,
                progress=progress.reporter("download"),
            )
        else:
            assert parsed.volume_path is not None
            source = resolve_volume_path(root, parsed.volume_path, must_exist=True)
        output_dir = resolve_volume_path(root, parsed.output_dir)
        extra: dict[str, Any] = {}
        if piece_calls is not None:
            analysis_dir = root / "tmp" / parsed.job_id / "analysis"
            analysis_dir.mkdir(parents=True, exist_ok=True)
            extra = {
                "analysis_dir": str(analysis_dir),
                "perceive": SplitPerceiver(
                    piece_calls, job_id=parsed.job_id, root=root, output_dir=output_dir,
                    commit=volume.commit, reload=volume.reload, settings=split,
                ),
            }  # fmt: skip
        response = run_pipeline(
            str(source),
            parsed.options,
            output_dir=str(output_dir),
            job_id=parsed.job_id,
            progress=sink,
            filename=parsed.filename,
            **extra,
        )
    except PipelineError as exc:
        response = {"status": "error", "job_id": job_id, "error": exc.to_dict(), "warnings": []}
    except Exception as exc:  # noqa: BLE001 - the server must always get a response dict
        logger.exception("process_video failed before the pipeline ran")
        failure = PipelineError(errors.PIPELINE_FAILED, f"GPU worker error: {type(exc).__name__}: {exc}"[:300])
        response = {"status": "error", "job_id": job_id, "error": failure.to_dict(), "warnings": []}
    finally:
        for scratch in (download_dir, analysis_dir):
            if scratch is not None:
                shutil.rmtree(scratch, ignore_errors=True)
    try:
        volume.commit()  # make outputs visible to the server as soon as we return
    except Exception as exc:  # noqa: BLE001
        logger.exception("volume commit failed")
        if response["status"] == "ok":
            failure = PipelineError(
                errors.PIPELINE_FAILED, "Results could not be saved to the Modal volume.", detail=str(exc)
            )
            warnings = response.get("warnings", [])
            response = {"status": "error", "job_id": job_id, "error": failure.to_dict(), "warnings": warnings}
    if response["status"] != "ok":
        try:
            sink("error", 100.0, response["error"]["message"])
        except Exception:  # noqa: BLE001 - progress is best-effort
            logger.warning("could not write the final progress entry")
    return response


def _configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


# ---------------------------------------------------------------------------
# Modal functions
# ---------------------------------------------------------------------------


class ModalPieceCalls:
    """``split.PieceCalls`` over the deployed ``analyse_piece`` function and the progress Dict."""

    def __init__(self, function: Any, store: Any) -> None:
        self.function = function
        self.store = store

    def spawn(self, request: dict[str, Any]) -> Any:
        return self.function.spawn(request)

    def result(self, call: Any) -> dict[str, Any] | None:
        failure: str | None = None
        try:
            return call.get(timeout=0)
        except TimeoutError:  # the BUILTIN TimeoutError: still queued or running
            return None
        except modal.exception.FunctionTimeoutError:  # subclass of modal's TimeoutError: check it first
            failure = "A piece of the film ran past its time limit on the GPU."
        except (
            modal.exception.ConnectionError,
            modal.exception.ServiceError,
            modal.exception.InternalError,
            modal.exception.ResourceExhaustedError,
            modal.exception.TimeoutError,
        ) as exc:  # trouble reaching Modal, not an outcome of the piece: ask again later
            logger.warning("could not check a piece: %s", exc)
            return None
        except Exception as exc:  # noqa: BLE001 - the remote failed: report it as the piece's error
            logger.warning("a piece failed on Modal: %s", exc)
            failure = f"A piece of the film failed on the GPU: {type(exc).__name__}: {exc}"[:300]
        return {"status": "error", "error": {"code": errors.PIPELINE_FAILED, "message": failure, "detail": None}}

    def cancel(self, call: Any) -> None:
        try:
            call.cancel()
        except Exception:  # noqa: BLE001 - best effort
            logger.warning("could not cancel a piece")

    def progress(self, key: str) -> float | None:
        try:
            entry = self.store.get(key)
        except Exception:  # noqa: BLE001 - progress is best-effort
            return None
        return entry.get("fraction") if isinstance(entry, dict) else None

    def forget(self, key: str) -> None:
        try:
            self.store.pop(key)
        except Exception:  # noqa: BLE001 - KeyError, or Modal unreachable: the entry is tiny
            pass


@app.function(
    image=image,
    timeout=PROCESS_TIMEOUT_S,
    startup_timeout=STARTUP_TIMEOUT_S,
    cpu=CPU_CORES,
    memory=MEMORY_MB,
    volumes={VOLUME_ROOT: vol},
    retries=0,  # failures come back as error dicts; never silently re-run a multi-hour job
    max_containers=MAX_CONTAINERS,
)
def process_video(request: dict) -> dict:
    """Analyse one film; returns a small manifest (big outputs live on the Volume).

    A CPU container: the player tracking runs in ``analyse_piece`` on the GPUs. Idempotent: a
    preempted call re-runs from scratch and overwrites ``output_dir``.
    """
    _configure_logging()
    calls = ModalPieceCalls(analyse_piece, progress_dict)
    return handle_request(request, volume=vol, progress_store=progress_dict, piece_calls=calls, split=SPLIT)


@app.function(
    image=image,
    gpu=GPU_TYPE,
    timeout=PROCESS_TIMEOUT_S,
    startup_timeout=STARTUP_TIMEOUT_S,
    cpu=CPU_CORES,
    memory=MEMORY_MB,
    volumes={VOLUME_ROOT: vol},
    retries=0,  # a failed piece fails the film (process_video reports it)
    max_containers=MAX_GPUS,
)
def analyse_piece(request: dict) -> dict:
    """Track the players in one piece of a film (``split.run_piece``); outputs go to the Volume."""
    _configure_logging()
    key = split_progress_key(request)

    def report(fraction: float, message: str) -> None:
        progress_dict[key] = {"fraction": fraction, "message": message, "updated_at": time.time()}

    vol.reload()  # the analysis copy was written after this container mounted the volume
    return finish_piece(run_piece(request, root=Path(VOLUME_ROOT), progress=report), vol)


def finish_piece(response: dict[str, Any], volume: Any) -> dict[str, Any]:
    """Commit the piece's outputs so ``process_video`` sees them; a failed commit fails the piece."""
    try:
        volume.commit()
    except Exception as exc:  # noqa: BLE001
        logger.exception("volume commit failed")
        if response.get("status") == "ok":
            failure = PipelineError(errors.PIPELINE_FAILED, "A piece's results could not be saved to the Modal volume.", detail=str(exc))
            return {"status": "error", "index": response.get("index"), "error": failure.to_dict()}
    return response


def split_progress_key(request: Any) -> str:
    piece = request.get("piece") if isinstance(request, dict) else None
    index = int(piece.get("index") or 0) if isinstance(piece, dict) else 0
    return progress_key(str(request.get("job_id") or "unknown"), index)


@app.function(image=image, gpu=GPU_TYPE, timeout=WARMUP_TIMEOUT_S, cpu=CPU_CORES, memory=MEMORY_MB)
def warmup() -> dict:
    """Verify the image on a real GPU: weights intact, all models load, the OHV CLI runs."""
    _configure_logging()
    from modal_app.pipeline import render

    report: dict[str, Any] = {
        "gpu": ohv.gpu_name(),
        "nvenc": render.nvenc_available(),
        "ohv_commit": ohv.OHV_COMMIT,
        "weight_problems": ohv.verify_weights(),
        "models": ohv.check_models(),
    }
    with tempfile.TemporaryDirectory() as work:
        try:
            report["smoke_run"] = ohv.smoke_run(work)
        except PipelineError as exc:
            report["smoke_run"] = {"ok": False, **exc.to_dict()}
        except Exception as exc:  # noqa: BLE001 - report, don't crash the smoke test
            report["smoke_run"] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    report["ok"] = bool(not report["weight_problems"] and report["models"].get("ok") and report["smoke_run"].get("ok"))
    print(json.dumps(report, indent=2))
    return report


@app.local_entrypoint()
def main(video: str, job_id: str = "cli-test", fps: float = 15.0) -> None:
    """Upload a local MP4, analyse it on the GPU, download the results into ./modal_output/."""
    source = Path(video).expanduser()
    if not source.is_file():
        raise SystemExit(f"Video not found: {source}")
    remote = f"uploads/{job_id}/{_safe_name(source.name)}"
    print(f"Uploading {source.name} ({source.stat().st_size / 1e6:.0f} MB) to {VOLUME_NAME}:/{remote} ...")
    with vol.batch_upload(force=True) as batch:
        batch.put_file(str(source), f"/{remote}")
    request = {
        "job_id": job_id,
        "video": {"type": "volume", "path": remote, "filename": source.name},
        "output_dir": f"results/{job_id}",
        "options": {"analysis_fps": fps},
    }
    print(f"Analysing on {GPU_TYPE} (this can take hours for a full game) ...")
    call = process_video.spawn(request)
    while True:
        try:
            response = call.get(timeout=30)
            break
        except TimeoutError:  # builtin TimeoutError: still running
            entry = progress_dict.get(job_id)
            if entry:
                print(f"  {entry['pct']:5.1f}%  {entry['stage']}: {entry['message']}")
    print(json.dumps(response, indent=2))
    if response.get("status") != "ok":
        raise SystemExit(1)
    out = Path("modal_output")
    out.mkdir(exist_ok=True)
    for key in ("tracking_path", "annotated_video_path"):
        if remote_path := response.get(key):
            target = out / PurePosixPath(remote_path).name
            with open(target, "wb") as fh:
                vol.read_file_into_fileobj(remote_path, fh)
            print(f"Saved {target}")
