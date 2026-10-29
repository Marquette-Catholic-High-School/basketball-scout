"""Tests for the Claude scouting report: payload, request shape, error mapping, rendering.

No network: a fake client stands in for ``anthropic.Anthropic`` and returns real SDK
``BetaMessage`` objects; errors are real ``anthropic`` exception instances built on
``httpx2`` requests/responses (what anthropic 2.x uses).
"""

from __future__ import annotations

import inspect
import json
import logging
import re
from datetime import date
from typing import Any

import anthropic
import httpx2
import pytest
from anthropic.types.beta import BetaMessage

from scout.errors import ErrorCode, ScoutError
from scout.reporting import claude_report, render
from scout.reporting.prompts import REPORT_SCHEMA, SYSTEM_PROMPT, build_user_prompt
from scout.reporting.render import report_to_markdown
from scout.schemas import Game, ScoutingReport, TeamSide
from tests.test_export_fastscout import make_analysis, make_roster

SAMPLE_REPORT: dict[str, Any] = {
    "headline": "Opponent HS lives on #3 J.R. Smith's pick-and-roll.",
    "executive_summary": "They ran 14 pick-and-rolls for 0.93 PPP.\n\nThey mostly play man and switch to a 2-3 zone.",
    "offensive_identity": ["Ran 14 pick-and-rolls (22.6% of possessions) for 0.93 PPP."],
    "defensive_identity": ["Man-to-man on 20 possessions, 0.90 PPP allowed."],
    "key_players": [
        {
            "jersey": "#3",
            "name": "J.R. Smith",
            "role": "Primary ball handler",
            "threat_level": "high",
            "strengths": ["5-11 FG", "4 AST"],
            "weaknesses": ["3 TO"],
            "how_to_defend": "Ice the ball screen | force him left.",
        }
    ],
    "play_tendencies": [
        {
            "play_type": "Pick & Roll",
            "frequency": "14 times, 23% of possessions",
            "effectiveness": "0.93 PPP",
            "counter": "Ice it.",
        }
    ],
    "transition": ["5 fast-break points on 2 possessions (small sample)."],
    "special_situations": [],
    "keys_to_win": ["Keep #3 out of the middle.", "Win the offensive glass."],
    "defensive_game_plan": ["# Ice side ball screens."],
    "offensive_game_plan": ["Attack the 2-3 zone from the high post."],
    "practice_emphasis": ["Scout team runs side pick-and-roll."],
    "data_caveats": ["One film only; jersey match rate 75%."],
}
REPORT_JSON = json.dumps(SAMPLE_REPORT)
REQUEST = httpx2.Request("POST", "https://api.anthropic.com/v1/messages")
USAGE = {
    "input_tokens": 1500,
    "output_tokens": 2200,
    "cache_read_input_tokens": None,
    "cache_creation_input_tokens": 4100,
}


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------


class MidStream:
    """Outcome that fails while the stream is being read (an SSE error event)."""

    def __init__(self, exc: Exception) -> None:
        self.exc = exc


class FakeStream:
    def __init__(self, outcome: Any) -> None:
        self.outcome = outcome

    def __enter__(self) -> FakeStream:
        if isinstance(self.outcome, Exception):  # the SDK sends the request in __enter__
            raise self.outcome
        return self

    def __exit__(self, *exc_info: object) -> None:
        return None

    def get_final_message(self) -> Any:
        if isinstance(self.outcome, MidStream):
            raise self.outcome.exc
        return self.outcome


class FakeMessages:
    def __init__(self, outcomes: list[Any]) -> None:
        self.outcomes = outcomes
        self.calls: list[dict[str, Any]] = []

    def stream(self, **kwargs: Any) -> FakeStream:
        self.calls.append(kwargs)
        return FakeStream(self.outcomes.pop(0))


class FakeClient:
    """Mimics ``client.beta.messages.stream(...)`` and records the keyword arguments."""

    def __init__(self, *outcomes: Any) -> None:
        self.messages = FakeMessages(list(outcomes))
        self.beta = self

    @property
    def calls(self) -> list[dict[str, Any]]:
        return self.messages.calls


