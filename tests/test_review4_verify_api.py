"""Regression tests from the verification of the fourth API / auth review.

A track fix racing a real ``POST /jobs`` that starts an ANALYZE, credentials sent with HEAD on
the liveness route, and the ``Allow`` header of a 405 there.
"""

from __future__ import annotations

import base64
import threading

import pytest
from fastapi.testclient import TestClient

from scout import db
from scout.api import jobs as jobs_api
from scout.main import create_app
from scout.schemas import JobKind, Roster, RosterPlayer, TeamSide
from tests.test_api_support import write_source_video

LIVE = "/api/health/live"


@pytest.fixture
def client(auth_headers):
    with TestClient(create_app(), headers=auth_headers) as c:
        yield c


def test_a_fix_sent_while_post_jobs_starts_an_analyze_waits_for_the_job_and_is_refused(client, game, monkeypatch):
    """The real start_job, past its check and queueing the ANALYZE. A fix that did not wait for it was
    written as the job appeared, and installing the new run then cleared it."""
    db.save_roster(Roster(game_id=game.id, side=TeamSide.SCOUTED, players=[RosterPlayer(id="p_s1", jersey="3")]))
    write_source_video(game.id)
    queueing, go_on = threading.Event(), threading.Event()
    submit = jobs_api._submit

    def slow_submit(*args, **kwargs):
        queueing.set()
        assert go_on.wait(10)
        return submit(*args, **kwargs)

    monkeypatch.setattr(jobs_api, "_submit", slow_submit)
    started, fixed = [], []
    jobs_url, track_url = f"/api/games/{game.id}/jobs", f"/api/games/{game.id}/tracks/12"
    start = threading.Thread(target=lambda: started.append(client.post(jobs_url, json={"kind": "analyze"})))
    fix = threading.Thread(target=lambda: fixed.append(client.put(track_url, json={"player_id": "p_s1"})))
    start.start()
    try:
        assert queueing.wait(10)
        fix.start()
        fix.join(0.5)
        assert fix.is_alive()  # it waits for the ANALYZE to be queued
    finally:
        go_on.set()
        start.join(10)
        fix.join(10)
    assert started[0].status_code == 201 and started[0].json()["kind"] == JobKind.ANALYZE
    error = fixed[0].json()["error"]
    assert fixed[0].status_code == 409 and error["code"] == "CONFLICT"
    assert error["detail"] == f"active job {started[0].json()['id']} (analyze, queued)"
    assert db.list_track_overrides(game.id) == []


def test_head_on_the_liveness_route_takes_no_notice_of_credentials(auth_headers):
    """An uptime monitor that sends HEAD with the coaches' login, or an old one, every minute: no device
    cookie, and no failed sign-ins that would lock out its address (a school's NAT, shared with coaches)."""
    stale = {"Authorization": "Basic " + base64.b64encode(b"coach:last-seasons-password").decode()}
    with TestClient(create_app()) as c:
        r = c.head(LIVE, headers=auth_headers)
        assert r.status_code == 200 and r.content == b"" and "set-cookie" not in r.headers
        for _ in range(12):  # more than the ten failures that lock an address out
            r = c.head(LIVE, headers=stale)
            assert r.status_code == 200 and "set-cookie" not in r.headers
        assert c.get("/api/health", headers=auth_headers).status_code == 200  # not 429


@pytest.mark.parametrize("method", ["POST", "PUT", "DELETE"])
def test_a_405_on_the_liveness_route_still_says_it_answers_get(client, method):
    """The HEAD route was registered first, so a wrong method there was told "Allow: HEAD", as if GET were gone."""
    r = client.request(method, LIVE)
    assert r.status_code == 405
    assert "GET" in [allowed.strip() for allowed in r.headers["allow"].split(",")]
