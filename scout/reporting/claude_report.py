"""Scouting report generation with the Claude API (Anthropic Python SDK).

Flow: ``build_report_payload`` turns a GameAnalysis into a compact, deterministic dict
-> it is sent as one cached JSON block, followed by the task text (with the coach's
optional focus) -> Claude answers with JSON matching ``REPORT_SCHEMA`` (structured
output) -> validated as a ``ScoutingReport`` -> rendered to Markdown.

API notes (Claude Opus 5.5, API version 2026-10-21): thinking is always adaptive (never
"disabled", never budget_tokens); temperature / top_p / top_k and assistant prefill are
rejected, so none of them is sent. Output can be long, so the request is streamed.
Server-side refusal fallbacks (a beta) are on unless ``SCOUT_CLAUDE_FALLBACKS=false``.
"""

from __future__ import annotations

import json
import logging
from collections import Counter
from itertools import groupby
from typing import Any

import anthropic
from pydantic import ValidationError

from scout.config import Settings, get_settings
from scout.errors import ErrorCode, ScoutError
from scout.reporting.prompts import REPORT_SCHEMA, SYSTEM_PROMPT, build_user_prompt
from scout.reporting.render import report_to_markdown
from scout.schemas import (
    PLAY_TYPE_LABELS,
    BoxScoreLine,
    EventType,
    Game,
    GameAnalysis,
    PlayerRef,
    PlayType,
    ReportRecord,
    Roster,
    ScoutingReport,
    TeamSide,
    ZoneSplits,
)

logger = logging.getLogger(__name__)

__all__ = ["FALLBACK_BETA", "PAYLOAD_TOKEN_BUDGET", "REPORT_SCHEMA", "build_report_payload", "generate_report"]

FALLBACK_BETA = "server-side-fallback-2026-07-01"
PAYLOAD_TOKEN_BUDGET = 25_000
_CHARS_PER_TOKEN = 3.0  # conservative for compact JSON (numbers and punctuation tokenize densely)
_TRIM_ORDER = ("play_log", "scoring_runs", "tendencies", "turnovers")  # lowest value first; box scores never go
_PLAY_LOG_LIMIT = 150
_RUN_MIN_POINTS = 8
_TOP_PLAYERS_PER_ROLE = 4
_MAX_WARNINGS = 12
_MAX_UNMATCHED_JERSEYS = 20
_MAX_SHOT_LOCATIONS = 12
_MAX_FOCUS_CHARS = 2000
_USAGE_FIELDS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
_SERVER_ERROR_TYPES = frozenset({"overloaded_error", "api_error"})

# ---------------------------------------------------------------------------
# Payload
# ---------------------------------------------------------------------------


def _round2(value: float | None) -> float | None:
    return None if value is None else round(value, 2)


def _pct(share: float | None) -> float | None:
    """0..1 share -> percentage with one decimal."""
    return None if share is None else round(share * 100, 1)


def _ratio_pct(part: int, whole: int) -> float | None:
    return round(100 * part / whole, 1) if whole else None


def _drop_none(values: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in values.items() if value is not None}


def _clock(seconds: float) -> str:
    total = max(0, int(seconds))
    return f"{total // 60:02d}:{total % 60:02d}"


def _payload_json(payload: dict[str, Any]) -> str:
    """Byte-stable serialisation so an unchanged game re-uses the prompt cache."""
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _estimated_tokens(payload: dict[str, Any]) -> int:
    return int(len(_payload_json(payload)) / _CHARS_PER_TOKEN)


def _team_name(analysis: GameAnalysis, side: TeamSide) -> str:
    team = analysis.team(side)
    box = analysis.box_score(side)
    return (team.name if team else "") or (box.team_name if box else "") or side.value


def _score(analysis: GameAnalysis, side: TeamSide) -> int:
    team = analysis.team(side)
    if team is not None:
        return team.score
    box = analysis.box_score(side)
    return box.totals.pts if box else 0


