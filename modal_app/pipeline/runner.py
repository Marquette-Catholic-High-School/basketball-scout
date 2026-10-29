"""End-to-end pipeline orchestration (used by the Modal function and the local processor).

    probe + validate -> [pre-transcode] -> OpenHoopVision -> adapter -> supplementary
    events -> quality checks -> [web copy of the annotated video] -> tracking.json.gz

Expected failures come back as ``{"status": "error", ...}`` and are never raised; the
request/response contract is in docs/TRACKING_SCHEMA.md. OHV's raw outputs live in a
scratch work directory (deleted at the end); only ``tracking.json.gz``,
``annotated.mp4`` and a short ``ohv_log.txt`` are written to ``output_dir``.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import tempfile
import time
import traceback
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from modal_app.pipeline import adapter, errors, ohv, render, result, video
from modal_app.pipeline.adapter import AdapterResult
from modal_app.pipeline.errors import PipelineError, is_cuda_oom
from modal_app.pipeline.progress import ProgressSink, ProgressTracker
from modal_app.pipeline.types import Perception

logger = logging.getLogger(__name__)

VOLUME_ROOT = "/data"  # Modal volume mount point (modal_app/app.py); returned paths are relative to it
TRACKING_FILE = "tracking.json.gz"
ANNOTATED_FILE = "annotated.mp4"
OHV_LOG_FILE = "ohv_log.txt"

MIN_MEDIAN_PLAYERS = 4  # fewer in a typical frame: not a full-court game angle
BALL_SPARSE_COVERAGE = 0.30
BALL_MISSING_COVERAGE = 0.02
COURT_SPARSE_COVERAGE = 0.30
OCR_SPARSE_SHARE = 0.25  # share of longer player tracks with at least one jersey read
OCR_MIN_TRACK_S = 2.0
PARTIAL_FILM_SHARE = 0.9  # fewer analysed frames than this share of the film: OHV stopped early


# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PipelineOptions:
    """``request["options"]`` (docs/TRACKING_SCHEMA.md) with defaults and range checks."""

    analysis_fps: float = 15.0
    analysis_max_side: int = 1280
    render_video: bool = True
    render_height: int = 720
    max_duration_s: float = 9000.0
    court_length_ft: float = 84.0
    court_width_ft: float = 50.0
    calibration: dict[str, Any] | None = None
    detector_weights: str | None = None
    court_keypoint_weights: str | None = None
    max_frames: int | None = None  # testing: stop OHV after N analysed frames
    work_dir: str | None = None  # scratch root (default: system temp)
    keep_work_dir: bool = False  # debugging: keep OHV's raw JSONL and videos

    @classmethod
    def from_dict(cls, raw: dict[str, Any] | None) -> PipelineOptions:
        """Validate; unknown keys (e.g. ``scouted_color_hint``, used by the server) are ignored."""
        raw = raw or {}
        if not isinstance(raw, dict):
            raise _bad_option("options", "must be an object")
        calibration = raw.get("calibration")
        if calibration is not None and not (isinstance(calibration, dict) and calibration.get("matrix")):
            raise _bad_option("calibration", "must be an object with a 3x3 'matrix'")
        defaults = cls()
        max_frames = raw.get("max_frames")
        return cls(
            analysis_fps=_number(raw, "analysis_fps", float, 1.0, 60.0, defaults.analysis_fps),
            analysis_max_side=_number(raw, "analysis_max_side", int, 320, 3840, defaults.analysis_max_side),
            render_video=bool(raw.get("render_video", defaults.render_video)),
            render_height=_number(raw, "render_height", int, 240, 2160, defaults.render_height),
            max_duration_s=_number(raw, "max_duration_s", float, 1.0, 172800.0, defaults.max_duration_s),
            court_length_ft=_number(raw, "court_length_ft", float, 50.0, 100.0, defaults.court_length_ft),
            court_width_ft=_number(raw, "court_width_ft", float, 30.0, 60.0, defaults.court_width_ft),
            calibration=calibration,
            detector_weights=_text(raw.get("detector_weights")),
            court_keypoint_weights=_text(raw.get("court_keypoint_weights")),
            max_frames=None if max_frames is None else _number(raw, "max_frames", int, 0, 10_000_000, 0),
            work_dir=_text(raw.get("work_dir")),
            keep_work_dir=bool(raw.get("keep_work_dir", False)),
        )


def _bad_option(key: str, reason: str) -> PipelineError:
    return PipelineError(errors.PIPELINE_FAILED, f"Invalid processing option '{key}': {reason}.")


def _number(raw: dict[str, Any], key: str, cast: Callable[[Any], Any], low: float, high: float, default: Any) -> Any:
    value = raw.get(key)
    if value is None:
        return default
    try:
        number = cast(value)
    except (TypeError, ValueError):
        raise _bad_option(key, f"{value!r} is not a number") from None
    if not low <= number <= high:
        raise _bad_option(key, f"{number} is outside {low:g}..{high:g}")
    return number


def _text(value: Any) -> str | None:
    return str(value) if value not in (None, "") else None


# ---------------------------------------------------------------------------
# Progress
# ---------------------------------------------------------------------------

# Our stage -> (stage weighted in progress.STAGE_WEIGHTS, start, end share of it). The
# tracker only knows its own stage names, so transcode + OHV share the big "detect" slot.
_STAGE_SLOTS: dict[str, tuple[str, float, float]] = {
    "download": ("download", 0.0, 1.0),
    "probe": ("probe", 0.0, 1.0),
    "transcode": ("detect", 0.0, 0.1),
    "ohv": ("detect", 0.1, 1.0),
    "events": ("events", 0.0, 1.0),
    "render": ("render", 0.0, 1.0),
    "write": ("write", 0.0, 1.0),
}
_TRACKER_STAGES = ["download", "probe", "detect", "events", "render", "write"]


class PipelineProgress:
    """Overall 0-100 progress for our stages; the sink receives our stage names."""

    def __init__(self, sink: ProgressSink | None, *, min_interval_s: float = 2.0) -> None:
        self._sink = sink
        self._stage = "download"
        self._tracker = ProgressTracker(
            self._emit if sink else None, min_interval_s=min_interval_s, stages=_TRACKER_STAGES
        )

    def update(self, stage: str, fraction: float, message: str = "", *, force: bool = False) -> float:
        slot, start, end = _STAGE_SLOTS[stage]
        self._stage = stage
        share = start + (end - start) * min(1.0, max(0.0, fraction))
        return self._tracker.update(slot, 100.0 * share, message, force=force)

    def reporter(self, stage: str) -> Callable[[float, str], None]:
        """A ``(fraction, message)`` callback for one stage (what video/ohv/render accept)."""
        return lambda fraction, message: self.update(stage, fraction, message)

    def done(self, message: str = "Done") -> None:
        self._tracker.done(message)

    def _emit(self, slot: str, pct: float, message: str) -> None:
        assert self._sink is not None
        self._sink("done" if slot == "done" else self._stage, pct, message)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run_pipeline(
    video_path: str,
    options: dict[str, Any],
    *,
    output_dir: str,
    job_id: str,
    progress: ProgressSink | None = None,
    filename: str | None = None,
) -> dict[str, Any]:
    """Process one film and write ``tracking.json.gz`` (+ ``annotated.mp4``) to ``output_dir``.

    Returns the processing response dict (docs/TRACKING_SCHEMA.md): ``{"status": "ok", ...}``
    or ``{"status": "error", "error": {"code", "message", "detail"}}``. Expected failures
    (PipelineError, CUDA OOM after retries) are returned, not raised. ``video_path`` must
    be a local file; URL sources are downloaded by the caller (``video.download_video``).
    """
    started = time.monotonic()
    tracker = PipelineProgress(progress)
    warnings: list[dict[str, str]] = []
    work_dir: Path | None = None
    keep_work = False
    try:
        opts = PipelineOptions.from_dict(options)
        keep_work = opts.keep_work_dir
        out = Path(output_dir)
        out.mkdir(parents=True, exist_ok=True)
        tracker.update("download", 1.0, "Film received", force=True)
        prefix = f"scout-{re.sub(r'[^A-Za-z0-9_-]', '', job_id)[:40]}-"
        work_dir = Path(tempfile.mkdtemp(prefix=prefix, dir=opts.work_dir))
        response = _process(
            Path(video_path), opts, out=out, work=work_dir, job_id=job_id, tracker=tracker, warnings=warnings,
            filename=filename or Path(video_path).name, started=started,
        )  # fmt: skip
        tracker.done("Analysis complete")
        return response
    except PipelineError as exc:
        logger.warning("pipeline failed for %s: %s", job_id, exc)
        return _error_response(job_id, exc, warnings)
    except Exception as exc:  # noqa: BLE001 - anything unexpected becomes PIPELINE_FAILED / GPU_OOM
        logger.exception("unexpected pipeline failure for %s", job_id)
        if is_cuda_oom(exc):
            failure = PipelineError(errors.GPU_OOM, "The GPU ran out of memory.", detail=_traceback_tail())
        else:
            message = f"Unexpected error: {type(exc).__name__}: {exc}"[:300]
            failure = PipelineError(errors.PIPELINE_FAILED, message, detail=_traceback_tail())
        return _error_response(job_id, failure, warnings)
    finally:  # also runs on Modal InputCancellation (a BaseException, deliberately not caught)
        if work_dir is not None and not keep_work:
            shutil.rmtree(work_dir, ignore_errors=True)


def _process(
    source: Path,
    opts: PipelineOptions,
    *,
    out: Path,
    work: Path,
    job_id: str,
    tracker: PipelineProgress,
    warnings: list[dict[str, str]],
    filename: str,
    started: float,
) -> dict[str, Any]:
    tracker.update("probe", 0.0, "Checking the film", force=True)
    probe = video.probe_video(source)
    video.validate_probe(probe, max_duration_s=opts.max_duration_s)
    video.check_decodable(source)
    plan = video.plan_analysis(
        probe, filename=filename, analysis_fps=opts.analysis_fps, max_side=opts.analysis_max_side
    )
    summary = f"Film is {probe.width}x{probe.height}, {probe.fps:.2f} fps, {probe.duration_s / 60:.1f} min"
    tracker.update("probe", 1.0, summary)

    analysed = source
    if plan.transcode:
        tracker.update("transcode", 0.0, "Preparing the film for analysis", force=True)
        analysed = video.transcode_for_analysis(
            source, work / "analysis.mp4", plan, progress=tracker.reporter("transcode")
        )

    tracker.update("ohv", 0.0, "Starting player and ball tracking", force=True)
    run = ohv.run_ohv(
        analysed,
        work / "ohv",
        analysis_fps=plan.analysed_fps,
        expected_frames=plan.expected_frames,
        court=ohv.CourtSpec(length_ft=opts.court_length_ft, width_ft=opts.court_width_ft),
        render=opts.render_video,
        weight_overrides=_weight_overrides(opts),
        max_frames=opts.max_frames,
        progress=tracker.reporter("ohv"),
    )
    warnings.extend(run.warnings)
    _write_log(out / OHV_LOG_FILE, run.log_tail)

    tracker.update("events", 0.0, "Building the event timeline", force=True)
    adapted = adapter.adapt_ohv(
        run.tracks_path,
        plan.meta,
        plan.frame_map,
        court_length_ft=opts.court_length_ft,
        court_width_ft=opts.court_width_ft,
        team_colors_bgr=run.summary.team_colors_bgr,
        calibration=opts.calibration,
        progress=lambda fraction, message: tracker.update("events", 0.8 * fraction, message),
    )
    perception = adapted.perception
    for warning in warnings:
        perception.warn(warning["code"], warning["message"], warning.get("severity", "warning"))
    # The video stream's own frame count: the container duration can include a longer audio track.
    whole_film = None if opts.max_frames is not None else round(plan.meta.frame_count / plan.step)
    check_quality(adapted, expected_frames=whole_film)
    events = merge_events(perception, adapted.events)
    tracker.update("events", 1.0, f"Found {len(events)} game events")

    artifacts: dict[str, str] = {}
    if opts.render_video:
        annotated = _render(run, plan, opts, out, perception, tracker)
        if annotated is not None:
            artifacts["annotated_video"] = volume_path(annotated)

    tracker.update("write", 0.0, "Saving results", force=True)
    stride = result.choose_sample_stride(perception)
    elapsed = time.monotonic() - started
    tracking = result.build_tracking_result(
        perception, events, job_id=job_id, pipeline_info=_pipeline_info(run, plan, opts, stride, elapsed),
        artifacts=artifacts, sample_stride=stride,
    )  # fmt: skip
    size = result.write_tracking_result(tracking, out / TRACKING_FILE)
    tracker.update("write", 1.0, "Results saved")
    tracks = len(tracking["tracks"])
    logger.info("job %s: %d tracks, %d events, tracking.json.gz %.1f MB", job_id, tracks, len(events), size / 1e6)
    return {
        "status": "ok",
        "job_id": job_id,
        "tracking_path": volume_path(out / TRACKING_FILE),
        "annotated_video_path": artifacts.get("annotated_video"),
        "summary": {
            "duration_s": plan.meta.duration_s,
            "tracks": len(perception.player_tracks()),
            "events": len(events),
            "elapsed_s": round(elapsed, 1),
        },
        "warnings": tracking["warnings"],
    }


# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------


def check_quality(adapted: AdapterResult, expected_frames: int | None = None) -> None:
    """Fail on unusable film (DETECTION_FAILED / BALL_NOT_DETECTED); warn on weak data.

    ``expected_frames``: analysed frames the whole film should give. OHV stops at the first
    frame it cannot decode, so a corrupt or cut-off film yields a partial analysis.
    """
    stats, perception = adapted.stats, adapted.perception
    if stats.frames == 0:
        raise PipelineError(errors.VIDEO_DECODE_FAILED, "No frames of the film could be analysed.")
    if stats.median_players < MIN_MEDIAN_PLAYERS:
        raise PipelineError(
            errors.DETECTION_FAILED,
            f"Only {stats.median_players:g} players were visible in a typical frame "
            f"(need at least {MIN_MEDIAN_PLAYERS}).",
            detail=f"median players per frame over {stats.frames} analysed frames",
        )
    if not perception.player_tracks():
        message = "Players were detected but none could be followed from frame to frame."
        raise PipelineError(errors.DETECTION_FAILED, message)
    ball = stats.ball_coverage
    if ball < BALL_MISSING_COVERAGE:
        raise PipelineError(errors.BALL_NOT_DETECTED, f"The ball was found in only {ball:.1%} of frames.")
    if ball < BALL_SPARSE_COVERAGE:
        message = f"The ball was tracked in {ball:.0%} of frames; some shots, passes and possessions may be missed."
        perception.warn("BALL_TRACKING_SPARSE", message)
    if not perception.homographies:  # a manual calibration fills court positions itself
        if stats.court_obs == 0:
            perception.warn(
                "NO_COURT_HOMOGRAPHY",
                "The court lines could not be mapped, so court positions and shot zones are unavailable. "
                "For a fixed camera, calibrate the court on the game page and re-run the analysis.",
            )
        elif stats.court_coverage < COURT_SPARSE_COVERAGE:
            message = (
                f"Court positions were found for {stats.court_coverage:.0%} of player sightings; "
                "shot zones may be incomplete."
            )
            perception.warn("COURT_MAPPING_SPARSE", message)
    min_obs = OCR_MIN_TRACK_S * perception.video.analysis_fps
    regulars = [t for t in perception.player_tracks() if len(t.obs) >= min_obs]
    if regulars and sum(1 for t in regulars if t.jersey_reads) / len(regulars) < OCR_SPARSE_SHARE:
        perception.warn("OCR_SPARSE", "Few jersey numbers could be read; match players to the roster on the game page.")
    if stats.bad_lines:
        message = f"{stats.bad_lines} unreadable frame record(s) were skipped."
        perception.warn("TRACKING_DATA_TRUNCATED", message, "info")
    if expected_frames and stats.frames < PARTIAL_FILM_SHARE * expected_frames:
        fps = perception.video.analysis_fps
        analysed, total = _clock(stats.frames / fps), _clock(expected_frames / fps)
        message = (
            f"Only the first {analysed} of the {total} film could be analysed "
            "(the rest could not be read), so stats and plays cover that part only. "
            "Export the film again and re-upload it to analyse all of it."
        )
        perception.warn("FILM_PARTIALLY_ANALYSED", message)


def _clock(seconds: float) -> str:
    """``75`` -> ``"1:15"``, ``3725`` -> ``"1:02:05"``."""
    minutes, secs = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def merge_events(perception: Perception, ohv_events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """OHV events + the supplementary detectors in ``events`` / ``possession``.

    Each supplementary step is optional: if it fails, a warning is added and the
    pipeline continues with what it has. Returns events sorted by frame with unique ids.
    """
    from modal_app.pipeline import events as extra_events
    from modal_app.pipeline import possession

    if not any(b.holder_track_id is not None for b in perception.ball):
        try:
            possession.assign_ball_holders(perception)
        except Exception:  # noqa: BLE001
            logger.exception("ball-holder assignment failed")
            message = "Ball possession could not be inferred; possessions may be incomplete."
            perception.warn("BALL_HOLDERS_UNAVAILABLE", message)
    try:
        enriched = list(extra_events.enrich_events(perception, ohv_events))
    except Exception:  # noqa: BLE001
        logger.exception("event enrichment failed")
        perception.warn("EVENT_ENRICHMENT_FAILED", "Assists, blocks and rebound types could not be filled in.")
        enriched = list(ohv_events)
    try:
        extra = list(extra_events.detect_events(perception, existing_events=enriched))
    except Exception:  # noqa: BLE001
        logger.exception("supplementary event detection failed")
        perception.warn("EXTRA_EVENTS_FAILED", "Free throws, fouls and screens could not be detected for this film.")
        extra = []
    extra = [e for e in map(_well_formed, extra) if e is not None]
    replaced = {e["attrs"].get("replaces_event_id") for e in extra} - {None}
    merged = [e for e in map(_well_formed, enriched) if e is not None and e.get("event_id") not in replaced] + extra
    merged.sort(key=lambda e: e["frame"])
    for number, event in enumerate(merged, start=1):
        event["event_id"] = f"e{number:05d}"
        event["attrs"].pop("replaces_event_id", None)  # points at a pre-renumbering id
    return merged


def _well_formed(event: Any) -> dict[str, Any] | None:
    """The event with an int ``frame`` (numpy ints too) and a dict ``attrs``; None if unusable."""
    try:
        frame = int(event["frame"])
        if not event["type"]:
            raise ValueError("no type")
    except (KeyError, TypeError, ValueError):
        logger.warning("dropping malformed event %r", event)
        return None
    return {**event, "frame": frame, "attrs": dict(event.get("attrs") or {})}


def _render(
    run: ohv.OhvRun,
    plan: video.AnalysisPlan,
    opts: PipelineOptions,
    out: Path,
    perception: Perception,
    tracker: PipelineProgress,
) -> Path | None:
    """Web copy of OHV's overlay video; a failure only costs the overlay, not the analysis."""
    if run.output_video is None:
        perception.warn("ANNOTATED_VIDEO_MISSING", "No annotated video was produced; the film plays without overlays.")
        return None
    tracker.update("render", 0.0, "Encoding the annotated video", force=True)
    target = out / ANNOTATED_FILE
    try:
        encoder = render.render_web_video(
            run.output_video, target, target_height=opts.render_height, source_height=plan.height,
            expected_frames=plan.expected_frames, progress=tracker.reporter("render"),
        )  # fmt: skip
    except PipelineError as exc:
        logger.warning("annotated video render failed: %s", exc.detail)
        message = "The annotated video could not be encoded; stats and the timeline are unaffected."
        perception.warn("ANNOTATED_VIDEO_FAILED", message)
        return None
    logger.info("annotated video encoded with %s", encoder)
    return target


