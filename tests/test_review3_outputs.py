"""Regression tests from the third review round of the outputs area: long file names taken
from video links (cut on the server, shortened again on the GPU, where the download's
``.part`` name was too long), report errors that come from a proxy or web filter instead of
the Anthropic API, the free-throw warning texts and the FastScout notes built on them, and
VIDEO_TOO_LONG messages that printed two equal durations.
"""

from __future__ import annotations

import io
import json
from pathlib import Path
from typing import Any

import anthropic
import httpx2
import pytest
from fastapi.testclient import TestClient

from modal_app import app as app_module
from modal_app.pipeline import errors, runner, video
from modal_app.pipeline import events as extra_events
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.video import VideoProbe
from scout import db
from scout.analysis import pipeline
from scout.api import uploads
from scout.errors import ErrorCode, ScoutError
from scout.export import fastscout
from scout.reporting import claude_report
from scout.schemas import PipelineWarning, TeamSide
from tests import helpers
from tests.test_api_support import fake_mp4, make_app
from tests.test_api_uploads import upload_all
from tests.test_export_fastscout import make_analysis, make_roster
from tests.test_modal_events import ev, free_throw_trip
from tests.test_reporting import _sdk_client

S = TeamSide.SCOUTED


@pytest.fixture
def client(auth_headers, monkeypatch):
    with TestClient(make_app(monkeypatch), headers=auth_headers) as c:
        yield c


# ---------------------------------------------------------------------------
# 3. Long file names from links
# ---------------------------------------------------------------------------


def _link_name(client: TestClient, game_id: str, url: str) -> str:
    r = client.post(f"/api/games/{game_id}/video-url", params={"auto_start": "false"}, json={"url": url})
    assert r.status_code == 200, r.text
    name = r.json()["game"]["video_filename"]
    assert db.get_game(game_id).video_filename == name
    return name


def test_a_long_name_from_a_link_is_cut_to_255_characters_keeping_its_extension(client, game):
    # A link may be 2000 characters long and its last segment became the film's name in full: a
    # name the coach types is capped at 255 (VideoUrlRequest.filename), this one was not.
    name = _link_name(client, game.id, "https://films.example.com/2026/" + "x" * 296 + ".mp4?sig=abc")
    assert len(name) == 255 and name == "x" * 251 + ".mp4"
    no_extension = _link_name(client, game.id, "https://films.example.com/" + "y" * 300)
    assert no_extension == "y" * 255
    odd = _link_name(client, game.id, "https://films.example.com/film." + "z" * 300)  # not an extension
    assert odd == ("film." + "z" * 300)[:255]


def test_a_link_name_is_counted_after_url_decoding(client, game):
    # 64 "%20" (192 characters in the link) are 64 spaces in the name: still under the limit.
    encoded = "vs%20" * 64 + "north.mp4"
    assert len(encoded) > 255
    assert _link_name(client, game.id, f"https://films.example.com/{encoded}") == "vs " * 64 + "north.mp4"
    long_decoded = "%41" * 300 + ".mov"  # "A" * 300 + ".mov"
    assert _link_name(client, game.id, f"https://films.example.com/{long_decoded}") == "A" * 251 + ".mov"


def test_a_link_without_a_file_name_or_a_typed_name_are_unchanged(client, game):
    assert _link_name(client, game.id, "https://films.example.com/films/") == "film.mp4"  # empty last segment
    assert _link_name(client, game.id, "https://films.example.com/%20%20/") == "film.mp4"
    r = client.post(
        f"/api/games/{game.id}/video-url",
        params={"auto_start": "false"},
        json={"url": "https://films.example.com/" + "x" * 300 + ".mp4", "filename": "Game 3.mp4"},
    )
    assert r.json()["game"]["video_filename"] == "Game 3.mp4"


def test_control_characters_decoded_from_a_link_do_not_reach_the_name(client, game):
    # "%0A" decoded into a line break, which went into the log lines that print the film's name.
    assert _link_name(client, game.id, "https://films.example.com/vs%0Acentral%09final%00.mp4") == (
        "vs central final .mp4"
    )


@pytest.mark.parametrize(
    ("name", "safe"),
    [
        ("x" * 296 + ".mp4", "x" * 96 + ".mp4"),
        ("../" + "Game 3 " * 40 + ".MOV", ("Game_3_" * 40)[:96] + ".MOV"),
        ("film." + "z" * 300, ("film." + "z" * 300)[:100]),  # not an extension: just cut
        ("Game 3 vs Central.mp4", "Game_3_vs_Central.mp4"),  # short names as before
        ("..", "film.mp4"),
    ],
    ids=["long", "folders-and-spaces", "no-extension", "short", "dots"],
)
def test_gpu_file_names_are_at_most_100_characters_and_keep_the_extension(name, safe):
    assert app_module._safe_name(name) == safe and len(safe) <= 100