def make_message(
    text: str | None = REPORT_JSON,
    *,
    stop_reason: str = "end_turn",
    model: str = "claude-opus-5-5",
    stop_details: dict[str, Any] | None = None,
    content: list[dict[str, Any]] | None = None,
) -> BetaMessage:
    if content is None:
        content = [{"type": "thinking", "thinking": "", "signature": "sig"}]
        if text is not None:
            content.append({"type": "text", "text": text})
    return BetaMessage.model_validate(
        {
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": content,
            "stop_reason": stop_reason,
            "stop_details": stop_details,
            "usage": USAGE,
        }
    )


def status_error(
    cls: type[anthropic.APIStatusError],
    status: int,
    error_type: str,
    message: str = "boom",
    headers: dict[str, str] | None = None,
) -> anthropic.APIStatusError:
    response = httpx2.Response(status, headers={"request-id": "req_123", **(headers or {})}, request=REQUEST)
    body = {"type": "error", "error": {"type": error_type, "message": message}}
    return cls(f"Error code: {status} - {body}", response=response, body=body)


def bad_request(message: str) -> anthropic.APIStatusError:
    return status_error(anthropic.BadRequestError, 400, "invalid_request_error", message)


def overloaded() -> anthropic.APIStatusError:
    return status_error(anthropic.OverloadedError, 529, "overloaded_error")


@pytest.fixture
def analysis():
    return make_analysis()


@pytest.fixture
def rosters(game):
    return {TeamSide.SCOUTED: make_roster(game.id)}


def _generate(analysis, game, rosters, settings, *outcomes, **kwargs):
    client = FakeClient(*outcomes)
    record = claude_report.generate_report(analysis, game, rosters, settings=settings, client=client, **kwargs)
    return record, client


def _error(analysis, game, rosters, settings, *outcomes) -> ScoutError:
    with pytest.raises(ScoutError) as err:
        _generate(analysis, game, rosters, settings, *outcomes)
    return err.value


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------


def _shape_from_pydantic(schema: dict[str, Any], defs: dict[str, Any]) -> dict[str, Any]:
    if "$ref" in schema:
        return _shape_from_pydantic(defs[schema["$ref"].split("/")[-1]], defs)
    if "enum" in schema:
        return {"type": schema.get("type", "string"), "enum": schema["enum"]}
    if schema["type"] == "object":
        props = {name: _shape_from_pydantic(sub, defs) for name, sub in schema["properties"].items()}
        return {"type": "object", "properties": props, "required": sorted(schema.get("required", []))}
    if schema["type"] == "array":
        return {"type": "array", "items": _shape_from_pydantic(schema["items"], defs)}
    return {"type": schema["type"]}


def _shape_from_ours(schema: dict[str, Any]) -> dict[str, Any]:
    if "enum" in schema:
        return {"type": schema["type"], "enum": schema["enum"]}
    if schema["type"] == "object":
        props = {name: _shape_from_ours(sub) for name, sub in schema["properties"].items()}
        return {"type": "object", "properties": props, "required": sorted(schema["required"])}
    if schema["type"] == "array":
        return {"type": "array", "items": _shape_from_ours(schema["items"])}
    return {"type": schema["type"]}


def test_report_schema_matches_pydantic_model():
    pydantic_schema = ScoutingReport.model_json_schema()
    expected = _shape_from_pydantic(pydantic_schema, pydantic_schema.get("$defs", {}))
    assert _shape_from_ours(REPORT_SCHEMA) == expected


def _walk(schema: dict[str, Any]):
    yield schema
    for sub in schema.get("properties", {}).values():
        yield from _walk(sub)
    if "items" in schema:
        yield from _walk(schema["items"])


def test_report_schema_is_strict_compatible():
    allowed_keys = {"type", "properties", "required", "additionalProperties", "items", "enum", "description"}
    for node in _walk(REPORT_SCHEMA):
        assert set(node) <= allowed_keys, set(node) - allowed_keys
        assert node["type"] in {"string", "array", "object"}
        if node["type"] == "object":
            assert node["additionalProperties"] is False
            assert node["required"] == list(node["properties"])


def test_sample_report_is_valid():
    assert ScoutingReport.model_validate_json(REPORT_JSON).key_players[0].threat_level == "high"


