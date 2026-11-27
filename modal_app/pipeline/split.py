"""Analyse a film in pieces on several GPUs at once (the Modal app; docs/ARCHITECTURE.md).

``process_video`` runs in a CPU container and prepares the film as before (probe, analysis
copy, written to the Modal volume). Then ``SplitPerceiver`` stands in for the one long
OpenHoopVision run:

    plan the pieces -> spawn ``analyse_piece`` for each (GPU containers, all at once)
    -> follow their progress -> join their tracks (``pieces.join_tracks``) and their annotated
    videos -> an ``OhvRun`` for the rest of the pipeline, which runs once on the whole film.

``run_piece`` is the body of ``analyse_piece``: cut the piece out of the analysis copy, run
OpenHoopVision on it, and leave its tracks (gzip) and its own stretch of the annotated web
video on the volume. A short film is one piece: OpenHoopVision then reads the analysis copy
itself and nothing is joined.

Pure Python: this module runs where only ``modal`` is installed.
"""

from __future__ import annotations

import gzip
import logging
import math
import shutil
import tempfile
import time
import traceback
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Protocol

from modal_app.pipeline import errors, ohv, pieces, render, video
from modal_app.pipeline.errors import PipelineError, is_cuda_oom
from modal_app.pipeline.pieces import PieceSpec, PieceTracks

logger = logging.getLogger(__name__)

PIECES_DIR = "pieces"  # under the job's output_dir on the volume; deleted after the join
TRACKS_FILE = "ohv_tracks.jsonl.gz"
VIDEO_FILE = "annotated.mp4"
PIECE_PROGRESS_INTERVAL_S = 5.0
LOG_LINES_PER_PIECE = 40


@dataclass(frozen=True)
class SplitSettings:
    """How a film is cut (deploy-time settings in modal_app/app.py)."""

    piece_s: float = pieces.DEFAULT_PIECE_S
    max_pieces: int = pieces.DEFAULT_MAX_PIECES
    overlap_s: float = pieces.DEFAULT_OVERLAP_S
    poll_s: float = 5.0


class PieceCalls(Protocol):
    """The GPU function, as the coordinator sees it (Modal in production, a fake in tests)."""

    def spawn(self, request: dict[str, Any]) -> Any:
        """Start one piece; return its call."""

    def result(self, call: Any) -> dict[str, Any] | None:
        """The piece's response dict once it has finished (an error dict if it failed), else None."""

    def cancel(self, call: Any) -> None:
        """Best effort."""

    def progress(self, key: str) -> float | None:
        """The piece's progress, 0..1, as ``run_piece`` reported it under ``key``."""

    def forget(self, key: str) -> None:
        """Drop the piece's progress entry."""


def progress_key(job_id: str, index: int) -> str:
    return f"{job_id}:piece{index}"


# ---------------------------------------------------------------------------
# Coordinator (CPU container)
# ---------------------------------------------------------------------------