class _Film(io.BytesIO):
    def __init__(self, body: bytes) -> None:
        super().__init__(body)
        self.headers = {"Content-Type": "video/mp4", "Content-Length": str(len(body))}


@pytest.fixture
def fake_link(monkeypatch):
    """urlopen answers every request with a small MP4; no sleeping between retries."""
    monkeypatch.setattr(video.urllib.request, "urlopen", lambda request, timeout=None: _Film(b"link film"))
    monkeypatch.setattr(video.time, "sleep", lambda seconds: None)


class _Volume:
    def reload(self) -> None:
        pass

    def commit(self) -> None:
        pass


def test_a_link_film_with_a_255_character_name_downloads_on_the_gpu(fake_link, monkeypatch, tmp_path):
    # The GPU downloads to "/data/tmp/<job>/<name>.part": a 251+ character name made that file name
    # longer than the 255 bytes a file system allows, and the job failed with "GPU worker error:
    # OSError: [Errno 36] File name too long".
    seen: list[dict[str, Any]] = []

    def fake_run_pipeline(video_path, options, *, output_dir, job_id, progress=None, filename=None):
        path = Path(video_path)
        seen.append({"name": path.name, "data": path.read_bytes(), "filename": filename})
        return {"status": "ok", "job_id": job_id, "tracking_path": f"results/{job_id}/tracking.json.gz", "warnings": []}

    monkeypatch.setattr(app_module, "run_pipeline", fake_run_pipeline)
    long_name = ("Central vs North " * 15)[:251] + ".mp4"  # as long as the server lets a name be
    assert len(long_name) == 255
    request = {
        "job_id": "j_long",
        "video": {"type": "url", "url": "https://cdn.example.org/film.mp4", "filename": long_name},
        "output_dir": "results/j_long",
        "options": {},
    }
    root = tmp_path / "volume"
    response = app_module.handle_request(request, volume=_Volume(), progress_store={}, root=root)
    assert response["status"] == "ok", response
    (run,) = seen
    assert run["data"] == b"link film" and len(run["name"]) <= 100 and run["name"].endswith(".mp4")
    assert run["filename"] == long_name  # the coach's name only travels as metadata
    assert not (root / "tmp" / "j_long").exists()


def test_an_uploaded_film_is_read_from_its_volume_path_as_it_is(monkeypatch, tmp_path):
    seen: list[str] = []

    def fake_run_pipeline(video_path, options, *, output_dir, job_id, progress=None, filename=None):
        seen.append(video_path)
        return {"status": "ok", "job_id": job_id, "warnings": []}

    monkeypatch.setattr(app_module, "run_pipeline", fake_run_pipeline)
    root = tmp_path / "volume"
    film = root / "uploads" / "j_up" / ("u" * 200 + ".mp4")
    film.parent.mkdir(parents=True)
    film.write_bytes(b"film")
    request = {"job_id": "j_up", "video": {"type": "volume", "path": f"uploads/j_up/{film.name}"}}
    response = app_module.handle_request(request, volume=_Volume(), progress_store={}, root=root)
    assert response["status"] == "ok" and seen == [str(film)]


# ---------------------------------------------------------------------------
# 4. Report errors from proxies
# ---------------------------------------------------------------------------


@pytest.fixture
def report_inputs(game):
    return make_analysis(), game, {S: make_roster(game.id)}


def _sdk_report_error(report_inputs, settings, response: httpx2.Response) -> ScoutError:
    client, _ = _sdk_client(response)
    analysis, game, rosters = report_inputs
    with pytest.raises(ScoutError) as err:
        claude_report.generate_report(analysis, game, rosters, settings=settings, client=client)
    return err.value


PROXY_PAGE = b"<!DOCTYPE html><html><head><title>Not Found</title></head><body><h1>Not Found</h1><hr>nginx</body></html>"


@pytest.mark.parametrize("status", [401, 404, 402, 429])
def test_a_proxys_own_error_page_is_not_a_rejected_key_or_an_unknown_model(report_inputs, settings, status):
    # A proxy or web filter answering 404 read "Model not found - check SCOUT_CLAUDE_MODEL", a 401
    # "The Anthropic API key was rejected": IT staff changed a model name or a key that were fine.
    page = httpx2.Response(status, headers={"content-type": "text/html; charset=utf-8"}, content=PROXY_PAGE)
    error = _sdk_report_error(report_inputs, settings, page)
    assert error.code == ErrorCode.REPORT_FAILED and error.retryable
    assert f"(HTTP {status})" in error.message and "web filter or proxy" in error.message
    assert error.hint == claude_report._FILTER_HINT
    assert "SCOUT_CLAUDE_MODEL" not in error.message and "rejected" not in error.message
    for text in (error.message, error.hint or "", error.detail or ""):
        assert "<" not in text and "nginx" not in text, text
    assert "text/html" in (error.detail or "")