def _player_label(ref: PlayerRef, roster: Roster | None) -> str:
    """Label like "#23 Jordan Smith", preferring the current roster spelling."""
    player = roster.by_id(ref.player_id) if roster is not None and ref.player_id else None
    if player is None:
        return ref.label
    return f"#{player.jersey} {player.name}" if player.name else f"#{player.jersey}"


def _line_stats(line: BoxScoreLine, *, minutes: bool = True) -> dict[str, Any]:
    """Compact stat line; team lines skip minutes (five players' worth would only confuse)."""
    return _drop_none(
        {
            "min": int(line.minutes_est + 0.5) if minutes and line.minutes_est is not None else None,
            "pts": line.pts,
            "fg": f"{line.fgm}-{line.fga}",
            "fg_pct": _ratio_pct(line.fgm, line.fga),
            "3pt": f"{line.tpm}-{line.tpa}",
            "3pt_pct": _ratio_pct(line.tpm, line.tpa),
            "ft": f"{line.ftm}-{line.fta}",
            "ft_pct": _ratio_pct(line.ftm, line.fta),
            "oreb": line.oreb,
            "dreb": line.dreb,
            "reb": line.reb,
            "ast": line.ast,
            "stl": line.stl,
            "blk": line.blk,
            "tov": line.tov,
            "pf": line.pf,
            "plus_minus": line.plus_minus,
        }
    )


def _has_stats(line: BoxScoreLine) -> bool:
    return any((line.pts, line.fga, line.fta, line.oreb, line.dreb, line.ast, line.stl, line.blk, line.tov, line.pf))


def _played(line: BoxScoreLine) -> bool:
    return _has_stats(line) or (line.minutes_est or 0.0) >= 1.0


def _player_zones(zones: ZoneSplits) -> dict[str, str]:
    splits = {name: getattr(zones, name) for name in ("paint", "mid", "three", "unknown")}
    return {name: f"{s.made}-{s.attempts}" for name, s in splits.items() if s.attempts}


def _team_zones(zones: ZoneSplits) -> dict[str, Any]:
    splits = {name: getattr(zones, name) for name in ("paint", "mid", "three", "unknown")}
    total = sum(s.attempts for s in splits.values())
    return {
        name: {
            "fg": f"{s.made}-{s.attempts}",
            "fg_pct": _ratio_pct(s.made, s.attempts),
            "share_pct": _ratio_pct(s.attempts, total),
        }
        for name, s in splits.items()
        if s.attempts
    }


def _shot_locations(analysis: GameAnalysis, side: TeamSide) -> dict[str, str]:
    """Made-attempted per court sub-zone (left_corner_3, top_mid...), most attempts first."""
    made: Counter[str] = Counter()
    attempts: Counter[str] = Counter()
    for shot in analysis.shots:
        if shot.side == side and shot.subzone:
            attempts[shot.subzone] += 1
            made[shot.subzone] += int(shot.made)
    ranked = sorted(attempts, key=lambda zone: (-attempts[zone], zone))[:_MAX_SHOT_LOCATIONS]
    return {zone: f"{made[zone]}-{attempts[zone]}" for zone in ranked}


def _player_entry(line: BoxScoreLine, roster: Roster | None) -> dict[str, Any]:
    player = roster.by_id(line.player.player_id) if roster is not None and line.player.player_id else None
    entry: dict[str, Any] = {
        "jersey": (player.jersey if player else line.player.jersey) or "?",
        "name": (player.name if player else line.player.name) or "Unknown",
        **_line_stats(line),
    }
    zones = _player_zones(line.zones)
    if zones:
        entry["zones"] = zones
    if player is not None:
        entry.update(_drop_none({"pos": player.position, "height": player.height, "grade": player.grade}))
    return entry


def _jersey_sort_key(entry: dict[str, Any]) -> tuple[int, int, str]:
    jersey = str(entry["jersey"])
    return (0, int(jersey), entry["name"]) if jersey.isdigit() else (1, 0, entry["name"])