# ---------------------------------------------------------------------------
# Payload
# ---------------------------------------------------------------------------


def _floats(value: Any):
    if isinstance(value, float):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _floats(item)
    elif isinstance(value, list):
        for item in value:
            yield from _floats(item)


def test_payload_box_scores(analysis, game, rosters):
    payload = claude_report.build_report_payload(analysis, game, rosters)
    assert payload["game"]["final_score"] == {"scouted": 27, "other": 20}
    assert payload["game"]["film_minutes"] == 32.0 and payload["game"]["periods_seen"] == 1
    team = payload["scouted_team"]
    assert [p["jersey"] for p in team["players"]] == ["0", "3", "10", "23"]  # #5 did not play
    jr = team["players"][1]
    assert jr["name"] == "J.R. Smith" and jr["pos"] == "G" and jr["height"] == "6-1" and jr["grade"] == "Sr"
    assert jr["fg"] == "5-11" and jr["fg_pct"] == 45.5 and jr["min"] == 22
    assert jr["zones"] == {"paint": "2-4", "mid": "1-2", "three": "2-5"}
    assert team["players"][3]["name"] == "Unknown"
    assert team["totals"]["pts"] == 27 and team["unattributed"]["pts"] == 2 and team["ppp"] == 0.87
    assert "min" not in team["totals"] and "min" not in payload["other_team"]["totals"]
    assert team["shot_zones"]["paint"] == {"fg": "5-9", "fg_pct": 55.6, "share_pct": 37.5}
    assert team["shot_locations"] == {
        "restricted_area": "2-2",
        "left_corner_3": "1-1",
        "top_3": "1-1",
        "top_mid": "0-1",
    }
    assert payload["other_team"]["totals"]["pts"] == 20
    for number in _floats(payload):
        assert round(number, 2) == number


def test_payload_plays_tendencies_and_quality(analysis, game, rosters):
    payload = claude_report.build_report_payload(analysis, game, rosters)
    play_types = payload["scouted_offense"]["play_types"]
    assert [p["type"] for p in play_types] == ["pick_and_roll", "isolation", "fast_break"]
    assert play_types[0]["poss_pct"] == 22.6
    defense = payload["scouted_defense"]
    assert defense["zone_shapes"] == {"1-3-1": 1, "2-3": 2} and defense["defensive_possessions"] == 3
    assert [look["type"] for look in defense["looks"]] == ["man_defense", "zone_defense"]
    assert payload["transition"]["scouted"] == {
        "possessions": 2,
        "share_pct": 40.0,
        "points": 5,
        "ppp": 2.5,
        "numbers": {"3v2": 1},
    }
    roles = payload["tendencies"]["play_roles"]
    assert roles["pick_and_roll"]["ball_handler"] == [{"player": "#3 J.R. Smith", "plays": 1, "points": 3}]
    assert roles["fast_break"]["ball_handler"][0]["player"] == "#10 José Núñez"
    assert "isolation" not in roles  # the other team's isolation is not a scouted tendency
    assert payload["tendencies"]["free_throws"] == [{"player": "#10 José Núñez", "ft": "2-2", "ft_pct": 100.0}]
    assert payload["turnovers"]["committed"] == {"total": 4, "stolen": 1, "by_type": {"Turnover (Travel)": 1}}
    assert payload["scoring_runs"] == [{"team": "Opponent HS", "run": "8-0", "from": "01:10", "to": "02:30"}]
    assert payload["play_log"][0] == {
        "t": "00:12",
        "play": "Fast Break",
        "players": "ball_handler #3 J.R. Smith",
        "result": "made_fg",
        "pts": 3,
    }
    quality = payload["data_quality"]
    assert quality["jersey_match_rate_pct"] == 75.0 and quality["ball_coverage_pct"] == 82.3
    assert quality["warnings"] == ["OCR_SPARSE: Few jersey numbers were readable."]
    assert quality["unattributed_points"] == 2 and quality["shots_without_location"] == 1
    assert "omitted_sections" not in payload