class SplitPerceiver:
    """``runner.Perceive`` that runs OpenHoopVision in pieces on several GPUs."""

    def __init__(
        self,
        calls: PieceCalls,
        *,
        job_id: str,
        root: Path,
        output_dir: Path,
        commit: Callable[[], None],
        reload: Callable[[], None],
        settings: SplitSettings | None = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.calls = calls
        self.job_id = job_id
        self.root = root
        self.pieces_dir = output_dir / PIECES_DIR
        self.commit = commit
        self.reload = reload
        self.settings = settings or SplitSettings()
        self.sleep = sleep

    def __call__(self, analysed: Path, plan: video.AnalysisPlan, opts: Any, work: Path, tracker: Any) -> ohv.OhvRun:
        from modal_app.pipeline.runner import weight_overrides

        started = time.monotonic()
        s = self.settings
        if opts.max_frames is not None:  # a test run of the first frames: one piece
            specs = [PieceSpec(0, 0, None, 0, None)]
        else:
            specs = pieces.plan_pieces(
                plan.expected_frames, plan.analysed_fps, piece_s=s.piece_s, max_pieces=s.max_pieces, overlap_s=s.overlap_s
            )
        source = self._on_volume(analysed)
        base = {
            "job_id": self.job_id,
            "video": source,
            "fps_rational": plan.fps_rational,
            "analysis_fps": plan.analysed_fps,
            "expected_frames": plan.expected_frames,
            "court": {"length_ft": opts.court_length_ft, "width_ft": opts.court_width_ft},
            "render": bool(opts.render_video),
            "render_height": opts.render_height,
            "source_height": plan.height,
            "weights": weight_overrides(opts),
            "max_frames": opts.max_frames,
        }
        requests = [
            {**base, "piece": spec.to_dict(), "output_dir": self._relative(self.pieces_dir / str(spec.index))}
            for spec in specs
        ]
        gpus = "a GPU" if len(specs) == 1 else f"{len(specs)} GPUs at once"
        tracker.update("ohv", 0.0, f"Starting player and ball tracking on {gpus}", force=True)
        try:
            self.commit()  # the pieces' containers must see the analysis copy
            results = self._run(requests, specs, tracker)
            self.reload()  # ... and we must see what they wrote
            return self._finish(specs, results, opts, work, tracker, started)
        finally:
            shutil.rmtree(self.pieces_dir, ignore_errors=True)

    # -- running the pieces ------------------------------------------------------
    def _run(self, requests: list[dict[str, Any]], specs: list[PieceSpec], tracker: Any) -> list[dict[str, Any]]:
        calls: dict[int, Any] = {}
        results: dict[int, dict[str, Any]] = {}
        finished: set[int] = set()  # results, and the piece that failed
        try:
            for spec, request in zip(specs, requests, strict=True):
                calls[spec.index] = self.calls.spawn(request)
            while len(results) < len(specs):
                for index, call in calls.items():
                    if index in results:
                        continue
                    response = self.calls.result(call)
                    if response is None:
                        continue
                    finished.add(index)
                    if response.get("status") != "ok":
                        raise _piece_failed(response, specs[index], len(specs))
                    results[index] = response
                if len(results) < len(specs):
                    self._report(specs, results, tracker)
                    self.sleep(self.settings.poll_s)
        except BaseException:  # a failed piece, or this call cancelled: stop the others
            for index, call in calls.items():
                if index not in finished:
                    self.calls.cancel(call)
            raise
        finally:
            for spec in specs:
                self.calls.forget(progress_key(self.job_id, spec.index))
        return [results[spec.index] for spec in specs]

    def _report(self, specs: list[PieceSpec], results: dict[int, dict[str, Any]], tracker: Any) -> None:
        fractions = []
        for spec in specs:
            if spec.index in results:
                fractions.append(1.0)
            else:
                value = self.calls.progress(progress_key(self.job_id, spec.index))
                fractions.append(min(1.0, max(0.0, value)) if isinstance(value, (int, float)) else 0.0)
        done = len(results)
        if len(specs) == 1:
            message = "Tracking players and the ball"
        else:
            message = f"Tracking players and the ball on {len(specs)} GPUs ({done} of {len(specs)} pieces done)"
        # The join and the rest of the pipeline follow, so the pieces fill 95% of the tracking slot.
        tracker.update("ohv", 0.95 * sum(fractions) / len(fractions), message)

    # -- joining -----------------------------------------------------------------
    def _finish(
        self,
        specs: list[PieceSpec],
        results: list[dict[str, Any]],
        opts: Any,
        work: Path,
        tracker: Any,
        started: float,
    ) -> ohv.OhvRun:
        work.mkdir(parents=True, exist_ok=True)
        tracks = work / "ohv_tracks.jsonl"
        warnings = _unique_warnings(w for r in results for w in r.get("warnings") or ())
        summaries = [r.get("summary") or {} for r in results]
        colors = next((s.get("team_colors_bgr") for s in summaries if s.get("team_colors_bgr")), None)
        if len(specs) == 1:
            with gzip.open(self.root / results[0]["tracks_path"], "rb") as src, open(tracks, "wb") as dst:
                shutil.copyfileobj(src, dst)
        else:
            tracker.update("ohv", 0.96, f"Joining the {len(specs)} pieces of the film", force=True)
            report = pieces.join_tracks(
                [
                    PieceTracks(spec, self.root / r["tracks_path"], s.get("team_colors_bgr"))
                    for spec, r, s in zip(specs, results, summaries, strict=True)
                ],
                tracks,
            )
            colors = report.team_colors_bgr or colors
            warnings = _unique_warnings([*warnings, *report.warnings])
            linked = [cut.linked for cut in report.cuts]
            logger.info("joined %d pieces: %d frames, %d tracks, linked at the cuts %s", len(specs), report.frames, report.tracks, linked)
        web_video = self._join_videos(specs, results, work, warnings) if opts.render_video else None
        summary = ohv.OhvSummary(
            team_colors_bgr=[tuple(c) for c in colors] if colors else None,  # type: ignore[misc]
            detector_batch_reductions=sum(int(s.get("detector_batch_reductions") or 0) for s in summaries),
            frames=sum(int(s.get("frames") or 0) for s in summaries) or None,
            processing_fps=None,
            ocr_error=next((s["ocr_error"] for s in summaries if s.get("ocr_error")), None),
            reid_error=next((s["reid_error"] for s in summaries if s.get("reid_error")), None),
        )
        params = results[0].get("params") or {}
        known = {f for f in ohv.OhvParams.__dataclass_fields__}
        log_tail: list[str] = []
        for spec, result in zip(specs, results, strict=True):
            if len(specs) > 1:
                log_tail.append(f"--- piece {spec.index + 1} of {len(specs)} ---")
            log_tail.extend(result.get("log_tail") or ())
        return ohv.OhvRun(
            tracks_path=tracks,
            events_path=tracks,
            output_video=None,
            params=ohv.OhvParams(**{k: v for k, v in params.items() if k in known}),
            attempts=max(int(r.get("attempts") or 1) for r in results),
            summary=summary,
            warnings=warnings,
            elapsed_s=round(time.monotonic() - started, 1),
            log_tail=log_tail,
            web_video=web_video,
            gpu=next((r["gpu"] for r in results if r.get("gpu")), None),
            pieces=[
                {
                    "start_frame": spec.start,
                    "own_start_frame": spec.own_start,
                    "own_end_frame": spec.own_end,
                    "seconds": result.get("elapsed_s"),
                    "attempts": result.get("attempts"),
                }
                for spec, result in zip(specs, results, strict=True)
            ],
        )

    def _join_videos(
        self, specs: list[PieceSpec], results: list[dict[str, Any]], work: Path, warnings: list[dict[str, str]]
    ) -> Path | None:
        paths = [r.get("video_path") for r in results]
        if not all(paths):  # the pieces said why (ANNOTATED_VIDEO_FAILED / _MISSING)
            if any(paths) and len(specs) > 1:
                warnings.append(_video_warning("Part of the annotated video could not be made"))
            return None
        target = work / VIDEO_FILE
        if len(specs) == 1:
            shutil.move(str(self.root / str(paths[0])), target)
            return target
        listing = work / "pieces.txt"
        listing.write_text(pieces.concat_list([self.root / str(p) for p in paths]), encoding="utf-8")
        same_encoder = len({r.get("encoder") for r in results}) == 1
        cmd = pieces.build_concat_command(str(listing), str(target))
        if not same_encoder:  # a stream copy needs identical encoder settings: encode once more
            cmd = cmd[: cmd.index("-c")] + ["-c:v", render.X264, "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p"] + cmd[cmd.index("-movflags") :]
        try:
            video.run_ffmpeg(cmd, message="Joining the annotated video", error_message="The annotated video could not be joined.")
        except PipelineError as exc:
            logger.warning("joining the annotated video failed: %s", exc.detail)
            warnings.append(_video_warning("The annotated video could not be joined"))
            return None
        return target

    # -- paths -------------------------------------------------------------------
    def _on_volume(self, path: Path) -> str:
        try:
            return self._relative(path)
        except ValueError as exc:
            message = "The analysis copy of the film is not on the Modal volume, so the GPUs cannot read it."
            raise PipelineError(errors.PIPELINE_FAILED, message, detail=str(path)) from exc

    def _relative(self, path: Path) -> str:
        return _relative(self.root, path)


def _piece_failed(response: dict[str, Any], spec: PieceSpec, count: int) -> PipelineError:
    error = response.get("error") if isinstance(response.get("error"), dict) else {}
    code = str(error.get("code") or errors.PIPELINE_FAILED)
    message = str(error.get("message") or "A piece of the film could not be analysed.")
    where = f"piece {spec.index + 1} of {count} (frames from {spec.start})" if count > 1 else "the film"
    detail = f"{where}: {error.get('detail') or ''}".strip()
    return PipelineError(code, message, detail=detail[-6000:])


def _unique_warnings(items: Any) -> list[dict[str, str]]:
    seen: set[str] = set()
    unique = []
    for warning in items:
        if isinstance(warning, dict) and warning.get("code") and warning["code"] not in seen:
            seen.add(warning["code"])
            unique.append(dict(warning))
    return unique


def _video_warning(what: str) -> dict[str, str]:
    return {
        "code": "ANNOTATED_VIDEO_FAILED",
        "message": f"{what}; stats and the timeline are unaffected, and the film plays without overlays.",
        "severity": "warning",
    }


# ---------------------------------------------------------------------------
# One piece (GPU container)
# ---------------------------------------------------------------------------


def run_piece(
    request: dict[str, Any], *, root: Path, progress: Callable[[float, str], None] | None = None
) -> dict[str, Any]:
    """Analyse one piece (see the module docstring); never raises for expected failures."""
    started = time.monotonic()
    index = request.get("piece", {}).get("index") if isinstance(request.get("piece"), dict) else None
    try:
        spec = PieceSpec.from_dict(request["piece"])
        source = _volume_file(root, str(request["video"]))
        out = root / str(request["output_dir"])
        report = _throttled(progress)
        with tempfile.TemporaryDirectory(prefix=f"piece{spec.index}-") as scratch:
            work = Path(scratch)
            clip = source
            if not spec.whole_film:
                report(0.0, "Cutting this piece of the film")
                clip = work / "piece.mp4"
                video.run_ffmpeg(
                    pieces.build_cut_command(str(source), str(clip), spec, str(request["fps_rational"])),
                    error_code=errors.VIDEO_DECODE_FAILED,
                    error_message="This piece of the film could not be cut out for analysis.",
                )
            total = int(request.get("expected_frames") or 0)
            expected = spec.frames if spec.frames is not None else max(1, total - spec.start)
            run = ohv.run_ohv(
                clip,
                work / "ohv",
                analysis_fps=float(request["analysis_fps"]),
                expected_frames=expected,
                court=ohv.CourtSpec(**(request.get("court") or {})),
                render=bool(request.get("render")),
                weight_overrides=request.get("weights") or None,
                max_frames=request.get("max_frames"),
                progress=lambda fraction, message: report(0.95 * fraction, message),
            )
            out.mkdir(parents=True, exist_ok=True)
            with open(run.tracks_path, "rb") as src, gzip.open(out / TRACKS_FILE, "wb", compresslevel=3) as dst:
                shutil.copyfileobj(src, dst)
            warnings = list(run.warnings)
            video_path, encoder = None, None
            if request.get("render") and run.output_video is not None:
                report(0.96, "Encoding the annotated video")
                trim = None
                if not spec.whole_film:
                    own = None if spec.own_end is None else spec.own_end - spec.own_start
                    trim = (spec.own_start - spec.start, own)
                try:
                    encoder = render.render_web_video(
                        run.output_video, out / VIDEO_FILE, target_height=int(request.get("render_height") or 720),
                        source_height=request.get("source_height"), expected_frames=expected, frames=trim,
                    )  # fmt: skip
                    video_path = _relative(root, out / VIDEO_FILE)
                except PipelineError as exc:
                    logger.warning("annotated video of piece %d failed: %s", spec.index, exc.detail)
                    warnings.append(_video_warning("The annotated video could not be encoded"))
            elif request.get("render"):
                warnings.append(
                    {
                        "code": "ANNOTATED_VIDEO_MISSING",
                        "message": "No annotated video was produced; the film plays without overlays.",
                        "severity": "warning",
                    }
                )
        report(1.0, "Piece done")
        return {
            "status": "ok",
            "index": spec.index,
            "tracks_path": _relative(root, out / TRACKS_FILE),
            "video_path": video_path,
            "encoder": encoder,
            "summary": asdict(run.summary),
            "params": asdict(run.params),
            "attempts": run.attempts,
            "elapsed_s": round(time.monotonic() - started, 1),
            "warnings": warnings,
            "log_tail": list(run.log_tail[-LOG_LINES_PER_PIECE:]),
            "gpu": ohv.gpu_name(),
        }
    except PipelineError as exc:
        logger.warning("piece %s failed: %s", index, exc)
        return {"status": "error", "index": index, "error": exc.to_dict()}
    except Exception as exc:  # noqa: BLE001 - the coordinator must always get a response dict
        logger.exception("piece %s failed unexpectedly", index)
        tail = traceback.format_exc()[-6000:]
        if is_cuda_oom(exc):
            failure = PipelineError(errors.GPU_OOM, "The GPU ran out of memory.", detail=tail)
        else:
            failure = PipelineError(errors.PIPELINE_FAILED, f"Unexpected error: {type(exc).__name__}: {exc}"[:300], detail=tail)
        return {"status": "error", "index": index, "error": failure.to_dict()}


def _volume_file(root: Path, relative: str) -> Path:
    parts = PurePosixPath(relative.lstrip("/")).parts
    if not parts or ".." in parts:
        raise PipelineError(errors.PIPELINE_FAILED, "Invalid piece request: the film is not on the volume.", detail=relative)
    path = root.joinpath(*parts)
    if not path.is_file():
        raise PipelineError(errors.VIDEO_INVALID, "The film to analyse was not found on the GPU volume.", detail=relative)
    return path


def _relative(root: Path, path: Path) -> str:
    return Path(path).resolve().relative_to(Path(root).resolve()).as_posix()


def _throttled(progress: Callable[[float, str], None] | None) -> Callable[[float, str], None]:
    """``progress`` at most every few seconds (each write to the Modal Dict is a network call),
    always for the first and the last report."""
    last = [-math.inf]

    def report(fraction: float, message: str) -> None:
        if progress is None:
            return
        now = time.monotonic()
        if fraction >= 1.0 or now - last[0] >= PIECE_PROGRESS_INTERVAL_S:
            last[0] = now
            try:
                progress(fraction, message)
            except Exception:  # noqa: BLE001 - progress is best-effort
                logger.warning("could not report piece progress")

    return report
