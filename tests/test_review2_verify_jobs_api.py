"""Second review round, verification of the jobs and API fixes: defects found in them, and the
interactions between them that were checked and found right (under "Verified")."""

from __future__ import annotations

import asyncio
import threading

import httpx
from fastapi.testclient import TestClient

from scout import db, storage
from scout.api import jobs as jobs_api
from scout.errors import ErrorCode, ScoutError
from scout.main import create_app
from scout.schemas import JobKind, JobStage, JobStatus, TeamSide
from tests import helpers
from tests.test_api_support import fake_mp4, make_app
from tests.test_worker import filmed_game  # noqa: F401 - fixture

MB = 1024 * 1024


# --- retry: the REANALYZE decision is made under start_lock -----------------------------------


class _WatchedLock:
    """``start_lock`` stand-in (re-entrant, like the real one) that says when a second thread waits."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self.contended = threading.Event()

    def __enter__(self) -> _WatchedLock:
        if not self._lock.acquire(blocking=False):
            self.contended.set()
            self._lock.acquire()
        return self

    def __exit__(self, *_exc: object) -> None:
        self._lock.release()


def test_a_retry_during_a_film_change_waits_for_it_before_choosing_a_reanalysis(
    filmed_game, auth_headers, monkeypatch  # noqa: F811
):
    """retry_job looked for the old tracking.json.gz before taking start_lock, which a film change
    holds while it deletes that file. A retry that arrived meanwhile chose a REANALYZE and then
    failed with 'There is no tracking data to re-analyse yet' instead of analysing the new film."""
    storage.write_json(storage.tracking_path(filmed_game.id), helpers.tracking([]).model_dump_json())
    old = db.create_job(filmed_game.id, JobKind.ANALYZE, {})
    error = ScoutError(ErrorCode.ANALYSIS_FAILED)
    db.update_job(old.id, status=JobStatus.FAILED, stage=JobStage.ANALYZING, error=error, finished_at=db.utcnow())
    lock = _WatchedLock()
    monkeypatch.setattr(jobs_api, "start_lock", lock)
    answers: list[httpx.Response] = []
    with TestClient(create_app(), headers=auth_headers) as c:
        with lock:  # a film change (auto_start=false) is under way
            retry = threading.Thread(target=lambda: answers.append(c.post(f"/api/jobs/{old.id}/retry")))
            retry.start()
            assert lock.contended.wait(10)
            storage.tracking_path(filmed_game.id).unlink()  # ... and deletes the old film's results
        retry.join(10)
    assert answers[0].status_code == 200, answers[0].text
    assert answers[0].json()["kind"] == JobKind.ANALYZE  # the new film goes to the GPU


# --- Verified: body caps with streamed bodies, and the cap next to the host check ------------------


def _stream(total: int, piece: int = 64 * 1024):
    async def pieces():
        sent = 0
        while sent < total:
            yield b"x" * min(piece, total - sent)
            sent += piece

    return pieces()


async def _send(app, method: str, url: str, **kwargs) -> httpx.Response:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as c:
        return await c.request(method, url, **kwargs)


def test_a_streamed_roster_form_over_4_mb_is_refused_as_it_arrives(game, auth_headers):
    """No Content-Length (chunked transfer encoding): the multipart cap still applies."""
    boundary = "scout-boundary"

    async def form():
        head = f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="roster.csv"\r\n'
        yield (head + "Content-Type: text/csv\r\n\r\n").encode()
        async for piece in _stream(5 * MB):
            yield piece
        yield f"\r\n--{boundary}--\r\n".encode()

    url = f"/api/games/{game.id}/rosters/scouted/import"
    headers = {**auth_headers, "Content-Type": f"multipart/form-data; boundary={boundary}"}
    r = asyncio.run(_send(create_app(), "POST", url, content=form(), headers=headers))
    assert r.status_code == 413 and r.json()["error"]["code"] == "REQUEST_TOO_LARGE"
    assert db.get_roster(game.id, TeamSide.SCOUTED).players == []


def test_a_streamed_film_chunk_bigger_than_the_json_cap_is_written(game, auth_headers):
    async def scenario() -> tuple[httpx.Response, httpx.Response]:
        app = create_app()
        data = fake_mp4(3 * MB)
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver", headers=auth_headers) as c:
            upload = (await c.post(f"/api/games/{game.id}/uploads", json={"filename": "f.mp4", "size": len(data)})).json()

            async def chunk(extra: bytes = b""):
                for start in range(0, len(data), 256 * 1024):
                    yield data[start : start + 256 * 1024]
                if extra:
                    yield extra

            url, octets = f"/api/uploads/{upload['id']}/chunk", {"Content-Type": "application/octet-stream"}
            too_long = await c.put(url, params={"offset": 0}, content=chunk(b"x"), headers=octets)
            written = await c.put(url, params={"offset": 0}, content=chunk(), headers=octets)
            return too_long, written

    too_long, written = asyncio.run(scenario())
    assert too_long.status_code == 413 and too_long.json()["error"]["code"] == "UPLOAD_TOO_LARGE"  # its own limit
    assert written.status_code == 200 and written.json()["received"] == 3 * MB


def test_an_unknown_server_name_is_refused_before_its_body_is_read(monkeypatch, game):
    """With sign-in off, the host check answers first; nothing of the 4 MB body is read."""
    app = make_app(monkeypatch, SCOUT_AUTH_DISABLED="true")
    sent: list[int] = []

    async def body():
        for _ in range(64):
            sent.append(1)
            yield b" " * (64 * 1024)

    headers = {"Host": "scouting-trap.example", "Content-Type": "application/json"}
    r = asyncio.run(_send(app, "PUT", f"/api/games/{game.id}/rosters/scouted", content=body(), headers=headers))
    assert r.status_code == 403 and r.json()["error"]["code"] == "HOST_NOT_ALLOWED"
    assert len(sent) <= 1  # httpx may start the body before the answer arrives


def test_an_allowed_name_still_gets_the_cross_site_check(monkeypatch, game, auth_headers):
    """The host check passing does not let a change from another website through."""
    with TestClient(make_app(monkeypatch, SCOUT_ALLOWED_HOSTS="scout.school.org"), headers=auth_headers) as c:
        page = {"Host": "scout.school.org", "Origin": "https://evil.example"}
        r = c.delete(f"/api/games/{game.id}", headers=page)
        assert r.status_code == 403 and r.json()["error"]["code"] == "CROSS_SITE_REQUEST"
        same = {"Host": "[::1]:8000", "Origin": "http://[::1]:8000"}
        assert c.patch(f"/api/games/{game.id}", json={"notes": "zone"}, headers=same).status_code == 200
    assert db.get_game(game.id) is not None