def test_payload_is_deterministic(analysis, game, rosters):
    first = claude_report._payload_json(claude_report.build_report_payload(analysis, game, rosters))
    second = claude_report._payload_json(claude_report.build_report_payload(make_analysis(), game, rosters))
    assert first == second
    assert '"generated_at"' not in first  # re-analysis timestamps must not break the prompt cache


def test_payload_trimming_never_drops_box_scores(analysis, game, rosters):
    payload = claude_report.build_report_payload(analysis, game, rosters, token_budget=50)
    assert payload["omitted_sections"] == ["play_log", "scoring_runs", "tendencies", "turnovers"]
    assert len(payload["scouted_team"]["players"]) == 4 and payload["other_team"]["totals"]["pts"] == 20
    assert "data_quality" in payload and "scouted_offense" in payload


def test_payload_without_roster_uses_analysis_names(analysis, game):
    payload = claude_report.build_report_payload(analysis, game, {})
    assert payload["scouted_team"]["players"][2]["name"] == "José Núñez"
    assert "pos" not in payload["scouted_team"]["players"][2]


# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------


def test_system_prompt_is_constant_and_covers_the_brief():
    assert not re.search(r"\b20\d\d\b|\d{4}-\d{2}-\d{2}", SYSTEM_PROMPT)  # no dates: keeps the cache warm
    for phrase in ("jersey number and name", "small", "approximate", "minors", "appearance", "derogatory", "schema"):
        assert phrase in SYSTEM_PROMPT


def test_user_prompt_with_focus_and_omitted_sections():
    game = {"scouted_team": "Opponent HS", "other_team": "Rival HS"}
    text = build_user_prompt(json.dumps({"game": game, "omitted_sections": ["play_log"]}), "We play a 2-3 zone.")
    assert "Write the scouting report on Opponent HS" in text and "playing Rival HS" in text
    assert "<coach_focus>\nWe play a 2-3 zone.\n</coach_focus>" in text
    assert "left out: play_log." in text and "scouted_offense.play_types" in text
    assert "<coach_focus>" not in build_user_prompt(json.dumps({"game": {}}), None)


# ---------------------------------------------------------------------------
# Request shape and result
# ---------------------------------------------------------------------------


def test_generate_report_request(analysis, game, rosters, settings):
    _, client = _generate(analysis, game, rosters, settings, make_message(), coach_focus="  We play a 2-3 zone.  ")
    (kwargs,) = client.calls
    assert kwargs["model"] == "claude-opus-5-5"
    assert kwargs["max_tokens"] == settings.claude_max_tokens
    assert kwargs["thinking"] == {"type": "adaptive"}
    assert not {"temperature", "top_p", "top_k"} & set(kwargs)
    assert kwargs["output_config"] == {"effort": "high", "format": {"type": "json_schema", "schema": REPORT_SCHEMA}}
    assert kwargs["system"] == [{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}]
    assert kwargs["betas"] == ["server-side-fallback-2026-07-01"] and kwargs["fallbacks"] == "default"
    (message,) = kwargs["messages"]  # one user turn: no assistant prefill
    assert message["role"] == "user"
    data_block, task_block = message["content"]
    payload = claude_report.build_report_payload(analysis, game, rosters)
    assert data_block == {
        "type": "text",
        "text": json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False),
        "cache_control": {"type": "ephemeral"},
    }
    assert "cache_control" not in task_block
    assert "<coach_focus>\nWe play a 2-3 zone.\n</coach_focus>" in task_block["text"]


def test_generate_report_record(analysis, game, rosters, settings):
    record, _ = _generate(analysis, game, rosters, settings, make_message(), coach_focus="  We play a 2-3 zone.  ")
    assert record.game_id == game.id and record.model == "claude-opus-5-5" and record.stop_reason == "end_turn"
    assert record.coach_focus == "We play a 2-3 zone."
    assert record.report == ScoutingReport.model_validate(SAMPLE_REPORT)
    assert record.usage == {**USAGE, "cache_read_input_tokens": 0}  # missing -> 0, all ints
    assert record.markdown.startswith("# Scouting Report: Opponent HS")
    assert "_Generated by claude-opus-5-5 from video analysis - verify against film._" in record.markdown