def _api_error_response(status: int, error_type: str, message: str) -> httpx2.Response:
    body = {"type": "error", "error": {"type": error_type, "message": message}}
    return httpx2.Response(status, json=body, headers={"request-id": "req_77"})


def test_the_apis_own_404_still_names_the_model(report_inputs, settings):
    error = _sdk_report_error(report_inputs, settings, _api_error_response(404, "not_found_error", "model: claude-x"))
    assert error.code == ErrorCode.REPORT_FAILED and not error.retryable
    assert error.message.startswith("Model not found - check SCOUT_CLAUDE_MODEL")
    assert "model: claude-x" in (error.detail or "") and "req_77" in (error.detail or "")


def test_the_apis_own_401_is_still_a_rejected_key(report_inputs, settings):
    error = _sdk_report_error(report_inputs, settings, _api_error_response(401, "authentication_error", "invalid x-api-key"))
    assert error.code == ErrorCode.REPORT_AUTH_FAILED and not error.retryable
    assert error.message == "The Anthropic API key was rejected."
    assert error.title == "Anthropic refused the request"


def test_the_apis_own_403_is_still_a_refused_request(report_inputs, settings):
    response = _api_error_response(403, "permission_error", "Your API key does not have permission.")
    error = _sdk_report_error(report_inputs, settings, response)
    assert error.code == ErrorCode.REPORT_AUTH_FAILED and error.message.startswith("Anthropic refused this request")


def test_a_gateways_5xx_page_is_still_a_busy_api(report_inputs, settings):
    page = httpx2.Response(503, headers={"content-type": "text/html"}, content=b"<html>503 Service Unavailable</html>")
    assert _sdk_report_error(report_inputs, settings, page).code == ErrorCode.REPORT_OVERLOADED


@pytest.mark.parametrize(
    ("error_type", "code"),
    [("overloaded_error", ErrorCode.REPORT_OVERLOADED), ("rate_limit_error", ErrorCode.REPORT_RATE_LIMITED)],
)
def test_errors_that_arrive_mid_stream_still_map_right(report_inputs, settings, error_type, code):
    # An SSE "error" event on an HTTP 200 stream: the SDK raises a plain APIStatusError with status 200.
    message = {
        "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [],
        "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 900, "output_tokens": 1},
    }  # fmt: skip
    events = [
        ("message_start", {"type": "message_start", "message": message}),
        ("error", {"type": "error", "error": {"type": error_type, "message": "busy"}}),
    ]
    body = "".join(f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events)
    stream = httpx2.Response(200, headers={"content-type": "text/event-stream"}, content=body.encode())
    raised = _sdk_report_error(report_inputs, settings, stream)
    assert raised.code == code
    assert isinstance(raised.__cause__, anthropic.APIStatusError) and raised.__cause__.status_code == 200


# ---------------------------------------------------------------------------
# 5. Free-throw warning texts
# ---------------------------------------------------------------------------


def _unmapped_gpu_result():
    no_court = PipelineWarning(code="NO_COURT_HOMOGRAPHY", message="The court lines could not be mapped.")
    tracking = helpers.tracking([], homography=False)
    return tracking.model_copy(update={"warnings": [no_court]})


@pytest.mark.parametrize(
    ("calibrated", "fix"),
    [
        (False, "Calibrate the court, then choose Full re-analysis."),
        (True, "Your calibration is used on this server only: choose Full re-analysis so the GPU looks for them."),
    ],
)
def test_the_servers_free_throw_warning_says_the_shooting_fouls_are_missing_too(calibrated, fix):
    # The GPU's own message and docs/TRACKING_SCHEMA.md say the shooting fouls inferred from the free
    # throws are missing as well; the server's fallback named FGA and points only.
    (warning,) = pipeline._free_throw_warnings(_unmapped_gpu_result(), calibrated=calibrated)
    assert warning.code == "FREE_THROWS_NOT_DETECTED" and warning.severity == "warning"
    message = warning.message
    assert "free throws (and the shooting fouls inferred from them)" in message.lower()
    assert "2-point attempt" in message and "FGA and points run high and PF runs low" in message
    assert message.endswith(fix)


def test_the_gpus_free_throw_warning_says_pf_runs_low():
    message = runner.FREE_THROWS_NOT_DETECTED_MESSAGE
    assert "shooting fouls" in message and "FGA and points run high and PF runs low" in message
    assert message.endswith("Calibrate the court, then choose Full re-analysis.")


