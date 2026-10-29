"""Regression tests from the second API / auth review.

Each test names the defect it pins down; the ones under "Verified" pin behaviour that
was checked and found right.
"""

from __future__ import annotations

import asyncio
import base64
import logging
import socket

import httpx
import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from scout import auth, config, db
from scout.main import create_app
from scout.schemas import CalibrationPoint, CourtCalibration, Roster, RosterPlayer, TeamSide
from tests.conftest import TEST_USER
from tests.helpers import IDENTITY
from tests.test_api_support import fake_mp4, make_app

MB = 1024 * 1024
OCTETS = {"Content-Type": "application/octet-stream"}
JSON = {"Content-Type": "application/json"}
REBOUND = "scouting-trap.example"  # a name another site pointed at the server's LAN address


@pytest.fixture
def client(auth_headers):
    with TestClient(create_app(), headers=auth_headers) as c:
        yield c


def _basic(user: str, password: str) -> dict[str, str]:
    return {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()}


def _signed_out_app(monkeypatch, **env: str):
    return make_app(monkeypatch, SCOUT_AUTH_DISABLED="true", **env)


# ---------------------------------------------------------------------------
# New film: the calibration of the old film goes too
# ---------------------------------------------------------------------------


def _calibration() -> CourtCalibration:
    points = [CalibrationPoint(landmark=f"point_{i}", px=(100.0 * i, 50.0 * i)) for i in range(4)]
    return CourtCalibration(
        points=points, matrix=IDENTITY, reprojection_error_ft=0.4, frame_t=30.0, video_width=1920, video_height=1080
    )


def _upload_film(client: TestClient, game_id: str, data: bytes) -> dict:
    upload = client.post(f"/api/games/{game_id}/uploads", json={"filename": "film.mp4", "size": len(data)}).json()
    r = client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=data, headers=OCTETS)
    assert r.status_code == 200, r.text
    return upload


def test_a_new_upload_clears_the_calibration_clicked_on_the_old_film(client, game):
    """The landmarks were clicked on the OLD film's frame; the worker sends the game's
    calibration to the GPU, so it used to be baked into the new film's results."""
    db.update_game(game.id, calibration=_calibration())
    upload = _upload_film(client, game.id, fake_mp4(3000))
    r = client.post(f"/api/uploads/{upload['id']}/complete", params={"auto_start": "false"})
    assert r.status_code == 200, r.text
    assert r.json()["game"]["calibration"] is None
    assert db.get_game(game.id).calibration is None


def test_a_video_link_clears_the_calibration_clicked_on_the_old_film(client, game):
    db.update_game(game.id, calibration=_calibration())
    r = client.post(f"/api/games/{game.id}/video-url", json={"url": "https://example.com/film.mp4"})
    assert r.status_code == 200, r.text
    assert r.json()["game"]["calibration"] is None and r.json()["job"]["kind"] == "analyze"
    assert db.get_game(game.id).calibration is None


# ---------------------------------------------------------------------------
# Request body caps (no nginx in the default install)
# ---------------------------------------------------------------------------


def test_json_bodies_over_1_mb_are_refused_before_they_are_read(client):
    """FastAPI read any JSON body into memory, whatever its size."""
    body = b'{"scouted_team": "North", "padding": "' + b"x" * MB + b'"}'
    r = client.post("/api/games", content=body, headers=JSON)
    assert r.status_code == 413, r.text
    error = r.json()["error"]
    assert error["code"] == "REQUEST_TOO_LARGE" and error["title"] == "Request too large"
    assert error["retryable"] is False and "1 MB" in error["message"]
    assert set(error) == set(client.get("/api/games/g_000000").json()["error"])  # the shape of every other error
    assert db.list_games() == []
    small = b'{"scouted_team": "North", "padding": "' + b"x" * (MB - 100) + b'"}'
    assert client.post("/api/games", content=small, headers=JSON).status_code == 201


def test_bodies_without_content_length_are_capped_as_they_arrive(game, auth_headers):
    """A chunked body has no Content-Length to check: the bytes are counted, and the rest
    of the body is never read once it passes the cap."""
    app = create_app()
    pieces_sent = []

    async def four_mb():
        for _ in range(64):
            pieces_sent.append(1)
            yield b" " * (64 * 1024)

    async def scenario() -> httpx.Response:
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver", headers=auth_headers) as c:
            return await c.put(f"/api/games/{game.id}/rosters/scouted", content=four_mb(), headers=JSON)

    r = asyncio.run(scenario())
    assert r.status_code == 413 and r.json()["error"]["code"] == "REQUEST_TOO_LARGE"
    assert len(pieces_sent) <= 18  # about 1 MB of the 4 MB
    assert db.get_roster(game.id, TeamSide.SCOUTED).players == []


