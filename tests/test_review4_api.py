"""Regression tests from the fourth API / auth review.

Track fixes refused while an ANALYZE is queued or running, HEAD on the liveness route,
and VIDEO_TOO_LONG for films less than half a millisecond over the limit. Tests marked
"guard" pin behaviour that must stay as it is.
"""

from __future__ import annotations

import socket
import threading
import time
import warnings

import pytest
import uvicorn
from fastapi.testclient import TestClient

from modal_app.pipeline import errors, video
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.video import VideoProbe
from scout import db, storage
from scout.api import uploads
from scout.api.jobs import start_lock
from scout.main import create_app
from scout.schemas import JobKind, JobStatus, Roster, RosterPlayer, TeamSide, TrackOverride
from tests.test_api_support import fake_mp4, make_app, write_source_video
from tests.test_api_uploads import upload_all

MB = 1024 * 1024
LIVE = "/api/health/live"
REBOUND = "scouting-trap.example"  # a name the server does not answer to
EARLIER_FIX = TrackOverride(track_id=40, ignore=True)


@pytest.fixture
def client(auth_headers):
    with TestClient(create_app(), headers=auth_headers) as c:
        yield c


@pytest.fixture
def rostered_game(game):
    db.save_roster(Roster(game_id=game.id, side=TeamSide.SCOUTED, players=[RosterPlayer(id="p_s1", jersey="3")]))
    db.set_track_override(game.id, EARLIER_FIX)
    return game


# ---------------------------------------------------------------------------
# 5. Track fixes while an ANALYZE is queued or running
# ---------------------------------------------------------------------------


def _fix_tracks(client: TestClient, game_id: str):
    """The Roster page's Save: assign track 12 and take back the earlier fix of track 40."""
    put = client.put(f"/api/games/{game_id}/tracks/12", json={"player_id": "p_s1", "side": "scouted"})
    delete = client.delete(f"/api/games/{game_id}/tracks/40")
    return put, delete


def _start(client: TestClient, game_id: str, kind: str) -> dict:
    r = client.post(f"/api/games/{game_id}/jobs", json={"kind": kind})
    assert r.status_code == 201, r.text
    return r.json()


def _assert_refused(response, job_id: str, status: JobStatus) -> None:
    assert response.status_code == 409
    error = response.json()["error"]
    assert error["code"] == "CONFLICT"
    assert "being analysed on the GPU" in error["message"]
    assert "numbers the players' tracks again" in error["message"]
    assert error["hint"] == "Set the track assignments once the analysis has finished."
    assert error["detail"] == f"active job {job_id} (analyze, {status})"


@pytest.mark.parametrize("status", [JobStatus.QUEUED, JobStatus.RUNNING])
def test_track_fixes_are_refused_while_an_analyze_is_queued_or_running(client, rostered_game, status):
    """They were accepted, and installing the new run then cleared them without a word."""
    write_source_video(rostered_game.id)
    job = _start(client, rostered_game.id, "analyze")
    if status == JobStatus.RUNNING:
        assert db.claim_job("w1", 60).id == job["id"]
    for response in _fix_tracks(client, rostered_game.id):
        _assert_refused(response, job["id"], status)
    assert db.list_track_overrides(rostered_game.id) == [EARLIER_FIX]  # neither written nor deleted
    tracks = client.get(f"/api/games/{rostered_game.id}/tracks")  # reading them is fine
    assert tracks.status_code == 200 and tracks.json()["overrides"] == [EARLIER_FIX.model_dump(mode="json")]


def test_a_fix_sent_while_an_analyze_is_being_started_waits_for_it_and_is_refused(client, rostered_game):
    """start_job holds start_lock from its check until the job exists. A fix that checked for an
    active ANALYZE meanwhile would be written once the job was queued, and cleared at its install."""
    url = f"/api/games/{rostered_game.id}/tracks/12"
    responses = []
    with start_lock:  # an ANALYZE being started
        sender = threading.Thread(target=lambda: responses.append(client.put(url, json={"ignore": True})))
        sender.start()
        sender.join(0.5)
        assert sender.is_alive()  # it waits for the start to finish
        job = db.create_job(rostered_game.id, JobKind.ANALYZE)
    sender.join(10)
    _assert_refused(responses[0], job.id, JobStatus.QUEUED)
    assert db.list_track_overrides(rostered_game.id) == [EARLIER_FIX]