def test_request_kwargs_fit_the_sdk_signature(analysis, game, rosters, settings):
    _, client = _generate(analysis, game, rosters, settings, make_message())
    stream = anthropic.Anthropic(api_key="test-key").beta.messages.stream
    inspect.signature(stream).bind(**client.calls[0])  # raises TypeError on an unknown keyword


def test_fallbacks_can_be_turned_off(analysis, game, rosters, settings):
    changes = {"claude_fallbacks": False, "claude_effort": "max", "claude_model": "claude-opus-5"}
    _, client = _generate(analysis, game, rosters, settings.model_copy(update=changes), make_message())
    kwargs = client.calls[0]
    assert "betas" not in kwargs and "fallbacks" not in kwargs
    assert kwargs["model"] == "claude-opus-5" and kwargs["output_config"]["effort"] == "max"


def test_coach_focus_does_not_change_the_cached_blocks(analysis, game, rosters, settings):
    _, first = _generate(analysis, game, rosters, settings, make_message(), coach_focus="Their press")
    _, second = _generate(analysis, game, rosters, settings, make_message(), coach_focus="Their shooters")
    a, b = first.calls[0], second.calls[0]
    assert a["system"] == b["system"]
    assert a["messages"][0]["content"][0] == b["messages"][0]["content"][0]
    assert a["messages"][0]["content"][1] != b["messages"][0]["content"][1]


def test_report_served_by_fallback_model_after_mid_stream_switch(analysis, game, rosters, settings):
    half = len(REPORT_JSON) // 2
    switch = {"type": "fallback", "from": {"model": "claude-opus-5-5"}, "to": {"model": "claude-opus-5"}}
    content = [
        {"type": "thinking", "thinking": "", "signature": "sig"},
        {"type": "text", "text": REPORT_JSON[:half]},
        {**switch, "trigger": {"type": "refusal"}},
        {"type": "text", "text": REPORT_JSON[half:]},
    ]
    record, _ = _generate(analysis, game, rosters, settings, make_message(content=content, model="claude-opus-5"))
    assert record.model == "claude-opus-5"
    assert record.report.headline == SAMPLE_REPORT["headline"]


# ---------------------------------------------------------------------------
# Client construction / configuration
# ---------------------------------------------------------------------------


def test_missing_api_key_fails_before_any_call(analysis, game, rosters, settings, monkeypatch):
    def forbidden(*args: Any, **kwargs: Any) -> None:
        raise AssertionError("no client may be created without a key")

    monkeypatch.setattr(claude_report.anthropic, "Anthropic", forbidden)
    with pytest.raises(ScoutError) as err:
        claude_report.generate_report(analysis, game, rosters, settings=settings)
    assert err.value.code == ErrorCode.REPORT_NOT_CONFIGURED


def test_client_is_built_from_settings_and_key_is_never_logged(analysis, game, rosters, settings, monkeypatch, caplog):
    secret = "sk-ant-test-SECRET-123"
    settings = settings.model_copy(update={"anthropic_api_key": secret})
    created: dict[str, Any] = {}
    fake = FakeClient(make_message())

    def factory(**kwargs: Any) -> FakeClient:
        created.update(kwargs)
        return fake

    monkeypatch.setattr(claude_report.anthropic, "Anthropic", factory)
    with caplog.at_level(logging.DEBUG):
        record = claude_report.generate_report(analysis, game, rosters, settings=settings)
    assert created == {"api_key": secret, "timeout": settings.claude_timeout_s, "max_retries": 3}
    assert record.report.headline == SAMPLE_REPORT["headline"]
    assert secret not in caplog.text and secret not in json.dumps(fake.calls, ensure_ascii=False)


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