def _scouted_section(analysis: GameAnalysis, roster: Roster | None) -> dict[str, Any]:
    box = analysis.box_score(TeamSide.SCOUTED)
    if box is None:
        return {"name": _team_name(analysis, TeamSide.SCOUTED)}
    players = sorted((_player_entry(line, roster) for line in box.players if _played(line)), key=_jersey_sort_key)
    totals, unattributed = box.totals, box.team_unattributed
    return _drop_none(
        {
            "name": _team_name(analysis, TeamSide.SCOUTED),
            "possessions": box.possessions,
            "ppp": _round2(box.points_per_possession),
            "totals": _line_stats(totals, minutes=False),
            "unattributed": _line_stats(unattributed, minutes=False) if _has_stats(unattributed) else None,
            "players": players,
            "shot_zones": _team_zones(totals.zones) or None,
            "shot_locations": _shot_locations(analysis, TeamSide.SCOUTED) or None,
            "three_point_rate_pct": _ratio_pct(totals.tpa, totals.fga),
            "free_throw_rate_pct": _ratio_pct(totals.fta, totals.fga),
        }
    )


def _other_section(analysis: GameAnalysis) -> dict[str, Any]:
    box = analysis.box_score(TeamSide.OTHER)
    section: dict[str, Any] = {"name": _team_name(analysis, TeamSide.OTHER)}
    if box is not None:
        section["possessions"] = box.possessions
        section["ppp"] = _round2(box.points_per_possession)
        section["totals"] = _line_stats(box.totals, minutes=False)
    return _drop_none(section)


def _game_section(analysis: GameAnalysis, game: Game) -> dict[str, Any]:
    periods = sum(1 for event in analysis.timeline if event.type == EventType.PERIOD_START)
    return _drop_none(
        {
            "scouted_team": game.scouted_team,
            "other_team": game.other_team or _team_name(analysis, TeamSide.OTHER),
            "date": game.game_date.isoformat() if game.game_date else None,
            "level": game.level,
            "location": game.location,
            "final_score": {"scouted": _score(analysis, TeamSide.SCOUTED), "other": _score(analysis, TeamSide.OTHER)},
            "film_minutes": round(analysis.video.duration_s / 60, 1),
            "periods_seen": periods or None,
        }
    )


def _play_types(analysis: GameAnalysis, side: TeamSide, category: str) -> list[dict[str, Any]]:
    summaries = sorted(
        (s for s in analysis.play_summary if s.side == side and s.category == category),
        key=lambda s: (-s.count, s.type.value),
    )
    return [
        _drop_none(
            {
                "type": s.type.value,
                "label": PLAY_TYPE_LABELS.get(s.type, s.type.value),
                "count": s.count,
                "poss_pct": _pct(s.possessions_pct),
                "points": s.points,
                "ppp": _round2(s.ppp),
                "fg": f"{s.fgm}-{s.fga}",
                "tov": s.turnovers,
            }
        )
        for s in summaries
    ]


def _defense_section(analysis: GameAnalysis) -> dict[str, Any]:
    shapes = Counter(
        str(play.attrs["zone_shape"])
        for play in analysis.plays
        if play.type == PlayType.ZONE_DEFENSE and play.side == TeamSide.SCOUTED and play.attrs.get("zone_shape")
    )
    return _drop_none(
        {
            "defensive_possessions": sum(1 for p in analysis.possessions if p.side == TeamSide.OTHER),
            "looks": _play_types(analysis, TeamSide.SCOUTED, "defense"),
            "zone_shapes": dict(sorted(shapes.items())) or None,
        }
    )


def _transition(analysis: GameAnalysis, side: TeamSide) -> dict[str, Any]:
    fast_breaks = [play for play in analysis.plays if play.type == PlayType.FAST_BREAK and play.side == side]
    fast_break_ids = {play.id for play in fast_breaks}
    possessions = [p for p in analysis.possessions if p.side == side]
    transition = [p for p in possessions if p.transition or fast_break_ids.intersection(p.play_ids)]
    points = sum(p.points for p in transition)
    numbers = Counter(str(play.attrs["numbers"]) for play in fast_breaks if play.attrs.get("numbers"))
    return _drop_none(
        {
            "possessions": len(transition),
            "share_pct": _ratio_pct(len(transition), len(possessions)),
            "points": points,
            "ppp": round(points / len(transition), 2) if transition else None,
            "numbers": dict(sorted(numbers.items())) or None,
        }
    )