def test_guard_track_fixes_still_work_during_a_reanalysis_or_a_report(client, rostered_game):
    """A REANALYZE keeps the track numbers (it reads the fixes when its analysis starts)."""
    storage.game_dir(rostered_game.id, create=True)
    storage.tracking_path(rostered_game.id).write_bytes(b"{}")
    _start(client, rostered_game.id, "reanalyze")
    db.create_job(rostered_game.id, JobKind.REPORT)
    assert {job.kind for job in db.active_jobs_for_game(rostered_game.id)} == {JobKind.REANALYZE, JobKind.REPORT}
    put, delete = _fix_tracks(client, rostered_game.id)
    assert put.status_code == 200 and delete.status_code == 204
    assert db.list_track_overrides(rostered_game.id) == [
        TrackOverride(track_id=12, player_id="p_s1", side=TeamSide.SCOUTED)
    ]


@pytest.mark.parametrize("status", [JobStatus.SUCCEEDED, JobStatus.FAILED, JobStatus.CANCELLED])
def test_guard_track_fixes_work_again_once_the_analyze_has_finished(client, rostered_game, status):
    write_source_video(rostered_game.id)
    job = _start(client, rostered_game.id, "analyze")
    db.update_job(job["id"], status=status)
    put, delete = _fix_tracks(client, rostered_game.id)
    assert put.status_code == 200 and delete.status_code == 204
    assert client.delete(f"/api/games/{rostered_game.id}/tracks/40").status_code == 404  # as before


# ---------------------------------------------------------------------------
# 6. HEAD on the liveness route
# ---------------------------------------------------------------------------


def _assert_live(c: TestClient, **headers: str) -> None:
    """GET answers {"status": "ok"}; HEAD answers 200 with the same headers and no body."""
    get = c.get(LIVE, headers=headers)
    assert get.status_code == 200 and get.json() == {"status": "ok"}  # guard: GET as before
    head = c.head(LIVE, headers=headers)
    assert head.status_code == 200 and head.content == b""
    assert head.headers["content-type"] == get.headers["content-type"] == "application/json"
    assert head.headers["content-length"] == get.headers["content-length"]  # what a GET would send
    assert "www-authenticate" not in head.headers and "set-cookie" not in head.headers


def test_head_on_the_liveness_route_needs_no_sign_in():
    """Hosted uptime monitors that check with HEAD got 401."""
    with TestClient(create_app()) as c:  # no credentials
        _assert_live(c)