def _weight_overrides(opts: PipelineOptions) -> dict[str, str]:
    """Custom checkpoints from options (paths may be relative to the volume root)."""
    overrides = {}
    custom = (
        ("rf-detr-basketball.pth", opts.detector_weights),
        ("court_mobilenetv4_896x512.pt", opts.court_keypoint_weights),
    )
    for name, value in custom:
        if value:
            on_volume = Path(VOLUME_ROOT) / value
            overrides[name] = str(on_volume) if not os.path.isabs(value) and on_volume.is_file() else value
    return overrides


def _pipeline_info(
    run: ohv.OhvRun, plan: video.AnalysisPlan, opts: PipelineOptions, stride: int, elapsed: float
) -> dict[str, Any]:
    return {
        "name": "openhoopvision",
        "version": ohv.OHV_COMMIT[:12],
        "models": {
            "detector": f"RF-DETR ({opts.detector_weights or 'rf-detr-basketball.pth'})",
            "pose": "RTMPose-S (rtmpose-s_simcc-aic-coco.pth)",
            "court": f"MobileNetV4 court keypoints ({opts.court_keypoint_weights or 'court_mobilenetv4_896x512.pt'})",
            "tracker": "McByte/ByteTrack + OSNet x1.0 ReID",
            "ocr": "SVTRv2-B jersey numbers",
        },
        "gpu": ohv.gpu_name(),
        "elapsed_s": elapsed,
        "options": {
            "analysis_fps": round(plan.analysed_fps, 4),
            "analysis_size": [plan.width, plan.height],
            "pre_transcoded": plan.transcode,
            "court_ft": [opts.court_length_ft, opts.court_width_ft],
            "ohv_attempts": run.attempts,
            "ohv_seconds": run.elapsed_s,
            "ohv_params": asdict(run.params),
            "track_sample_stride": stride,
            "manual_calibration": opts.calibration is not None,
        },
    }


def volume_path(path: str | os.PathLike[str]) -> str:
    """Path relative to the Modal volume root when it lives there, else absolute."""
    absolute = os.path.abspath(path)
    root = os.path.abspath(VOLUME_ROOT)
    if absolute.startswith(root + os.sep):
        return os.path.relpath(absolute, root).replace(os.sep, "/")
    return absolute


def _write_log(path: Path, lines: list[str]) -> None:
    try:
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    except OSError:
        logger.warning("could not write %s", path)


def _traceback_tail(limit: int = 6000) -> str:
    return traceback.format_exc()[-limit:]


def _error_response(job_id: str, error: PipelineError, warnings: list[dict[str, str]]) -> dict[str, Any]:
    return {"status": "error", "job_id": job_id, "error": error.to_dict(), "warnings": list(warnings)}