def _play_roles(analysis: GameAnalysis, roster: Roster | None) -> dict[str, dict[str, list[dict[str, Any]]]]:
    """Per offensive play type and role: the scouted players involved most often."""
    tallies: dict[tuple[str, str, str], tuple[int, int]] = {}
    for play in analysis.plays:
        if play.side != TeamSide.SCOUTED or play.category != "offense":
            continue
        for role, ref in play.players.items():
            key = (play.type.value, role, _player_label(ref, roster))
            count, points = tallies.get(key, (0, 0))
            tallies[key] = (count + 1, points + play.points)
    roles: dict[str, dict[str, list[dict[str, Any]]]] = {}
    ranked = sorted(tallies.items(), key=lambda kv: (kv[0][0], kv[0][1], -kv[1][0], kv[0][2]))
    for (play_type, role, label), (count, points) in ranked:
        players = roles.setdefault(play_type, {}).setdefault(role, [])
        if len(players) < _TOP_PLAYERS_PER_ROLE:
            players.append({"player": label, "plays": count, "points": points})
    return roles


def _free_throws(analysis: GameAnalysis, roster: Roster | None) -> list[dict[str, Any]]:
    box = analysis.box_score(TeamSide.SCOUTED)
    lines = [line for line in box.players if line.fta] if box else []
    lines.sort(key=lambda line: (-line.fta, _player_label(line.player, roster)))
    return [
        _drop_none(
            {
                "player": _player_label(line.player, roster),
                "ft": f"{line.ftm}-{line.fta}",
                "ft_pct": _ratio_pct(line.ftm, line.fta),
            }
        )
        for line in lines
    ]


def _tendencies(analysis: GameAnalysis, roster: Roster | None) -> dict[str, Any]:
    sections = {"play_roles": _play_roles(analysis, roster), "free_throws": _free_throws(analysis, roster)}
    return {key: value for key, value in sections.items() if value}


def _turnovers(analysis: GameAnalysis) -> dict[str, Any]:
    scouted, other = analysis.box_score(TeamSide.SCOUTED), analysis.box_score(TeamSide.OTHER)
    committed = Counter(
        event.label
        for event in analysis.timeline
        if event.type == EventType.TURNOVER and event.side == TeamSide.SCOUTED
    )
    return {
        "committed": _drop_none(
            {
                "total": scouted.totals.tov if scouted else sum(committed.values()),
                "stolen": other.totals.stl if other else None,
                "by_type": dict(sorted(committed.items())) or None,
            }
        ),
        "forced": _drop_none(
            {"total": other.totals.tov if other else None, "steals": scouted.totals.stl if scouted else None}
        ),
    }


def _scoring_runs(analysis: GameAnalysis) -> list[dict[str, Any]]:
    """Unanswered runs of at least ``_RUN_MIN_POINTS`` points."""
    scoring = [event for event in analysis.timeline if event.points and event.side is not None]
    runs = []
    for side, group in groupby(scoring, key=lambda event: event.side):
        events = list(group)
        points = sum(event.points for event in events)
        if side is not None and points >= _RUN_MIN_POINTS:
            runs.append(
                {
                    "team": _team_name(analysis, side),
                    "run": f"{points}-0",
                    "from": _clock(events[0].t),
                    "to": _clock(events[-1].t),
                }
            )
    return runs


def _play_log(analysis: GameAnalysis, roster: Roster | None) -> list[dict[str, Any]]:
    plays = sorted(
        (p for p in analysis.plays if p.side == TeamSide.SCOUTED and p.category == "offense"),
        key=lambda p: (p.start_t, p.id),
    )
    log = []
    for play in plays[:_PLAY_LOG_LIMIT]:
        players = ", ".join(f"{role} {_player_label(ref, roster)}" for role, ref in sorted(play.players.items()))
        log.append(
            _drop_none(
                {
                    "t": _clock(play.start_t),
                    "play": PLAY_TYPE_LABELS.get(play.type, play.type.value),
                    "players": players or None,
                    "result": play.outcome.value,
                    "pts": play.points,
                }
            )
        )
    return log


