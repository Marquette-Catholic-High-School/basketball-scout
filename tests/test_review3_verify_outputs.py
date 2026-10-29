"""Verification of the third review round in the outputs area: link file names with multi-byte
characters or encoded folders (cut by characters on the server, plain ASCII that fits a file
name's 255 bytes on the GPU), every SDK error class with and without the API's JSON body, and
VIDEO_TOO_LONG texts whose seconds round up to the next minute.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import httpx2
import pytest
from fastapi.testclient import TestClient

from modal_app import app as app_module
from modal_app.pipeline import errors, video
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.video import VideoProbe
from scout.api import uploads
from scout.errors import ErrorCode, ScoutError
from scout.reporting import claude_report
from scout.schemas import TeamSide
from tests.test_api_support import make_app
from tests.test_export_fastscout import make_analysis, make_roster
from tests.test_reporting import _sdk_client


@pytest.fixture
def client(auth_headers, monkeypatch):
    with TestClient(make_app(monkeypatch), headers=auth_headers) as c:
        yield c


def _link_name(client: TestClient, game_id: str, url: str) -> str:
    r = client.post(f"/api/games/{game_id}/video-url", params={"auto_start": "false"}, json={"url": url})
    assert r.status_code == 200, r.text
    return r.json()["game"]["video_filename"]


# ---------------------------------------------------------------------------
# Long file names from links
# ---------------------------------------------------------------------------


class _Film(io.BytesIO):
    def __init__(self, body: bytes) -> None:
        super().__init__(body)
        self.headers = {"Content-Type": "video/mp4", "Content-Length": str(len(body))}


class _Volume:
    def reload(self) -> None:
        pass

    def commit(self) -> None:
        pass


def test_a_multibyte_link_name_is_cut_by_characters_and_downloads_on_the_gpu(client, game, monkeypatch, tmp_path):
    # "é" is 2 bytes in UTF-8: the server's 255 is characters (like a typed name, which only ever
    # reaches the database); the GPU's file name is plain ASCII, so "<name>.part" fits in 255 bytes.
    url = "https://films.example.com/" + "%C3%A9" * 100 + "x" * 200 + ".mp4"
    name = _link_name(client, game.id, url)
    assert name == "é" * 100 + "x" * 151 + ".mp4" and len(name.encode()) > 255

    seen: list[Path] = []

    def fake_run_pipeline(video_path, options, *, output_dir, job_id, progress=None, filename=None):
        seen.append(Path(video_path))
        assert filename == name and Path(video_path).read_bytes() == b"link film"
        return {"status": "ok", "job_id": job_id, "warnings": []}

    monkeypatch.setattr(video.urllib.request, "urlopen", lambda request, timeout=None: _Film(b"link film"))
    monkeypatch.setattr(video.time, "sleep", lambda seconds: None)
    monkeypatch.setattr(app_module, "run_pipeline", fake_run_pipeline)
    request = {"job_id": "j_utf8", "video": {"type": "url", "url": url, "filename": name}, "options": {}}
    response = app_module.handle_request(request, volume=_Volume(), progress_store={}, root=tmp_path / "volume")
    assert response["status"] == "ok", response
    (path,) = seen
    assert path.name.isascii() and len(path.name) <= 100 and path.name.endswith(".mp4")
    assert len((path.name + ".part").encode()) <= 255


@pytest.mark.parametrize(
    ("segment", "name"),
    [
        ("a%2F..%2F" + "b" * 300 + ".mp4", "b" * 251 + ".mp4"),  # an encoded "/" is a folder, not part of the name
        ("c%5C" + "d" * 300 + ".mov", "d" * 251 + ".mov"),  # an encoded "\" too
        ("e" * 300 + "%2Em4v", "e" * 251 + ".m4v"),  # an encoded "." still starts the extension
    ],
    ids=["slash", "backslash", "dot"],
)
def test_encoded_folders_in_a_long_link_name_never_reach_the_name(client, game, segment, name):
    assert _link_name(client, game.id, f"https://films.example.com/films/{segment}") == name


# ---------------------------------------------------------------------------
# Report errors: every SDK error class, with and without the API's JSON error body
# ---------------------------------------------------------------------------

_API_TYPES = {
    400: "invalid_request_error", 401: "authentication_error", 402: "billing_error", 403: "permission_error",
    404: "not_found_error", 407: "invalid_request_error", 413: "request_too_large", 429: "rate_limit_error",
    500: "api_error", 529: "overloaded_error",
}  # fmt: skip
_BODIES = {
    "api": lambda status: {"json": {"type": "error", "error": {"type": _API_TYPES[status], "message": "api says"}}},
    "html": lambda status: {"headers": {"content-type": "text/html"}, "content": b"<html><h1>Blocked</h1></html>"},
    "text": lambda status: {"headers": {"content-type": "text/plain"}, "content": b"Access denied"},
    "empty": lambda status: {"content": b""},
    "other-json": lambda status: {"json": {"message": "Forbidden by policy"}},  # an API gateway's own JSON
}
FILTER = "filter"  # REPORT_FAILED "... did not come from the API: a web filter or proxy ..." with the filter hint
_EXPECTED = [
    (400, "api", ErrorCode.REPORT_FAILED),
    (401, "api", ErrorCode.REPORT_AUTH_FAILED),
    (402, "api", ErrorCode.REPORT_FAILED),
    (403, "api", ErrorCode.REPORT_AUTH_FAILED),
    (404, "api", ErrorCode.REPORT_FAILED),
    (407, "api", ErrorCode.REPORT_FAILED),
    (413, "api", ErrorCode.REPORT_FAILED),
    (429, "api", ErrorCode.REPORT_RATE_LIMITED),
    (500, "api", ErrorCode.REPORT_OVERLOADED),
    (529, "api", ErrorCode.REPORT_OVERLOADED),
    *[(status, body, FILTER) for status in (400, 401, 402, 403, 404, 407, 413, 429) for body in _BODIES if body != "api"],
    *[(status, body, ErrorCode.REPORT_OVERLOADED) for status in (500, 529) for body in ("html", "empty")],
]


def _report_error(game, settings, response: httpx2.Response) -> ScoutError:
    client, _ = _sdk_client(response)
    rosters = {TeamSide.SCOUTED: make_roster(game.id)}
    with pytest.raises(ScoutError) as err:
        claude_report.generate_report(make_analysis(), game, rosters, settings=settings, client=client)
    return err.value


@pytest.mark.parametrize(("status", "body", "expected"), _EXPECTED, ids=[f"{s}-{b}" for s, b, _ in _EXPECTED])
def test_every_sdk_error_class_maps_by_whether_the_api_answered(game, settings, status, body, expected):
    # The SDK picks the class from the status alone (AuthenticationError, NotFoundError, RateLimitError,
    # ...); only the API's own JSON error says the key, the model or the rate limit is to blame.
    error = _report_error(game, settings, httpx2.Response(status, **_BODIES[body](status)))
    if expected == FILTER:
        assert error.code == ErrorCode.REPORT_FAILED and error.retryable
        assert f"(HTTP {status})" in error.message and "web filter or proxy" in error.message
        assert error.hint == claude_report._FILTER_HINT
        assert "<" not in (error.detail or "") and "Access denied" not in (error.detail or "")
    else:
        assert error.code == expected and error.hint != claude_report._FILTER_HINT


def _stream_with_error(data: str) -> httpx2.Response:
    message = {
        "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [],
        "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 900, "output_tokens": 1},
    }  # fmt: skip
    body = f"event: message_start\ndata: {json.dumps({'type': 'message_start', 'message': message})}\n\n"
    body += f"event: error\ndata: {data}\n\n"
    return httpx2.Response(200, headers={"content-type": "text/event-stream"}, content=body.encode())


@pytest.mark.parametrize(
    ("data", "expected"),
    [
        (json.dumps({"type": "error", "error": {"type": "api_error", "message": "x"}}), ErrorCode.REPORT_OVERLOADED),
        ("<html>proxy</html>", FILTER),  # not the API's JSON: as before this round
    ],
    ids=["api_error", "not-json"],
)
def test_other_errors_that_arrive_mid_stream(game, settings, data, expected):
    error = _report_error(game, settings, _stream_with_error(data))
    if expected == FILTER:
        assert error.code == ErrorCode.REPORT_FAILED and "(HTTP 200)" in error.message
        assert error.hint == claude_report._FILTER_HINT
    else:
        assert error.code == expected


# ---------------------------------------------------------------------------
# VIDEO_TOO_LONG: seconds that round up to a whole minute
# ---------------------------------------------------------------------------


def _probe(duration_s: float) -> VideoProbe:
    return VideoProbe(path="game.mp4", fps=15.0, fps_rational="15/1", width=1280, height=720,
                      duration_s=duration_s, frame_count=900, codec="h264")  # fmt: skip


def test_seconds_that_round_up_carry_into_the_minutes():
    # 9059.96 s is 150 minutes 59.96 seconds: printed with one decimal of seconds it is
    # "151 minutes 0.0 seconds", never "150 minutes 60.0 seconds" (GPU and upload check alike).
    with pytest.raises(PipelineError) as info:
        video.validate_probe(_probe(9059.96), max_duration_s=9059.9)
    assert info.value.code == errors.VIDEO_TOO_LONG
    assert info.value.message == "The film is 151 minutes 0.0 seconds long; the limit is 150 minutes 59.9 seconds."
    assert uploads._durations(9059.96, 9059.9) == ["151 minutes 0.0 seconds", "150 minutes 59.9 seconds"]
