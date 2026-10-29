"""Transform entry point: TrackingResult + roster -> GameAnalysis."""

from __future__ import annotations

import dataclasses
import gc
import logging
import traceback
import zlib
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
from pydantic import ValidationError

from scout import storage
from scout.analysis import boxscore, events, teams
from scout.analysis import plays as play_rec
from scout.analysis.geometry import CourtConfig, apply_homography_many, bbox_foot_point, load_court_config
from scout.analysis.plays import PlayRules
from scout.analysis.tracking_index import TrackingIndex
from scout.errors import ErrorCode, ScoutError
from scout.roster.matcher import assign_tracks
from scout.schemas import (
    TRACKING_SCHEMA_VERSION,
    DataQuality,
    EventType,
    Game,
    GameAnalysis,
    Homography,
    PipelineWarning,
    Point,
    Roster,
    ShotZone,
    TeamSide,
    TeamSummary,
    TrackAssignment,
    TrackingResult,
    TrackOverride,
)

logger = logging.getLogger(__name__)

SUPPORTED_SCHEMA_MAJOR = TRACKING_SCHEMA_VERSION.split(".")[0]
MAX_LISTED_ERRORS = 5
LOW_MATCH_RATE = 0.5
# Pipeline warnings about a missing / sparse court mapping that a manual calibration answers.
COURT_MAPPING_WARNINGS = frozenset({"NO_COURT_HOMOGRAPHY", "COURT_MAPPING_SPARSE"})
# A stored court position this close (feet, each axis) to a calibration's projection of the
# pixel position came from that calibration (the GPU result rounds both to 0.01).
PROJECTED_TOLERANCE_FT = 0.05
_SIDES = (TeamSide.SCOUTED, TeamSide.OTHER)
_TRACKING_HINT = (
    "Re-run the full analysis. If it keeps failing, redeploy the GPU app (`scripts/update.sh --deploy-modal`)."
)


def load_tracking(path: Path) -> TrackingResult:
    """Read ``tracking.json`` / ``tracking.json.gz`` and validate it.

    Raises ``ScoutError(TRACKING_RESULT_INVALID)`` with a readable summary of the first
    validation errors (and the schema version found) when it does not match. A file
    without ``schema_version`` is read as the current version (the model default).
    """
    path = Path(path)
    try:
        data = storage.read_json(path)
    except FileNotFoundError as exc:
        raise ScoutError(ErrorCode.TRACKING_RESULT_INVALID, "No tracking data was found for this game.",
                         hint=_TRACKING_HINT, detail=str(path)) from exc
    except (OSError, EOFError, zlib.error, ValueError) as exc:  # bad gzip, truncated file, bad JSON
        raise ScoutError(ErrorCode.TRACKING_RESULT_INVALID, "The GPU result file is damaged or not valid JSON.",
                         hint=_TRACKING_HINT, detail=f"{path.name}: {type(exc).__name__}: {exc}") from exc
    if not isinstance(data, dict):
        raise ScoutError(ErrorCode.TRACKING_RESULT_INVALID, "The GPU result is not a JSON object.",
                         detail=f"{path.name}: top-level {type(data).__name__}")
    version = str(data.get("schema_version", TRACKING_SCHEMA_VERSION))
    if version.split(".")[0] != SUPPORTED_SCHEMA_MAJOR:
        raise ScoutError(
            ErrorCode.TRACKING_RESULT_INVALID,
            f"The GPU result uses tracking schema version {version}, but this server reads version "
            f"{TRACKING_SCHEMA_VERSION}.",
            detail=f"{path.name}: schema_version={version!r}",
        )
    try:
        return TrackingResult.model_validate(data)
    except ValidationError as exc:
        raise ScoutError(
            ErrorCode.TRACKING_RESULT_INVALID,
            f"The GPU result (schema {version}) does not match the expected format: {_summarize_errors(exc)}",
            detail=str(exc)[:4000],
        ) from exc


def analyze_game(
    tracking: TrackingResult,
    game: Game,
    rosters: dict[TeamSide, Roster],
    overrides: list[TrackOverride] | None = None,
    *,
    court: CourtConfig | None = None,
    rules: PlayRules | None = None,
) -> GameAnalysis:
    """Run the whole transform. Pure function of its inputs (no DB / filesystem access
    beyond the court / play-rule config files when ``court`` / ``rules`` are not given).

    Steps: team map (``teams.resolve_team_map``) -> ``TrackingIndex`` (using
    ``game.calibration.matrix`` when the pipeline produced no homography, see
    ``_court_mapping``) -> roster
    matching (``scout.roster.matcher.assign_tracks``) -> timeline/possessions/shots
    (``events.build_timeline``) -> plays (``plays.detect_plays`` + ``link_plays``) -> box
    scores (``boxscore.build_box_scores``) -> play summary -> ``DataQuality``.

    Without an explicit ``court``, ``config/court.yaml`` is used with the court length /
    width the pipeline measured in (so the homography and the shot zones agree).

    Raises ``ScoutError(ANALYSIS_FAILED)`` wrapping unexpected exceptions.
    """
    try:
        if court is None:
            court = _court_for(tracking)
        if rules is None:
            rules = play_rec.load_play_rules()
        return _analyze(tracking, game, _complete_rosters(rosters, game), overrides or [], court, rules)
    except ScoutError:
        raise
    except Exception as exc:
        logger.exception("Analysis failed for game %s", game.id)
        raise ScoutError(ErrorCode.ANALYSIS_FAILED, detail=_short_traceback(exc)) from exc