def test_multipart_bodies_over_4_mb_are_refused_before_they_are_spooled(client, game):
    """The roster route checks its 2 MB only after the whole form was parsed into a temp file."""
    url = f"/api/games/{game.id}/rosters/scouted/import"
    r = client.post(url, files={"file": ("roster.csv", b"#,Name\n" + b"3,A\n" * MB, "text/csv")})
    assert r.status_code == 413 and r.json()["error"]["code"] == "REQUEST_TOO_LARGE"
    # Between the two limits the route answers with its own message.
    r = client.post(url, files={"file": ("roster.csv", b"x" * (3 * MB), "text/csv")})
    assert r.status_code == 413 and r.json()["error"]["code"] == "UPLOAD_TOO_LARGE"


def test_a_body_that_passes_the_cap_midway_gets_one_413_and_the_app_sees_the_client_leave():
    from scout.api.limits import BodyLimitMiddleware

    async def run(*, answer_first: bool) -> tuple[list[int], list[str], int]:
        incoming = [{"type": "http.request", "body": b"x" * (600 * 1024), "more_body": True} for _ in range(3)]
        sent: list[dict] = []
        seen: list[str] = []

        async def receive():
            return incoming.pop(0)

        async def send(message):
            sent.append(message)

        async def app(scope, receive, send):
            if answer_first:
                await send({"type": "http.response.start", "status": 200, "headers": []})
            while (message := await receive())["type"] == "http.request":
                seen.append("data")
            seen.append(message["type"])
            if not answer_first:
                await send({"type": "http.response.start", "status": 400, "headers": []})  # dropped: the 413 went first
            await send({"type": "http.response.body", "body": b"..."})

        scope = {"type": "http", "method": "POST", "path": "/api/games", "headers": [(b"content-type", b"application/json")]}
        await BodyLimitMiddleware(app)(scope, receive, send)
        return [m["status"] for m in sent if m["type"] == "http.response.start"], seen, len(incoming)

    # The third piece is never read.
    assert asyncio.run(run(answer_first=False)) == ([413], ["data", "http.disconnect"], 1)
    # Too late for a 413 once the app has answered: it just sees the client leave.
    assert asyncio.run(run(answer_first=True)) == ([200], ["data", "http.disconnect"], 1)


def test_get_and_head_requests_and_film_chunks_are_not_capped(auth_headers, game, monkeypatch):
    with TestClient(make_app(monkeypatch, SCOUT_UPLOAD_CHUNK_MB="2"), headers=auth_headers) as c:
        assert c.request("GET", f"/api/games/{game.id}", content=b"x" * (2 * MB)).status_code == 200
        assert c.request("HEAD", "/static/js/api.js", content=b"x" * (2 * MB)).status_code == 200
        data = fake_mp4(3 * MB)
        upload = c.post(f"/api/games/{game.id}/uploads", json={"filename": "film.mp4", "size": len(data)}).json()
        url = f"/api/uploads/{upload['id']}/chunk"
        r = c.put(url, params={"offset": 0}, content=data[: 2 * MB], headers=OCTETS)
        assert r.status_code == 200 and r.json()["received"] == 2 * MB
        # The chunk route keeps its own limit: the upload's remaining size (and twice its chunk size).
        r = c.put(url, params={"offset": 2 * MB}, content=data[2 * MB :] + b"extra", headers=OCTETS)
        assert r.status_code == 413 and r.json()["error"]["code"] == "UPLOAD_TOO_LARGE"


# ---------------------------------------------------------------------------
# Allowed host names (DNS rebinding with sign-in off)
# ---------------------------------------------------------------------------