def _data_quality(analysis: GameAnalysis) -> dict[str, Any]:
    quality = analysis.data_quality
    box = analysis.box_score(TeamSide.SCOUTED)
    warnings = list(dict.fromkeys(f"{w.code}: {w.message}" for w in quality.warnings))[:_MAX_WARNINGS]
    return _drop_none(
        {
            "pipeline": analysis.pipeline.name,
            "court_mapped": quality.homography_available,
            "coord_mode": quality.coord_mode,
            "jersey_match_rate_pct": _pct(quality.jersey_match_rate),
            "ball_coverage_pct": _pct(quality.ball_coverage),
            "event_confidence_mean": _round2(quality.event_confidence_mean),
            "tracks_total": quality.tracks_total,
            "tracks_assigned": quality.tracks_assigned,
            "unmatched_jerseys": quality.unmatched_jerseys[:_MAX_UNMATCHED_JERSEYS] or None,
            "unattributed_points": box.team_unattributed.pts if box else None,
            "shots_without_location": box.totals.zones.unknown.attempts if box else None,
            "warnings": warnings or None,
        }
    )


def _fit_budget(payload: dict[str, Any], token_budget: int) -> dict[str, Any]:
    """Drop low-value sections until the payload fits; record what was dropped (never the box scores)."""
    omitted = []
    for key in _TRIM_ORDER:
        if _estimated_tokens(payload) <= token_budget:
            break
        if payload.pop(key, None) is not None:
            omitted.append(key)
    if omitted:
        payload["omitted_sections"] = omitted
        logger.info("Report payload trimmed to fit ~%d tokens: dropped %s", token_budget, ", ".join(omitted))
    if _estimated_tokens(payload) > token_budget:
        logger.warning("Report payload is still ~%d tokens after trimming.", _estimated_tokens(payload))
    return payload


def build_report_payload(
    analysis: GameAnalysis,
    game: Game,
    rosters: dict[TeamSide, Roster],
    *,
    token_budget: int = PAYLOAD_TOKEN_BUDGET,
) -> dict[str, Any]:
    """Compact, deterministic (sorted, rounded) JSON-able summary of the game for Claude.

    Game info, the scouted team's box score (players who played + totals), the other
    team's totals, shot zones, play types with PPP, defensive looks, transition, player
    tendencies, turnovers, scoring runs, a play log and data-quality caveats. Sections are
    dropped in ``_TRIM_ORDER`` if the payload would exceed ``token_budget`` (listed under
    ``omitted_sections`` so nothing disappears silently).
    """
    roster = rosters.get(TeamSide.SCOUTED)
    payload: dict[str, Any] = {
        "game": _game_section(analysis, game),
        "scouted_team": _scouted_section(analysis, roster),
        "other_team": _other_section(analysis),
        "scouted_offense": {"play_types": _play_types(analysis, TeamSide.SCOUTED, "offense")},
        "scouted_defense": _defense_section(analysis),
        "transition": {side.value: _transition(analysis, side) for side in TeamSide},
        "tendencies": _tendencies(analysis, roster),
        "turnovers": _turnovers(analysis),
        "scoring_runs": _scoring_runs(analysis),
        "play_log": _play_log(analysis, roster),
        "data_quality": _data_quality(analysis),
    }
    return _fit_budget(payload, token_budget)


# ---------------------------------------------------------------------------
# Request / response
# ---------------------------------------------------------------------------


def _build_request(settings: Settings, payload_json: str, task_text: str) -> dict[str, Any]:
    """Keyword arguments for ``client.beta.messages.stream``.

    Cache breakpoints sit on the constant system prompt and on the game-data block, so
    regenerating with a different coach focus only re-sends the short task text.
    """
    request: dict[str, Any] = {
        "model": settings.claude_model,
        "max_tokens": settings.claude_max_tokens,
        "system": [{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}],
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": payload_json, "cache_control": {"type": "ephemeral"}},
                    {"type": "text", "text": task_text},
                ],
            }
        ],
        "thinking": {"type": "adaptive"},
        "output_config": {"effort": settings.claude_effort, "format": {"type": "json_schema", "schema": REPORT_SCHEMA}},
    }
    if settings.claude_fallbacks:
        request["betas"] = [FALLBACK_BETA]
        request["fallbacks"] = "default"
    return request