def save_analysis(analysis: GameAnalysis, path: Path) -> None:
    """Write ``analysis.json`` atomically (readers never see a half-written file)."""
    storage.write_json(Path(path), analysis.model_dump_json())


def load_analysis(path: Path) -> GameAnalysis:
    """Read a saved analysis; ScoutError(ANALYSIS_NOT_READY) when there is none yet."""
    path = Path(path)
    try:
        return GameAnalysis.model_validate(storage.read_json(path))
    except FileNotFoundError as exc:
        raise ScoutError(ErrorCode.ANALYSIS_NOT_READY, detail=str(path)) from exc
    except (OSError, EOFError, zlib.error, ValueError) as exc:  # includes pydantic ValidationError
        raise ScoutError(
            ErrorCode.ANALYSIS_FAILED,
            "The saved analysis could not be read.",
            hint="Click 'Re-run analysis' to rebuild it.",
            detail=f"{type(exc).__name__}: {exc}"[:4000],
        ) from exc


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def _analyze(
    tracking: TrackingResult,
    game: Game,
    rosters: dict[TeamSide, Roster],
    overrides: list[TrackOverride],
    court: CourtConfig,
    rules: PlayRules,
) -> GameAnalysis:
    tracking, calibration = _court_mapping(game, tracking)
    team_map = teams.resolve_team_map(tracking, game)
    index = TrackingIndex(tracking, court, homography=calibration)
    assignments = assign_tracks(tracking, team_map, rosters, overrides)
    built = events.build_timeline(tracking, index, team_map, assignments, rosters, court)

    plays = play_rec.detect_plays(index, built.timeline, built.possessions, assignments, team_map, court, rules)
    play_rec.link_plays(built.timeline, built.possessions, plays)
    play_by_event = {r.id: r.play_id for r in built.timeline if r.type in (EventType.SHOT_MADE, EventType.SHOT_MISSED)}
    for shot in built.shots:
        shot.play_id = play_by_event.get(shot.event_id)

    team_names = {side: rosters[side].team_name for side in _SIDES}
    box_scores = boxscore.build_box_scores(built.timeline, built.possessions, assignments, rosters, team_names, index)
    summaries = [_team_summary(side, team_names[side], team_map, tracking, built.score) for side in _SIDES]
    quality = _data_quality(tracking, index, assignments, built, rosters, homography=calibration is not None)
    logger.info(
        "Analysed game %s: %d timeline rows, %d possessions, %d plays",
        game.id, len(built.timeline), len(built.possessions), len(plays),
    )
    return GameAnalysis(
        game_id=game.id,
        generated_at=datetime.now(UTC),
        video=tracking.video,
        pipeline=tracking.pipeline,
        teams=summaries,
        timeline=built.timeline,
        possessions=built.possessions,
        plays=plays,
        shots=built.shots,
        box_scores=box_scores,
        play_summary=play_rec.summarize_plays(plays, built.possessions),
        track_assignments=assignments,
        data_quality=quality,
    )


def _court_for(tracking: TrackingResult) -> CourtConfig:
    court = load_court_config()
    dims = {"length_ft": tracking.court.length_ft, "width_ft": tracking.court.width_ft}
    if (court.length_ft, court.width_ft) != (dims["length_ft"], dims["width_ft"]):
        logger.info("Using the pipeline's court size %.0fx%.0f ft", dims["length_ft"], dims["width_ft"])
        court = dataclasses.replace(court, **dims)
    return court


def _complete_rosters(rosters: dict[TeamSide, Roster], game: Game) -> dict[TeamSide, Roster]:
    """Both sides present, each with a team name (roster name > game name > generic)."""
    game_names = {TeamSide.SCOUTED: game.scouted_team, TeamSide.OTHER: game.other_team}
    complete = {}
    for side in _SIDES:
        roster = rosters.get(side) or Roster(game_id=game.id, side=side)
        name = roster.team_name or game_names[side] or events.DEFAULT_TEAM_NAMES[side]
        complete[side] = roster if roster.team_name == name else roster.model_copy(update={"team_name": name})
    return complete