def test_with_sign_in_off_a_rebound_name_cannot_read_rosters_or_delete_games(monkeypatch, game):
    """A page whose name was pointed at the server's address is same-origin for the browser,
    so the cross-site guard let it read the rosters (minors' names) and delete games."""
    players = [RosterPlayer(jersey="3", first_name="Jordan", last_name="Smith")]
    db.save_roster(Roster(game_id=game.id, side=TeamSide.SCOUTED, players=players))
    page = {"Sec-Fetch-Site": "same-origin", "Origin": f"http://{REBOUND}:8000"}
    with TestClient(_signed_out_app(monkeypatch), base_url=f"http://{REBOUND}:8000") as c:
        r = c.get(f"/api/games/{game.id}/rosters", headers={"Sec-Fetch-Site": "same-origin"})
        assert r.status_code == 403 and "Smith" not in r.text
        error = r.json()["error"]
        assert error["code"] == "HOST_NOT_ALLOWED" and error["title"] == "Unknown server name"
        assert REBOUND in error["message"] and "SCOUT_ALLOWED_HOSTS" in error["message"]
        assert c.delete(f"/api/games/{game.id}", headers=page).status_code == 403
        assert c.get("/").status_code == 403
    assert db.get_game(game.id) is not None


@pytest.mark.parametrize(
    "host", ["127.0.0.1:8000", "192.168.1.50", "[::1]:8000", "[fe80::1]", "localhost:8000", "LocalHost", "scout.localhost"]
)
def test_with_sign_in_off_addresses_and_localhost_still_work(monkeypatch, host):
    with TestClient(_signed_out_app(monkeypatch)) as c:
        assert c.get("/api/games", headers={"Host": host}).status_code == 200


def test_with_sign_in_off_the_machines_own_name_works(monkeypatch):
    monkeypatch.setattr(socket, "gethostname", lambda: "Scout-VM.lan")
    with TestClient(_signed_out_app(monkeypatch)) as c:
        for host in ("scout-vm.lan", "scout-vm:8000", "scout-vm.local", "SCOUT-VM.LOCAL."):
            assert c.get("/api/games", headers={"Host": host}).status_code == 200, host
        for host in ("scout-vm.evil.example", "evil-scout-vm", "scout-vm:http", "[scout-vm]"):
            assert c.get("/api/games", headers={"Host": host}).status_code == 403, host


def test_x_forwarded_host_can_refuse_a_request_but_never_let_one_through(monkeypatch):
    """A page can set X-Forwarded-Host itself (it is same-origin after rebinding); behind a
    proxy that rewrites Host (Apache's default) the header carries the browser's name."""
    with TestClient(_signed_out_app(monkeypatch)) as c:
        assert c.get("/api/games", headers={"Host": REBOUND, "X-Forwarded-Host": "localhost"}).status_code == 403
        assert c.get("/api/games", headers={"Host": "127.0.0.1:8000", "X-Forwarded-Host": REBOUND}).status_code == 403
        forwarded = {"Host": "127.0.0.1:8000", "X-Forwarded-Host": f"localhost, {REBOUND}"}
        assert c.get("/api/games", headers=forwarded).status_code == 403
        assert c.get("/api/games", headers={"Host": "127.0.0.1:8000", "X-Forwarded-Host": "10.0.0.5:443"}).status_code == 200


def test_allowed_hosts_setting(monkeypatch, auth_headers):
    monkeypatch.setattr(socket, "gethostname", lambda: "scout-vm")
    app = make_app(monkeypatch, SCOUT_ALLOWED_HOSTS="Scout.School.org, *.district.org")
    with TestClient(app, headers=auth_headers) as c:
        allowed = ("scout.school.org", "SCOUT.school.org.:8443", "gym.district.org", "a.b.district.org", "10.0.0.5", "[::1]")
        for host in (*allowed, "localhost"):
            assert c.get("/api/games", headers={"Host": host}).status_code == 200, host
        for host in ("district.org", "evildistrict.org", "scout.school.org.evil.example", "scout-vm", REBOUND):
            r = c.get("/api/games", headers={"Host": host})
            assert r.status_code == 403 and r.json()["error"]["code"] == "HOST_NOT_ALLOWED", host
    with TestClient(_signed_out_app(monkeypatch, SCOUT_ALLOWED_HOSTS="*")) as c:
        assert c.get("/api/games", headers={"Host": REBOUND}).status_code == 200  # "*": any name
    with TestClient(_signed_out_app(monkeypatch, SCOUT_ALLOWED_HOSTS="scout.school.org:8443")) as c:
        assert c.get("/api/games", headers={"Host": "scout.school.org"}).status_code == 200  # names, not ports
        assert c.get("/api/games", headers={"Host": REBOUND}).status_code == 403


def test_with_sign_in_on_and_no_setting_any_name_still_works(client):
    """The browser never sends the coach's saved password to another site's name."""
    assert client.get("/api/games", headers={"Host": REBOUND}).status_code == 200


