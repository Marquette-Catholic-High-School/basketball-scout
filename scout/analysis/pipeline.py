"""Transform entry point: TrackingResult + roster -> GameAnalysis."""

from __future__ import annotations

from pathlib import Path

from scout.analysis.geometry import CourtConfig
from scout.analysis.plays import PlayRules
from scout.schemas import Game, GameAnalysis, Roster, TeamSide, TrackingResult, TrackOverride


def load_tracking(path: Path) -> TrackingResult:
    """Read ``tracking.json`` / ``tracking.json.gz`` and validate it.

    Raises ``ScoutError(TRACKING_RESULT_INVALID)`` with a readable summary of the first
    validation errors (and the schema version found) when it does not match.
    """
    raise NotImplementedError


def analyze_game(
    tracking: TrackingResult,
    game: Game,
    rosters: dict[TeamSide, Roster],
    overrides: list[TrackOverride] | None = None,
    *,
    court: CourtConfig | None = None,
    rules: PlayRules | None = None,
) -> GameAnalysis:
    """Run the whole transform. Pure function of its inputs (no DB / filesystem access).

    Steps: team map (``teams.resolve_team_map``) -> ``TrackingIndex`` (using
    ``game.calibration.matrix`` when the pipeline produced no homography) -> roster
    matching (``scout.roster.matcher.assign_tracks``) -> timeline/possessions/shots
    (``events.build_timeline``) -> plays (``plays.detect_plays`` + ``link_plays``) -> box
    scores (``boxscore.build_box_scores``) -> play summary -> ``DataQuality``.

    Raises ``ScoutError(ANALYSIS_FAILED)`` wrapping unexpected exceptions.
    """
    raise NotImplementedError


def save_analysis(analysis: GameAnalysis, path: Path) -> None:
    raise NotImplementedError


def load_analysis(path: Path) -> GameAnalysis:
    raise NotImplementedError