def _court_mapping(game: Game, tracking: TrackingResult) -> tuple[TrackingResult, list[list[float]] | None]:
    """(tracking to analyse, the coach's calibration matrix to apply to it).

    The calibration is only used when the pipeline produced no homography of its own. A GPU
    run that was given a calibration bakes it in (a ``manual`` homography plus the court
    positions projected with it); when the coach has re-calibrated or removed it since, that
    old mapping is dropped so the current calibration (or none) is what the analysis uses.
    """
    current = _calibration_matrix(game, tracking)
    homographies = tracking.court.homographies
    if not homographies:
        return tracking, current
    if any(h.source != "manual" for h in homographies):
        return tracking, None  # the pipeline mapped the court itself
    if current is not None and all(np.allclose(h.matrix, current) for h in homographies):
        return tracking, None  # the GPU run already used this calibration
    logger.info("Court calibration changed since the GPU run; re-mapping the court positions")
    return _without_baked_calibration(tracking), current


def _calibration_matrix(game: Game, tracking: TrackingResult) -> list[list[float]] | None:
    """The coach's manual court calibration, rescaled to the tracking resolution."""
    cal = game.calibration
    if cal is None:
        return None
    sx = cal.video_width / tracking.video.width if cal.video_width else 1.0
    sy = cal.video_height / tracking.video.height if cal.video_height else 1.0
    if sx == 1.0 and sy == 1.0:
        return cal.matrix
    return (np.asarray(cal.matrix, dtype=float) @ np.diag([sx, sy, 1.0])).tolist()


def _without_baked_calibration(tracking: TrackingResult) -> TrackingResult:
    """``tracking`` minus its manual homographies and the court positions projected with them
    (positions from the pipeline's court model are kept). The input is not modified."""
    baked = tracking.court.homographies
    stale_by_track: dict[int, dict[int, Point]] = {}  # track -> {frame: dropped court_xy}
    tracks, ball = [], []
    # Up to ~1M replacement samples: the cyclic GC would rescan the whole result many times
    # over while they are built, and none of them form reference cycles.
    gc_was_enabled = gc.isenabled()
    gc.disable()
    try:
        for track in tracking.tracks:
            feet = [bbox_foot_point(s.bbox) for s in track.samples]
            stale = _projected_by(baked, [s.f for s in track.samples], feet, [s.court_xy for s in track.samples])
            if stale.any():
                hits = list(zip(track.samples, stale.tolist(), strict=True))
                stale_by_track[track.track_id] = {s.f: s.court_xy for s, hit in hits if hit}
                samples = [s.model_copy(update={"court_xy": None}) if hit else s for s, hit in hits]
                track = track.model_copy(update={"samples": samples})
            tracks.append(track)
        stale = _projected_by(baked, [b.f for b in tracking.ball], [b.xy for b in tracking.ball],
                              [b.court_xy for b in tracking.ball])
        for b, hit in zip(tracking.ball, stale.tolist(), strict=True):
            held = stale_by_track.get(b.holder_track_id, {}).get(b.f) if b.holder_track_id is not None else None
            if hit or (held is not None and b.court_xy is not None and _same_point(held, b.court_xy)):
                b = b.model_copy(update={"court_xy": None})  # the ball took its holder's (projected) position
            ball.append(b)
    finally:
        if gc_was_enabled:
            gc.enable()
    court = tracking.court.model_copy(update={"homographies": []})
    return tracking.model_copy(update={"court": court, "tracks": tracks, "ball": ball})


def _same_point(a: Point, b: Point) -> bool:
    return abs(a[0] - b[0]) <= PROJECTED_TOLERANCE_FT and abs(a[1] - b[1]) <= PROJECTED_TOLERANCE_FT


def _projected_by(
    homographies: list[Homography], frames: list[int], px: list[Point], court_xy: list[Point | None]
) -> np.ndarray:
    """Per sample: True when its court position is the projection of its pixel position by the
    homography covering its frame."""
    stale = np.zeros(len(frames), dtype=bool)
    if not len(frames):
        return stale
    frames = np.asarray(frames)
    px = np.asarray(px, dtype=float).reshape(-1, 2)
    court = np.asarray([xy if xy is not None else (np.nan, np.nan) for xy in court_xy], dtype=float)
    for h in homographies:
        covered = (frames >= h.frame_start) & (frames <= (h.frame_end if h.frame_end is not None else frames.max()))
        rows = np.flatnonzero(covered)
        if len(rows):
            close = np.abs(apply_homography_many(h.matrix, px[rows]) - court[rows]) <= PROJECTED_TOLERANCE_FT
            stale[rows[close.all(axis=1)]] = True  # NaN (no position / horizon) never matches
    return stale