ERROR_CASES = [
    (status_error(anthropic.AuthenticationError, 401, "authentication_error"), ErrorCode.REPORT_AUTH_FAILED, None),
    (status_error(anthropic.PermissionDeniedError, 403, "permission_error"), ErrorCode.REPORT_AUTH_FAILED, None),
    (
        status_error(anthropic.NotFoundError, 404, "not_found_error", "model: claude-opus-5-5"),
        ErrorCode.REPORT_FAILED,
        "SCOUT_CLAUDE_MODEL",
    ),
    (
        status_error(anthropic.RateLimitError, 429, "rate_limit_error", headers={"retry-after": "30"}),
        ErrorCode.REPORT_RATE_LIMITED,
        "wait 30 seconds",
    ),
    (overloaded(), ErrorCode.REPORT_OVERLOADED, None),
    (status_error(anthropic.ServiceUnavailableError, 503, "api_error"), ErrorCode.REPORT_OVERLOADED, None),
    (status_error(anthropic.InternalServerError, 500, "api_error"), ErrorCode.REPORT_OVERLOADED, None),
    (status_error(anthropic.APIStatusError, 502, "api_error"), ErrorCode.REPORT_OVERLOADED, None),
    (bad_request("max_tokens: 999999 > 128000"), ErrorCode.REPORT_FAILED, "max_tokens: 999999 > 128000"),
    (
        status_error(anthropic.UnprocessableEntityError, 422, "invalid_request_error", "odd"),
        ErrorCode.REPORT_FAILED,
        "odd",
    ),
    (anthropic.APITimeoutError(request=REQUEST), ErrorCode.REPORT_FAILED, "timed out"),
    (anthropic.APIConnectionError(request=REQUEST), ErrorCode.REPORT_FAILED, "Could not reach"),
]


def _case_id(value: Any) -> str | None:
    return type(value).__name__ if isinstance(value, Exception) else None


@pytest.mark.parametrize(("exc", "code", "text"), ERROR_CASES, ids=_case_id)
def test_error_mapping(analysis, game, rosters, settings, exc, code, text):
    error = _error(analysis, game, rosters, settings, exc)
    assert error.code == code
    if text:
        assert text in error.message
    assert error.__cause__ is exc


def test_error_retryability(analysis, game, rosters, settings):
    def raised(exc: Exception) -> ScoutError:
        return _error(analysis, game, rosters, settings, exc)

    assert raised(anthropic.APITimeoutError(request=REQUEST)).retryable
    assert raised(anthropic.APIConnectionError(request=REQUEST)).retryable
    assert raised(status_error(anthropic.RateLimitError, 429, "rate_limit_error")).retryable
    assert "wait" not in raised(status_error(anthropic.RateLimitError, 429, "rate_limit_error")).message
    assert not raised(bad_request("bad")).retryable
    assert not raised(status_error(anthropic.NotFoundError, 404, "not_found_error")).retryable
    assert "req_123" in raised(overloaded()).detail


@pytest.mark.parametrize(
    ("error_type", "code"),
    [("overloaded_error", ErrorCode.REPORT_OVERLOADED), ("rate_limit_error", ErrorCode.REPORT_RATE_LIMITED)],
)
def test_mid_stream_error_events_are_mapped(analysis, game, rosters, settings, error_type, code):
    # An SSE "error" event arrives on an HTTP 200 stream, so the SDK raises a plain APIStatusError.
    mid_stream = MidStream(status_error(anthropic.APIStatusError, 200, error_type))
    assert _error(analysis, game, rosters, settings, mid_stream).code == code


def test_refusal(analysis, game, rosters, settings):
    refusal = {"type": "refusal", "category": "cyber", "explanation": "Declined."}
    error = _error(analysis, game, rosters, settings, make_message(None, stop_reason="refusal", stop_details=refusal))
    assert error.code == ErrorCode.REPORT_REFUSED and "cyber" in error.message
    error = _error(analysis, game, rosters, settings, make_message(None, stop_reason="refusal"))
    assert error.code == ErrorCode.REPORT_REFUSED and "category" not in error.message


def test_max_tokens_is_truncated_even_with_text(analysis, game, rosters, settings):
    error = _error(analysis, game, rosters, settings, make_message(REPORT_JSON[:200], stop_reason="max_tokens"))
    assert error.code == ErrorCode.REPORT_TRUNCATED and "32000" in error.message


@pytest.mark.parametrize(
    ("message", "text"),
    [(make_message("not json"), "did not match"), (make_message(None), "no report text")],
)
def test_unusable_answers(analysis, game, rosters, settings, message, text):
    error = _error(analysis, game, rosters, settings, message)
    assert error.code == ErrorCode.REPORT_FAILED and text in error.message