def test_the_extra_events_warning_says_what_was_lost_and_what_it_does_to_the_box_score(monkeypatch):
    # "Free throws, fouls and screens could not be detected for this film." left out the jump balls
    # and periods, and that the free throws stay field-goal attempts (FGA and points high, PF low).
    def broken(*args, **kwargs):
        raise RuntimeError("detector bug")

    monkeypatch.setattr(extra_events, "detect_events", broken)
    perception = free_throw_trip(court=True)
    runner.merge_events(perception, [ev("e1", "shot", 10.0, track=1, team=0, made=False)])
    (warning,) = [w for w in perception.warnings if w["code"] == "EXTRA_EVENTS_FAILED"]
    message = warning["message"]
    assert message.startswith("Free throws, fouls, screens, jump balls and periods could not be detected")
    assert "free throws stay field-goal attempts" in message
    assert "FGA and points run high and PF runs low" in message
    assert not [w for w in perception.warnings if w["code"] == "FREE_THROWS_NOT_DETECTED"]


def _server_free_throw_warning() -> PipelineWarning:
    (warning,) = pipeline._free_throw_warnings(_unmapped_gpu_result(), calibrated=False)
    return warning


@pytest.mark.parametrize(
    ("codes", "why"),
    [
        (["FREE_THROWS_NOT_DETECTED"], "(the court was not mapped)"),
        (["EXTRA_EVENTS_FAILED"], "(the free-throw detection failed)"),
        (["EXTRA_EVENTS_FAILED", "FREE_THROWS_NOT_DETECTED"], "(the court was not mapped)"),
    ],
)
def test_the_fastscout_notes_carry_one_free_throw_note(game, codes, why):
    # Both codes at once: the GPU's EXTRA_EVENTS_FAILED plus the server's FREE_THROWS_NOT_DETECTED
    # for an unmapped court.
    messages = {
        "FREE_THROWS_NOT_DETECTED": _server_free_throw_warning().message,
        "EXTRA_EVENTS_FAILED": runner.EXTRA_EVENTS_FAILED_MESSAGE,
    }
    analysis = make_analysis()
    for code in codes:
        analysis.data_quality.warnings.append(PipelineWarning(code=code, message=messages[code]))
    warnings = fastscout.paste_block_warnings(analysis, game, roster=make_roster(game.id))
    notes = [w for w in warnings if "ree throw" in w]
    assert len(notes) == 1, notes
    (note,) = notes
    assert note.startswith(f"Free throws could not be detected in this film {why}")
    assert "FGM-A and PTS run high" in note and "PF is missing the shooting fouls" in note
    team_lines = [line for line in fastscout.team_helper_block(analysis, S).splitlines() if "ree throw" in line]
    assert len(team_lines) == 1 and team_lines[0].startswith(f"Free throws not detected {why}")


# ---------------------------------------------------------------------------
# 6. VIDEO_TOO_LONG text
# ---------------------------------------------------------------------------


def _probe(duration_s: float) -> VideoProbe:
    return VideoProbe(path="game.mp4", fps=15.0, fps_rational="15/1", width=1280, height=720,
                      duration_s=duration_s, frame_count=900, codec="h264")  # fmt: skip


@pytest.mark.parametrize(
    ("duration_s", "text"),
    [
        (9000.2, "The film is 150 minutes 0.2 seconds long; the limit is 150 minutes 0.0 seconds."),
        (9000.004, "The film is 150 minutes 0.004 seconds long; the limit is 150 minutes 0.000 seconds."),
        (9024.0, "The film is 150.4 minutes long; the limit is 150.0 minutes."),  # as before
        (9601.0, "The film is 160 minutes long; the limit is 150 minutes."),
    ],
)
def test_a_film_just_over_the_limit_is_not_reported_as_long_as_the_limit(duration_s, text):
    # 0.2 s over read "The film is 150.00 minutes long; the limit is 150.00 minutes."
    with pytest.raises(PipelineError) as info:
        video.validate_probe(_probe(duration_s), max_duration_s=9000.0)
    assert info.value.code == errors.VIDEO_TOO_LONG and info.value.message == text


@pytest.mark.parametrize(
    ("minutes", "text"),
    [
        (150.3, "This film is 150.3 minutes long; the limit is 150.0 minutes."),
        (150.0 + 0.2 / 60, "This film is 150 minutes 0.2 seconds long; the limit is 150 minutes 0.0 seconds."),
        (151.0, "This film is 151 minutes long; the limit is 150 minutes."),
    ],
)
def test_an_upload_just_over_the_limit_is_not_reported_as_long_as_the_limit(client, game, monkeypatch, minutes, text):
    # The server's own check printed whole minutes: a 150.3-minute film read "This film is 150 minutes
    # long; the limit is 150 minutes."
    monkeypatch.setattr(uploads, "probe_duration_s", lambda path: minutes * 60)
    upload = upload_all(client, game.id, fake_mp4(3000))
    r = client.post(f"/api/uploads/{upload['id']}/complete")
    assert r.status_code == 422 and r.json()["error"]["code"] == "VIDEO_TOO_LONG"
    assert r.json()["error"]["message"] == text