def _stream(client: Any, request: dict[str, Any]) -> Any:
    with client.beta.messages.stream(**request) as stream:
        return stream.get_final_message()


def _api_message(exc: anthropic.APIError) -> str:
    """The API's own error message when the body has one."""
    body = exc.body
    if isinstance(body, dict) and isinstance(body.get("error"), dict) and body["error"].get("message"):
        return str(body["error"]["message"])
    return exc.message


def _stream_with_fallback_retry(client: Any, request: dict[str, Any]) -> Any:
    """Stream once; if the API rejects the refusal-fallback beta itself, retry once without it."""
    try:
        return _stream(client, request)
    except anthropic.BadRequestError as exc:
        if "fallbacks" not in request or "fallback" not in _api_message(exc).lower():
            raise
        logger.warning("Anthropic API rejected the refusal fallback (%s); retrying without it.", _api_message(exc))
        return _stream(client, {key: value for key, value in request.items() if key not in ("betas", "fallbacks")})


def _error_detail(exc: anthropic.APIError) -> str:
    if isinstance(exc, anthropic.APIStatusError):
        request_id = f" (request id {exc.request_id})" if exc.request_id else ""
        return f"{type(exc).__name__} {exc.status_code}: {_api_message(exc)}{request_id}"
    return f"{type(exc).__name__}: {exc.message}"


def _is_server_error(exc: anthropic.APIError) -> bool:
    """5xx / overloaded, including errors that arrive mid-stream (HTTP 200 with an error event)."""
    if isinstance(exc, (anthropic.OverloadedError, anthropic.ServiceUnavailableError, anthropic.InternalServerError)):
        return True
    return isinstance(exc, anthropic.APIStatusError) and (exc.status_code >= 500 or exc.type in _SERVER_ERROR_TYPES)


def _scout_error(exc: anthropic.APIError, model: str) -> ScoutError:
    """Map an SDK error to the coach-facing error taxonomy (most specific first)."""
    detail = _error_detail(exc)
    if isinstance(exc, (anthropic.AuthenticationError, anthropic.PermissionDeniedError)):
        return ScoutError(ErrorCode.REPORT_AUTH_FAILED, detail=detail)
    if isinstance(exc, anthropic.NotFoundError):
        return ScoutError(
            ErrorCode.REPORT_FAILED,
            f"Model not found - check SCOUT_CLAUDE_MODEL (currently {model!r}).",
            hint="Set SCOUT_CLAUDE_MODEL in .env to a model your Anthropic account can use, then restart the worker.",
            retryable=False,
            detail=detail,
        )
    status_error = exc if isinstance(exc, anthropic.APIStatusError) else None
    rate_limited = status_error is not None and status_error.type == "rate_limit_error"
    if isinstance(exc, anthropic.RateLimitError) or rate_limited:
        retry_after = status_error.response.headers.get("retry-after") if status_error is not None else None
        message = "The Anthropic API is rate limiting this key."
        if retry_after:
            message += f" It asked us to wait {retry_after} seconds before trying again."
        return ScoutError(ErrorCode.REPORT_RATE_LIMITED, message, detail=detail)
    if _is_server_error(exc):
        return ScoutError(ErrorCode.REPORT_OVERLOADED, detail=detail)
    if isinstance(exc, anthropic.BadRequestError):
        message = f"The Anthropic API rejected the request: {_api_message(exc)}"
        return ScoutError(ErrorCode.REPORT_FAILED, message, retryable=False, detail=detail)
    if isinstance(exc, anthropic.APITimeoutError):
        return ScoutError(
            ErrorCode.REPORT_FAILED,
            "The request to Claude timed out.",
            hint="Try again. If it keeps timing out, raise SCOUT_CLAUDE_TIMEOUT_S in .env.",
            retryable=True,
            detail=detail,
        )
    if isinstance(exc, anthropic.APIConnectionError):
        return ScoutError(
            ErrorCode.REPORT_FAILED,
            "Could not reach the Anthropic API.",
            hint="Check the server's internet connection and try again.",
            retryable=True,
            detail=detail,
        )
    message = f"The Anthropic API returned an error: {_api_message(exc)}"
    return ScoutError(ErrorCode.REPORT_FAILED, message, detail=detail)