def _team_summary(
    side: TeamSide, name: str, team_map: dict[int, TeamSide], tracking: TrackingResult, score: dict[TeamSide, int]
) -> TeamSummary:
    team_id = next((tid for tid, s in sorted(team_map.items()) if s == side), None)
    info = next((t for t in tracking.teams if t.team_id == team_id), None)
    return TeamSummary(
        side=side,
        name=name,
        team_id=team_id,
        color_rgb=info.color_rgb if info else None,
        color_name=info.color_name if info else None,
        score=score.get(side, 0),
    )


# ---------------------------------------------------------------------------
# Data quality
# ---------------------------------------------------------------------------


def _data_quality(
    tracking: TrackingResult,
    index: TrackingIndex,
    assignments: list[TrackAssignment],
    built: events.TimelineBuild,
    rosters: dict[TeamSide, Roster],
    *,
    homography: bool,
) -> DataQuality:
    """How much to trust the numbers. Jersey matching is judged only for sides that have
    a roster (with no roster there is nothing to match against)."""
    players = [a for a in assignments if a.role == "player" and not a.ignored]
    rostered_sides = {side for side in _SIDES if rosters[side].players}
    matchable = [a for a in players if a.side in rostered_sides]
    weight = {a.track_id: a.frames or index.track_sample_count(a.track_id) for a in matchable}
    total = sum(weight.values())
    matched = sum(weight[a.track_id] for a in matchable if a.player_id)
    match_rate = round(matched / total, 3) if total else 0.0
    unmatched = sorted(
        {(a.side, a.jersey or a.best_read) for a in matchable if not a.player_id and (a.jersey or a.best_read)},
        key=lambda k: (_SIDES.index(k[0]), boxscore.jersey_sort_key(k[1])),
    )
    primary = [r.confidence for r in built.timeline if r.source_event_id is not None and r.id == r.source_event_id]
    # After the coach calibrated, "the court could not be mapped: calibrate it" no longer applies.
    pipeline_warnings = [w for w in tracking.warnings if not (homography and w.code in COURT_MAPPING_WARNINGS)]
    zones_known = any(s.zone != ShotZone.UNKNOWN for s in built.shots)
    warnings = pipeline_warnings + _analysis_warnings(rosters, index, match_rate if total else None, zones_known)
    return DataQuality(
        # "Court mapped" on the Data tab and in the report: court feet from a homography, the coach's
        # calibration or the pipeline's court model (OpenHoopVision sends positions, never matrices).
        homography_available=index.coord_mode == "court",
        coord_mode=index.coord_mode,
        ball_coverage=round(index.ball_coverage, 3),
        jersey_match_rate=match_rate,
        unmatched_jerseys=[f"{side.value}:#{jersey}" for side, jersey in unmatched],
        tracks_total=len(players),
        tracks_assigned=sum(1 for a in players if a.player_id),
        event_confidence_mean=round(sum(primary) / len(primary), 3) if primary else None,
        warnings=warnings,
    )


def _analysis_warnings(
    rosters: dict[TeamSide, Roster], index: TrackingIndex, match_rate: float | None, zones_known: bool = False
) -> list[PipelineWarning]:
    """Coach-facing notes about what the analysis could not do."""
    notes = []
    for side in _SIDES:
        if not rosters[side].players:
            notes.append(PipelineWarning(
                code="NO_ROSTER",
                message=f"No roster for {rosters[side].team_name}: players are shown by jersey number only",
                severity="warning" if side == TeamSide.SCOUTED else "info",
            ))
    if index.coord_mode == "pixel":
        what = (
            "Court mapped for only part of the film: shots without a court position have no zone"
            if zones_known else "Court not mapped: shot zones are unknown"
        )
        notes.append(PipelineWarning(
            code="COURT_NOT_MAPPED",
            message=f"{what}. For a fixed camera, calibrate the court on the game page and re-run the analysis.",
        ))
    if match_rate is not None and match_rate < LOW_MATCH_RATE:
        notes.append(PipelineWarning(
            code="LOW_JERSEY_MATCH",
            message=f"Only {match_rate:.0%} of player time was matched to roster jerseys: check the roster numbers "
            "or assign players to tracks on the roster page.",
        ))
    return notes


def _summarize_errors(exc: ValidationError) -> str:
    errors = exc.errors()
    parts = [
        f"{'.'.join(str(p) for p in err['loc']) or '(root)'}: {err['msg']}" for err in errors[:MAX_LISTED_ERRORS]
    ]
    if len(errors) > MAX_LISTED_ERRORS:
        parts.append(f"... and {len(errors) - MAX_LISTED_ERRORS} more")
    return "; ".join(parts)


def _short_traceback(exc: BaseException, max_lines: int = 12) -> str:
    lines = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__)).strip().splitlines()
    return "\n".join(lines[-max_lines:])