def test_health_live_answers_to_any_name(monkeypatch):
    with TestClient(_signed_out_app(monkeypatch, SCOUT_ALLOWED_HOSTS="scout.school.org")) as c:
        assert c.get("/api/health/live", headers={"Host": REBOUND}).json() == {"status": "ok"}
        assert c.get("/api/health", headers={"Host": REBOUND}).status_code == 403


def test_unknown_names_are_refused_before_sign_in_and_do_not_count_as_failures(monkeypatch, auth_headers):
    with TestClient(make_app(monkeypatch, SCOUT_ALLOWED_HOSTS="scout.school.org")) as c:
        for i in range(15):
            assert c.get("/api/games", headers={"Host": REBOUND, **_basic(TEST_USER, f"guess-{i}")}).status_code == 403
        assert c.get("/api/games", headers={"Host": "scout.school.org", **auth_headers}).status_code == 200


def test_websockets_to_an_unknown_name_are_closed(monkeypatch):
    with TestClient(_signed_out_app(monkeypatch)) as c:
        with pytest.raises(WebSocketDisconnect) as closed, c.websocket_connect("/api/anything", headers={"Host": REBOUND}):
            pass
        assert closed.value.code == 1008


def test_startup_warns_when_sign_in_is_off_and_no_names_are_set(settings, caplog, monkeypatch):
    monkeypatch.setattr(socket, "gethostname", lambda: "scout-vm")
    signed_out = settings.model_copy(update={"auth_disabled": True})
    with caplog.at_level(logging.WARNING, logger="scout.auth"):
        auth.log_auth_status(signed_out)
    assert "SCOUT_ALLOWED_HOSTS is empty" in caplog.text and "scout-vm.local" in caplog.text
    caplog.clear()
    with caplog.at_level(logging.WARNING, logger="scout.auth"):
        auth.log_auth_status(signed_out.model_copy(update={"allowed_hosts": "scout.school.org"}))
        auth.log_auth_status(settings)
    assert "SCOUT_ALLOWED_HOSTS" not in caplog.text


# ---------------------------------------------------------------------------
# Verified (no change needed): the first round's device cookie
# ---------------------------------------------------------------------------

SHARED_ADDRESS = ("203.0.113.50", 4000)


def test_device_cookie_is_secure_only_behind_a_trusted_https_proxy(auth_headers):
    """uvicorn as deployed (--proxy-headers --forwarded-allow-ips 127.0.0.1) takes the scheme
    from X-Forwarded-Proto only when nginx on this machine sent it."""
    from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

    app = ProxyHeadersMiddleware(create_app(), trusted_hosts="127.0.0.1")
    https = {**auth_headers, "X-Forwarded-Proto": "https"}

    def cookie(client_address: tuple[str, int], headers: dict[str, str]) -> str:
        with TestClient(app, client=client_address) as c:
            return c.get("/api/games", headers=headers).headers["set-cookie"]

    assert "Secure" in cookie(("127.0.0.1", 4000), https)  # nginx with a certificate
    assert "Secure" not in cookie(("127.0.0.1", 4000), auth_headers)  # nginx on plain http
    assert "Secure" not in cookie(("203.0.113.9", 4000), https)  # a client cannot claim https


def test_a_password_change_needs_the_restart_that_retires_the_device_cookies(monkeypatch, auth_headers):
    """The cookie key lives in the web process, and the password is read when it starts."""
    with TestClient(create_app(), client=SHARED_ADDRESS) as browser:
        assert browser.get("/api/games", headers=auth_headers).status_code == 200
        old_cookie = browser.cookies[auth.DEVICE_COOKIE]
        monkeypatch.setenv("SCOUT_AUTH_PASSWORD", "new-password-456")  # .env edited, no restart yet
        config.reset_settings()
        assert browser.get("/api/games", headers=auth_headers).status_code == 200
        assert browser.get("/api/games", headers=_basic(TEST_USER, "new-password-456")).status_code == 401
    with TestClient(create_app(), client=SHARED_ADDRESS, cookies={auth.DEVICE_COOKIE: old_cookie}) as browser:
        r = browser.get("/api/games", headers=_basic(TEST_USER, "new-password-456"))
        assert r.status_code == 200 and r.cookies[auth.DEVICE_COOKIE] != old_cookie  # replaced by a new one
        assert browser.get("/api/games", headers=auth_headers).status_code == 401
