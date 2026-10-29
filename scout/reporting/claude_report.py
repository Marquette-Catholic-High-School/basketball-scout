"""Scouting report generation with the Claude API (Anthropic Python SDK)."""

from __future__ import annotations

from typing import Any

from scout.config import Settings
from scout.schemas import Game, GameAnalysis, ReportRecord, Roster, TeamSide


def build_report_payload(analysis: GameAnalysis, game: Game, rosters: dict[TeamSide, Roster]) -> dict[str, Any]:
    """Compact, deterministic (sorted keys, rounded floats) JSON-able summary for Claude:
    game info, team box scores, player lines, shot zones, play-type summary with PPP,
    defensive looks, transition stats, notable sequences, data-quality caveats."""
    raise NotImplementedError


def generate_report(
    analysis: GameAnalysis,
    game: Game,
    rosters: dict[TeamSide, Roster],
    *,
    coach_focus: str | None = None,
    settings: Settings | None = None,
    client: Any | None = None,
) -> ReportRecord:
    """Call Claude and return a validated report. ``client`` is injectable for tests.

    Raises ``ScoutError`` with REPORT_NOT_CONFIGURED / REPORT_AUTH_FAILED /
    REPORT_RATE_LIMITED / REPORT_OVERLOADED / REPORT_REFUSED / REPORT_TRUNCATED /
    REPORT_FAILED.
    """
    raise NotImplementedError