def test_fallback_rejection_is_retried_once_without_it(analysis, game, rosters, settings, caplog):
    rejected = bad_request("fallbacks: Extra inputs are not permitted")
    with caplog.at_level(logging.WARNING, logger="scout.reporting.claude_report"):
        record, client = _generate(analysis, game, rosters, settings, rejected, make_message())
    first, second = client.calls
    assert first["fallbacks"] == "default" and first["betas"] == [claude_report.FALLBACK_BETA]
    assert "fallbacks" not in second and "betas" not in second
    assert {k: v for k, v in first.items() if k not in ("betas", "fallbacks")} == second
    assert record.report.headline == SAMPLE_REPORT["headline"]
    assert "retrying without it" in caplog.text


def test_other_bad_requests_are_not_retried(analysis, game, rosters, settings):
    client = FakeClient(bad_request("messages: bad"), make_message())
    with pytest.raises(ScoutError) as err:
        claude_report.generate_report(analysis, game, rosters, settings=settings, client=client)
    assert err.value.code == ErrorCode.REPORT_FAILED and len(client.calls) == 1


def test_fallback_rejection_without_fallbacks_enabled_is_not_retried(analysis, game, rosters, settings):
    settings = settings.model_copy(update={"claude_fallbacks": False})
    client = FakeClient(bad_request("fallback model unavailable"), make_message())
    with pytest.raises(ScoutError):
        claude_report.generate_report(analysis, game, rosters, settings=settings, client=client)
    assert len(client.calls) == 1


def test_failed_retry_is_mapped(analysis, game, rosters, settings):
    error = _error(analysis, game, rosters, settings, bad_request("unexpected `fallbacks`"), overloaded())
    assert error.code == ErrorCode.REPORT_OVERLOADED


# ---------------------------------------------------------------------------
# Through the real SDK (in-process mock transport, no network)
# ---------------------------------------------------------------------------


def _sse_response(text: str) -> httpx2.Response:
    """A streamed Messages API answer: one (empty) thinking block, then the text in two deltas."""
    usage = {"input_tokens": 900, "output_tokens": 1, "cache_read_input_tokens": 4100, "cache_creation_input_tokens": 0}
    start = {
        "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [],
        "stop_reason": None, "stop_sequence": None, "usage": usage,
    }  # fmt: skip
    thinking = {"type": "thinking", "thinking": "", "signature": ""}
    end = {"stop_reason": "end_turn", "stop_sequence": None}
    events = [
        {"type": "message_start", "message": start},
        {"type": "content_block_start", "index": 0, "content_block": thinking},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "sig"}},
        {"type": "content_block_stop", "index": 0},
        {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": text[:40]}},
        {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": text[40:]}},
        {"type": "content_block_stop", "index": 1},
        {"type": "message_delta", "delta": end, "usage": {"output_tokens": 2100}},
        {"type": "message_stop"},
    ]
    body = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events)
    return httpx2.Response(200, headers={"content-type": "text/event-stream"}, content=body.encode())


def _sdk_client(*responses: httpx2.Response) -> tuple[anthropic.Anthropic, list[httpx2.Request]]:
    sent: list[httpx2.Request] = []
    queue = list(responses)

    def handler(request: httpx2.Request) -> httpx2.Response:
        sent.append(request)
        return queue.pop(0)

    http_client = anthropic.DefaultHttpxClient(transport=httpx2.MockTransport(handler))
    return anthropic.Anthropic(api_key="test-key", max_retries=0, http_client=http_client), sent


def test_end_to_end_through_the_sdk(analysis, game, rosters, settings):
    client, sent = _sdk_client(_sse_response(REPORT_JSON))
    record = claude_report.generate_report(analysis, game, rosters, settings=settings, client=client)
    (request,) = sent
    body = json.loads(request.content)
    assert request.headers["anthropic-version"] == "2026-10-21"
    assert request.headers["anthropic-beta"] == "server-side-fallback-2026-07-01"
    assert body["fallbacks"] == "default" and body["stream"] is True
    assert body["thinking"] == {"type": "adaptive"} and not {"temperature", "top_p", "top_k"} & set(body)
    assert body["output_config"] == {"effort": "high", "format": {"type": "json_schema", "schema": REPORT_SCHEMA}}
    assert body["system"][0]["cache_control"] == {"type": "ephemeral"}
    assert body["messages"][0]["content"][0]["cache_control"] == {"type": "ephemeral"}
    assert record.report == ScoutingReport.model_validate(SAMPLE_REPORT)
    assert record.usage == {
        "input_tokens": 900,
        "output_tokens": 2100,
        "cache_read_input_tokens": 4100,
        "cache_creation_input_tokens": 0,
    }