@pytest.mark.parametrize("http", ["h11", "httptools"])
def test_head_on_the_liveness_route_sends_headers_only_through_uvicorn(http):
    """The TestClient leaves out a HEAD body by itself; uvicorn, as deployed, must do so too."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))  # a free port
    config = uvicorn.Config(create_app(), http=http, lifespan="off", log_config=None, access_log=False)
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 10
        while not server.started and thread.is_alive() and time.monotonic() < deadline:
            time.sleep(0.01)
        (get_head, get_body), (head_head, head_body) = (_raw_request(sock.getsockname(), m) for m in ("GET", "HEAD"))
    finally:
        server.should_exit = True
        thread.join(10)
    assert get_body == b'{"status":"ok"}' and b"\r\ncontent-length: 15\r\n" in get_head.lower()
    assert head_head.startswith(b"HTTP/1.1 200 ") and b"\r\ncontent-length: 15\r\n" in head_head.lower()
    assert head_body == b""


def _raw_request(address: tuple[str, int], method: str) -> tuple[bytes, bytes]:
    """``(status line and headers, body)`` of one request on its own connection."""
    with socket.create_connection(address, timeout=5) as conn:
        conn.sendall(f"{method} {LIVE} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".encode())
        data = b""
        while chunk := conn.recv(4096):
            data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    return head + b"\r\n", body


def test_head_on_the_liveness_route_with_sign_in_off(monkeypatch):
    """With sign-in off it answered 405: the route only served GET."""
    with TestClient(make_app(monkeypatch, SCOUT_AUTH_DISABLED="true"), base_url="http://localhost") as c:
        _assert_live(c)


@pytest.mark.parametrize("auth_disabled", ["true", "false"])
def test_head_on_the_liveness_route_answers_to_any_name(monkeypatch, auth_disabled):
    """As GET does: the monitor may use a name SCOUT_ALLOWED_HOSTS does not list (403 before)."""
    app = make_app(monkeypatch, SCOUT_AUTH_DISABLED=auth_disabled, SCOUT_ALLOWED_HOSTS="scout.school.org")
    with TestClient(app) as c:
        _assert_live(c, Host=REBOUND)
        r = c.head("/api/health", headers={"Host": REBOUND})  # guard: other routes still check the name
        assert r.status_code == 403


@pytest.mark.parametrize("path", ["/api/health", f"{LIVE}/", "/api/games", "/"])
def test_guard_head_on_other_routes_still_needs_sign_in(path):
    with TestClient(create_app()) as c:
        r = c.head(path)
        assert r.status_code == 401 and "www-authenticate" in r.headers


def test_the_cross_site_check_and_the_body_cap_leave_head_on_the_liveness_route_alone():
    cross_site = {"Sec-Fetch-Site": "cross-site", "Origin": "https://elsewhere.example"}
    with TestClient(create_app()) as c:
        assert c.head(LIVE, headers={**cross_site, "Content-Length": str(2 * MB)}).status_code == 200
        assert c.post(LIVE, headers=cross_site).status_code == 403  # guard: a change from another site


def test_the_api_docs_list_head_on_the_liveness_route_with_an_operation_id_of_its_own():
    """One route serving both methods would give them the same operation id (FastAPI warns)."""
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        operations = create_app().openapi()["paths"][LIVE]
    assert sorted(operations) == ["get", "head"]
    assert operations["get"]["operationId"] != operations["head"]["operationId"]
    assert not [w for w in caught if "Duplicate Operation ID" in str(w.message)]


# ---------------------------------------------------------------------------
# 7. VIDEO_TOO_LONG less than half a millisecond over the limit
# ---------------------------------------------------------------------------


def _probe(duration_s: float) -> VideoProbe:
    return VideoProbe(path="game.mp4", fps=15.0, fps_rational="15/1", width=1280, height=720,
                      duration_s=duration_s, frame_count=900, codec="h264")  # fmt: skip


@pytest.mark.parametrize(
    ("duration_s", "limit_s", "film", "limit"),
    [
        # Both read "150 minutes 0.000 seconds".
        (9000.0004, 9000.0, "150 minutes 0.0004 seconds", "150 minutes 0.0000 seconds"),
        (9000.000001, 9000.0, "150 minutes 0.000001 seconds", "150 minutes 0.000000 seconds"),
        # SCOUT_MAX_VIDEO_MINUTES=150.00001: both read "150 minutes 0.001 seconds".
        (9000.001, 150.00001 * 60, "150 minutes 0.0010 seconds", "150 minutes 0.0006 seconds"),
        (9000.004, 9000.0, "150 minutes 0.004 seconds", "150 minutes 0.000 seconds"),  # guard: as before
    ],
)
def test_a_film_just_over_the_limit_never_reads_as_long_as_the_limit(duration_s, limit_s, film, limit):
    with pytest.raises(PipelineError) as info:
        video.validate_probe(_probe(duration_s), max_duration_s=limit_s)
    assert info.value.code == errors.VIDEO_TOO_LONG
    assert info.value.message == f"The film is {film} long; the limit is {limit}."
    assert uploads._durations(duration_s, limit_s) == [film, limit]  # the server's own check, worded alike


def test_an_upload_just_over_the_limit_never_reads_as_long_as_the_limit(client, game, monkeypatch):
    monkeypatch.setattr(uploads, "probe_duration_s", lambda path: 9000.0004)  # ffprobe prints microseconds
    upload = upload_all(client, game.id, fake_mp4(3000))
    r = client.post(f"/api/uploads/{upload['id']}/complete")
    assert r.status_code == 422 and r.json()["error"]["code"] == "VIDEO_TOO_LONG"
    assert r.json()["error"]["message"] == (
        "This film is 150 minutes 0.0004 seconds long; the limit is 150 minutes 0.0000 seconds."
    )