def _call_claude(client: Any, request: dict[str, Any]) -> Any:
    try:
        return _stream_with_fallback_retry(client, request)
    except anthropic.APIError as exc:
        raise _scout_error(exc, request["model"]) from exc


def _report_text(final: Any) -> str:
    """The report JSON: the first text block.

    After a mid-stream server-side fallback the fallback model continues the partial
    answer in a later text block, so in that case the text blocks are joined.
    """
    blocks = list(getattr(final, "content", None) or [])
    texts = [block.text for block in blocks if getattr(block, "type", None) == "text"]
    if not texts:
        raise ScoutError(ErrorCode.REPORT_FAILED, "Claude returned no report text.")
    if any(getattr(block, "type", None) == "fallback" for block in blocks):
        return "".join(texts)
    return texts[0]


def _parse_report(final: Any, settings: Settings) -> ScoutingReport:
    """Check why generation stopped BEFORE reading content, then validate the JSON."""
    stop_reason = getattr(final, "stop_reason", None)
    if stop_reason == "refusal":
        category = getattr(getattr(final, "stop_details", None), "category", None)
        reason = f" (safety category: {category})" if category else ""
        raise ScoutError(ErrorCode.REPORT_REFUSED, f"Claude declined to write this report{reason}.")
    if stop_reason == "max_tokens":
        raise ScoutError(
            ErrorCode.REPORT_TRUNCATED,
            f"The report hit the output limit of {settings.claude_max_tokens} tokens before it finished.",
        )
    try:
        return ScoutingReport.model_validate_json(_report_text(final))
    except ValidationError as exc:
        message = "Claude's answer did not match the report format."
        raise ScoutError(ErrorCode.REPORT_FAILED, message, detail=str(exc)[:2000]) from exc


def _usage(final: Any) -> dict[str, int]:
    usage = getattr(final, "usage", None)
    return {name: int(getattr(usage, name, None) or 0) for name in _USAGE_FIELDS}


def _make_client(settings: Settings) -> anthropic.Anthropic:
    if not settings.anthropic_api_key:
        raise ScoutError(ErrorCode.REPORT_NOT_CONFIGURED)
    return anthropic.Anthropic(api_key=settings.anthropic_api_key, timeout=settings.claude_timeout_s, max_retries=3)


def _clean_focus(coach_focus: str | None) -> str | None:
    focus = (coach_focus or "").strip()[:_MAX_FOCUS_CHARS]
    return focus or None


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
    settings = settings or get_settings()
    if client is None:
        client = _make_client(settings)
    focus = _clean_focus(coach_focus)
    payload_json = _payload_json(build_report_payload(analysis, game, rosters))
    request = _build_request(settings, payload_json, build_user_prompt(payload_json, focus))
    logger.info(
        "Requesting a Claude scouting report for game %s (model %s, effort %s, ~%d payload tokens).",
        game.id,
        settings.claude_model,
        settings.claude_effort,
        int(len(payload_json) / _CHARS_PER_TOKEN),
    )
    final = _call_claude(client, request)
    report = _parse_report(final, settings)
    model = getattr(final, "model", None) or settings.claude_model  # a fallback model may have answered
    stop_reason = getattr(final, "stop_reason", None)
    usage = _usage(final)
    logger.info("Claude report for game %s finished: model %s, stop %s, usage %s.", game.id, model, stop_reason, usage)
    return ReportRecord(
        game_id=game.id,
        model=model,
        coach_focus=focus,
        report=report,
        markdown=report_to_markdown(report, game, model=model),
        usage=usage,
        stop_reason=stop_reason,
    )