def test_fallback_retry_through_the_sdk(analysis, game, rosters, settings):
    error_body = {"type": "error", "error": {"type": "invalid_request_error", "message": "fallbacks: not available"}}
    rejected = httpx2.Response(400, json=error_body, headers={"request-id": "req_9"})
    client, sent = _sdk_client(rejected, _sse_response(REPORT_JSON))
    record = claude_report.generate_report(analysis, game, rosters, settings=settings, client=client)
    first, second = (json.loads(request.content) for request in sent)
    assert first["fallbacks"] == "default" and "fallbacks" not in second
    assert "anthropic-beta" in sent[0].headers and "anthropic-beta" not in sent[1].headers
    assert record.report.headline == SAMPLE_REPORT["headline"]


# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------


def test_report_to_markdown():
    game = Game(
        scouted_team="Opponent HS",
        other_team="Rival HS",
        game_date=date(2026, 1, 16),
        level="Varsity",
        location="Rival Gym",
    )
    markdown = report_to_markdown(ScoutingReport.model_validate(SAMPLE_REPORT), game, model="claude-opus-5-5")
    lines = markdown.splitlines()
    assert lines[0] == "# Scouting Report: Opponent HS"
    assert lines[2] == "**Film:** Opponent HS vs Rival HS · January 16, 2026 · Varsity · Rival Gym"
    assert "> **Opponent HS lives on #3 J.R. Smith's pick-and-roll.**" in lines
    assert "They ran 14 pick-and-rolls for 0.93 PPP.\n\nThey mostly play man" in markdown
    assert "## Keys to Win\n\n1. Keep #3 out of the middle.\n2. Win the offensive glass." in markdown
    assert "| # | Player | Role | Threat | Strengths | Weaknesses | How to defend |" in lines
    row = (
        "| 3 | J.R. Smith | Primary ball handler | High | 5-11 FG; 4 AST | 3 TO "
        "| Ice the ball screen \\| force him left. |"
    )
    assert row in lines
    assert "| Pick & Roll | 14 times, 23% of possessions | 0.93 PPP | Ice it. |" in lines
    assert "- \\# Ice side ball screens." in lines  # a leading "# " would otherwise become a heading
    assert "## Special Situations" not in markdown  # empty sections are left out
    assert markdown.index("## Keys to Win") < markdown.index("## Key Players") < markdown.index("## Data Caveats")
    assert lines[-1] == "_Generated by claude-opus-5-5 from video analysis - verify against film._"


@pytest.mark.parametrize(
    ("text", "safe"),
    [
        ("# Ice it", "\\# Ice it"),
        ("## Twice", "\\## Twice"),
        ("> quote", "\\> quote"),
        ("- dash", "\\- dash"),
        ("3. Third", "3\\. Third"),
        ("2) Second", "2\\) Second"),
        ("#23 drives\nleft", "#23 drives left"),
        ("0.93 PPP", "0.93 PPP"),
    ],
)
def test_markdown_escapes_block_markers(text, safe):
    assert render._inline(text) == safe


def test_markdown_minimal_game_and_default_model():
    empty = {"key_players": [], "play_tendencies": [], "keys_to_win": [], "data_caveats": ["   "]}
    report = ScoutingReport.model_validate({**SAMPLE_REPORT, **empty})
    markdown = report_to_markdown(report, Game(scouted_team="Opponent HS"))
    assert "**Film:** Opponent HS\n" in markdown
    for heading in ("## Key Players", "## Play Tendencies", "## Keys to Win", "## Data Caveats"):
        assert heading not in markdown
    assert markdown.endswith("_Generated by Claude from video analysis - verify against film._\n")
