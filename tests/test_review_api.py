"""Regression tests from the API / auth / storage review.

Each test names the defect it pins down; see the review report for the details.
"""

from __future__ import annotations

import asyncio
import base64
import errno
import threading
import time
from datetime import UTC, datetime, timedelta

import anyio
import httpx
import pytest
from fastapi.testclient import TestClient

from scout import auth, config, db, storage
from scout.api import jobs, uploads
from scout.errors import ScoutError
from scout.export import fastscout
from scout.main import create_app
from scout.schemas import (
    BoxScoreLine,
    GameAnalysis,
    GameCreate,
    JobKind,
    JobStatus,
    PipelineInfo,
    PlayerRef,
    Roster,
    RosterPlayer,
    TeamBoxScore,
    TeamSide,
    TeamSummary,
)
from tests import helpers
from tests.test_api_support import fake_mp4, make_app, write_analysis, write_source_video

EVIL = "https://evil.example"


@pytest.fixture
def client(auth_headers):
    with TestClient(create_app(), headers=auth_headers) as c:
        yield c


# ---------------------------------------------------------------------------
# Cross-site request forgery: browsers resend the saved Basic credentials on a
# form or no-preflight fetch that another website submits.
# ---------------------------------------------------------------------------


def _import_roster(client: TestClient, game_id: str, headers: dict[str, str]):
    content = b"#,Name\n3,Jordan Smith\n"
    return client.post(
        f"/api/games/{game_id}/rosters/scouted/import",
        files={"file": ("roster.csv", content, "text/csv")},
        data={"mode": "replace"},
        headers=headers,
    )


@pytest.mark.parametrize(
    "headers",
    [
        {"Origin": EVIL},
        {"Origin": "null"},  # sandboxed iframe / data: URL
        {"Sec-Fetch-Site": "cross-site", "Origin": EVIL},
        {"Sec-Fetch-Site": "same-site", "Origin": "https://students.testserver"},
        {"Referer": f"{EVIL}/scouting-trap.html"},  # older browsers send no Origin on some POSTs
    ],
)
def test_cross_site_multipart_roster_import_is_blocked(client, game, headers):
    """A cross-site multipart form POST must not replace the coach's roster."""
    r = _import_roster(client, game.id, headers)
    assert r.status_code == 403, r.text
    assert r.json()["error"]["code"] == "CROSS_SITE_REQUEST"
    assert db.get_roster(game.id, TeamSide.SCOUTED).players == []


def test_cross_site_body_less_posts_are_blocked(client, game):
    """cancel / retry have no body, so the JSON content-type check never protected them."""
    write_source_video(game.id)
    job = client.post(f"/api/games/{game.id}/jobs", json={"kind": "analyze"}).json()
    r = client.post(f"/api/jobs/{job['id']}/cancel", headers={"Origin": EVIL, "Sec-Fetch-Site": "cross-site"})
    assert r.status_code == 403
    assert db.get_job(job["id"]).status == JobStatus.QUEUED
    db.update_job(job["id"], status=JobStatus.FAILED)
    r = client.post(f"/api/jobs/{job['id']}/retry", headers={"Origin": EVIL})
    assert r.status_code == 403
    assert len(db.list_jobs(game_id=game.id)) == 1


def test_same_origin_browser_requests_still_work(client, game):
    """What the real frontend sends: same-origin fetch / XHR (with or without Sec-Fetch-Site)."""
    same_origin = {"Origin": "http://testserver", "Sec-Fetch-Site": "same-origin"}
    assert _import_roster(client, game.id, same_origin).status_code == 200
    assert _import_roster(client, game.id, {"Origin": "http://testserver"}).status_code == 200
    assert _import_roster(client, game.id, {"Referer": "http://testserver/games/x/roster"}).status_code == 200
    r = client.post("/api/games", json={"scouted_team": "North"}, headers=same_origin)
    assert r.status_code == 201
    r = client.delete(f"/api/games/{r.json()['id']}", headers=same_origin)
    assert r.status_code == 204


def test_scripts_without_browser_headers_are_not_blocked(client, game):
    """curl and scripts send no Origin / Referer / Sec-Fetch-Site."""
    assert _import_roster(client, game.id, {}).status_code == 200


def test_safe_methods_are_never_blocked(client, game):
    r = client.get(f"/api/games/{game.id}", headers={"Origin": EVIL, "Sec-Fetch-Site": "cross-site"})
    assert r.status_code == 200


def test_proxy_that_drops_the_port_from_host_still_works(client, game):
    """nginx ``proxy_set_header Host $host`` drops a non-default port; Sec-Fetch-Site is absent
    in older browsers, so the Origin is compared by host name."""
    headers = {"Host": "scout.example.org", "Origin": "https://scout.example.org:8443"}
    assert _import_roster(client, game.id, headers).status_code == 200
    headers = {"Host": "scout.example.org:8000", "Origin": "https://scout.example.org:8443"}
    assert _import_roster(client, game.id, headers).status_code == 403  # the port was kept and differs


def test_proxy_that_rewrites_host_is_matched_by_forwarded_host(client, game):
    headers = {"Host": "127.0.0.1:8000", "X-Forwarded-Host": "scout.example.org", "Origin": "https://scout.example.org"}
    assert _import_roster(client, game.id, headers).status_code == 200


def test_cross_site_guard_applies_without_auth(monkeypatch, game):
    # localhost: with sign-in off an unknown name like "testserver" is refused before this check
    with TestClient(make_app(monkeypatch, SCOUT_AUTH_DISABLED="true"), base_url="http://localhost") as c:
        r = _import_roster(c, game.id, {"Origin": EVIL})
        assert r.status_code == 403 and r.json()["error"]["code"] == "CROSS_SITE_REQUEST"


def test_cross_site_requests_do_not_count_as_failed_sign_ins(game):
    """The guard runs before sign-in, so a hostile page cannot lock the coach out with forms."""
    with TestClient(create_app()) as c:
        for _ in range(15):
            r = c.post("/api/games", json={"scouted_team": "X"}, headers={"Origin": EVIL, "Authorization": "Basic Zm9vOmJhcg=="})
            assert r.status_code == 403


# ---------------------------------------------------------------------------
# New: GET /api/games/{id}/export/fastscout-notes?side=
# ---------------------------------------------------------------------------


def _line(jersey: str | None, name: str | None, player_id: str | None = None, **stats: int) -> BoxScoreLine:
    return BoxScoreLine(player=PlayerRef(player_id=player_id, jersey=jersey, name=name), minutes_est=20.0, **stats)


def _analysis_with_box_scores(game) -> GameAnalysis:
    def box(side: TeamSide, team: str, players: list[BoxScoreLine], unattributed: BoxScoreLine) -> TeamBoxScore:
        totals = BoxScoreLine(player=PlayerRef(name=team), pts=sum(p.pts for p in players) + unattributed.pts)
        return TeamBoxScore(side=side, team_name=team, players=players, team_unattributed=unattributed, totals=totals)

    return GameAnalysis(
        game_id=game.id,
        generated_at=datetime.now(UTC),
        video=helpers.video_info(),
        pipeline=PipelineInfo(name="test"),
        teams=[
            TeamSummary(side=TeamSide.SCOUTED, name=game.scouted_team, score=12),
            TeamSummary(side=TeamSide.OTHER, name=game.other_team, score=9),
        ],
        box_scores=[
            box(
                TeamSide.SCOUTED,
                game.scouted_team,
                [_line("3", "Jordan Smith", "p_s3", pts=10, fga=6, fgm=5), _line("14", None, pts=2, fga=1, fgm=1)],
                _line(None, None, pts=0),
            ),
            box(TeamSide.OTHER, game.other_team, [_line("5", "Sam Hill", pts=6, fga=4, fgm=3)], _line(None, None, pts=3, fga=1)),
        ],
    )


def _store_analysis(game, analysis: GameAnalysis) -> None:
    path = storage.analysis_path(game.id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(analysis.model_dump_json())


def test_fastscout_notes_needs_an_analysis(client, game):
    r = client.get(f"/api/games/{game.id}/export/fastscout-notes")
    assert r.status_code == 409 and r.json()["error"]["code"] == "ANALYSIS_NOT_READY"


def test_fastscout_notes_shape_and_side(client, game):
    """Real FastScout helpers on a real analysis file: warnings list + team numbers block."""
    db.save_roster(Roster(game_id=game.id, side=TeamSide.SCOUTED, players=[RosterPlayer(id="p_s3", jersey="3", first_name="Jordan", last_name="Smith")]))
    analysis = _analysis_with_box_scores(game)
    _store_analysis(game, analysis)

    r = client.get(f"/api/games/{game.id}/export/fastscout-notes")
    assert r.status_code == 200, r.text
    body = r.json()
    assert set(body) == {"warnings", "team_numbers"}
    assert body["warnings"] == fastscout.paste_block_warnings(analysis, game, TeamSide.SCOUTED)
    assert any("#14" in w for w in body["warnings"])  # the unrostered player is flagged
    assert body["team_numbers"] == fastscout.team_helper_block(analysis, TeamSide.SCOUTED)
    assert "Final score: Opponent HS 12, Rival HS 9" in body["team_numbers"]

    other = client.get(f"/api/games/{game.id}/export/fastscout-notes", params={"side": "other"}).json()
    assert other["team_numbers"].startswith("Rival HS:")
    assert any("could not be credited" in w for w in other["warnings"])  # 3 team points nobody got
    assert client.get(f"/api/games/{game.id}/export/fastscout-notes", params={"side": "home"}).status_code == 422


def test_fastscout_notes_passes_game_and_side_like_the_paste_block(client, game, monkeypatch):
    write_analysis(game, monkeypatch)
    calls = []

    def warnings(analysis, game_, side=TeamSide.SCOUTED, config=None, *, roster=None):
        calls.append(("warnings", analysis.game_id, game_.id, side, roster))
        return ["check #14"]

    def helper(analysis, side=TeamSide.SCOUTED):
        calls.append(("helper", analysis.game_id, side))
        return "Final score: ..."

    monkeypatch.setattr(fastscout, "paste_block_warnings", warnings)
    monkeypatch.setattr(fastscout, "team_helper_block", helper)
    r = client.get(f"/api/games/{game.id}/export/fastscout-notes", params={"side": "other"})
    assert r.json() == {"warnings": ["check #14"], "team_numbers": "Final score: ..."}
    assert calls == [("warnings", game.id, game.id, TeamSide.OTHER, None), ("helper", game.id, TeamSide.OTHER)]


def test_fastscout_notes_is_unknown_for_a_missing_game(client):
    assert client.get("/api/games/g_000000/export/fastscout-notes").status_code == 404



# ---------------------------------------------------------------------------
# Login throttle
# ---------------------------------------------------------------------------


def _basic(user: str, password: str) -> dict[str, str]:
    return {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()}


def test_parallel_guesses_cannot_outrun_the_lockout(monkeypatch):
    """With a password hash the check is slow and runs in a thread: a burst of parallel
    guesses used to pass the lockout check together, so all of them were tried."""
    monkeypatch.delenv("SCOUT_AUTH_PASSWORD")
    app = make_app(monkeypatch, SCOUT_AUTH_PASSWORD_HASH=auth.hash_password("right-pw", iterations=1000))
    tried: list[str] = []

    def slow_verify(password: str, encoded: str) -> bool:
        tried.append(password)
        time.sleep(0.02)
        return False

    monkeypatch.setattr(auth, "verify_password", slow_verify)

    async def burst() -> list[int]:
        transport = httpx.ASGITransport(app=app, client=("203.0.113.9", 4000))
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as c:
            guesses = [c.get("/api/games", headers=_basic("coach", f"guess-{i}")) for i in range(30)]
            return [r.status_code for r in await asyncio.gather(*guesses)]

    codes = asyncio.run(burst())
    assert len(tried) == 10  # the tenth wrong guess starts the lockout; nothing after it is tried
    assert codes.count(401) == 9 and codes.count(429) == 21


def test_ipv6_addresses_in_one_network_share_a_failure_limit(auth_headers):
    """An IPv6 /64 has billions of addresses: rotating them used to give unlimited guesses."""
    app = create_app()
    codes = []
    with TestClient(app) as probe:
        for i in range(40):  # 4 failures per address, never reaching the per-address limit
            attacker = TestClient(app, client=(f"2001:db8:5:7::{i // 4 + 1:x}", 4000))
            codes.append(attacker.get("/api/games", headers=_basic("coach", f"guess-{i}")).status_code)
        assert codes.count(401) == auth.NETWORK_MAX_FAILURES - 1 and codes[auth.NETWORK_MAX_FAILURES - 1 :] == [429] * 11
        # The whole /64 is locked, even an address that never failed...
        fresh = TestClient(app, client=("2001:db8:5:7::abcd", 4000))
        assert fresh.get("/api/games", headers=auth_headers).status_code == 429
        # ...but other networks, and IPv4, are not.
        assert TestClient(app, client=("2001:db8:5:8::1", 4000)).get("/api/games", headers=auth_headers).status_code == 200
        assert probe.get("/api/games", headers=auth_headers).status_code == 200


def test_one_ipv6_device_does_not_lock_out_its_network(auth_headers):
    """The per-address limit still applies first, so a coach on the same school network is fine."""
    app = create_app()
    attacker = TestClient(app, client=("2001:db8:5:7::66", 4000))
    coach = TestClient(app, client=("2001:db8:5:7::10", 4000))
    with attacker, coach:
        for _ in range(9):
            assert attacker.get("/api/games", headers=_basic("coach", "guess")).status_code == 401
        assert attacker.get("/api/games", headers=_basic("coach", "guess")).status_code == 429
        assert coach.get("/api/games", headers=auth_headers).status_code == 200


def test_ipv4_mapped_ipv6_is_counted_as_ipv4():
    assert auth._client_ip({"client": ("::ffff:198.51.100.7", 1)}) == "198.51.100.7"
    assert auth._client_ip({"client": ("198.51.100.7", 1)}) == "198.51.100.7"
    assert auth._client_ip({}) == "unknown"
    assert auth._client_network("2001:db8:5:7::66") == "2001:db8:5:7::/64"
    assert auth._client_network("198.51.100.7") is None


# ---------------------------------------------------------------------------
# Film replacement
# ---------------------------------------------------------------------------

OCTETS = {"Content-Type": "application/octet-stream"}


def _upload_film(client: TestClient, game_id: str, data: bytes) -> dict:
    upload = client.post(f"/api/games/{game_id}/uploads", json={"filename": "film.mp4", "size": len(data)}).json()
    r = client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=data, headers=OCTETS)
    assert r.status_code == 200, r.text
    return upload


def test_new_film_forgets_the_team_colour_choice_for_the_old_film(client, game):
    """Pipeline team ids are colour clusters of ONE film. The coach's choice for the old film
    used to survive a new upload/link, silently swapping the teams of the new film (and the
    "Which team is ...?" banner, shown only while the map is empty, never came back)."""
    old_choice = {0: TeamSide.OTHER, 1: TeamSide.SCOUTED}
    db.update_game(game.id, team_id_map=old_choice)
    upload = _upload_film(client, game.id, fake_mp4(3000))
    r = client.post(f"/api/uploads/{upload['id']}/complete", params={"auto_start": "false"})
    assert r.status_code == 200 and r.json()["game"]["team_id_map"] == {}
    assert db.get_game(game.id).team_id_map == {}

    db.update_game(game.id, team_id_map=old_choice)
    r = client.post(f"/api/games/{game.id}/video-url", params={"auto_start": "false"}, json={"url": "https://example.com/film.mp4"})
    assert r.status_code == 200 and r.json()["game"]["team_id_map"] == {}


# ---------------------------------------------------------------------------
# Job rules
# ---------------------------------------------------------------------------


def test_two_simultaneous_analysis_requests_queue_only_one_job(game, settings, monkeypatch):
    """A double click or a second tab: both requests used to pass the "one analysis at a
    time" check before either job existed, so two GPU runs were queued for one game."""
    write_source_video(game.id)
    first_inside = threading.Event()
    real_check = jobs._check_inputs_ready

    def slow_check(game_, kind, settings_):
        real_check(game_, kind, settings_)
        first_inside.set()
        time.sleep(0.3)

    monkeypatch.setattr(jobs, "_check_inputs_ready", slow_check)
    outcomes: list[str] = []

    def start() -> None:
        try:
            outcomes.append(jobs.start_job(db.require_game(game.id), JobKind.ANALYZE, {}, settings).id)
        except ScoutError as exc:
            outcomes.append(str(exc.code))

    first = threading.Thread(target=start)
    first.start()
    assert first_inside.wait(5)
    second = threading.Thread(target=start)
    second.start()
    first.join(5)
    second.join(5)
    assert len(db.active_jobs_for_game(game.id)) == 1
    assert sorted(outcomes, key=len)[0] == "CONFLICT"


# ---------------------------------------------------------------------------
# Chunk uploads: full disk, stalled connections
# ---------------------------------------------------------------------------


def test_disk_full_during_a_chunk_is_explained(auth_headers, game, monkeypatch):
    """ENOSPC used to surface as "Unexpected error" (retryable 500), so the upload page retried."""
    with TestClient(create_app(), headers=auth_headers, raise_server_exceptions=False) as c:
        upload = c.post(f"/api/games/{game.id}/uploads", json={"filename": "film.mp4", "size": 3000}).json()

        async def disk_full(self, data):
            raise OSError(errno.ENOSPC, "No space left on device")

        with monkeypatch.context() as patched:
            patched.setattr(anyio.AsyncFile, "write", disk_full)
            r = c.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=fake_mp4(3000), headers=OCTETS)
        assert r.status_code == 413, r.text
        error = r.json()["error"]
        assert error["code"] == "UPLOAD_TOO_LARGE" and "disk space" in error["message"]
        assert error["retryable"] is False
    assert db.get_upload(upload["id"]).received == 0
    assert storage.upload_part_path(upload["id"]).stat().st_size == 0


def test_a_stalled_chunk_gives_the_upload_back(auth_headers, game, monkeypatch):
    """uvicorn has no request-body timeout: a connection that died silently (Wi-Fi dropped)
    used to hold the upload's lock forever, so every resume of that upload hung too."""
    monkeypatch.setattr(uploads, "CHUNK_IDLE_TIMEOUT_S", 0.2)
    app = create_app()

    async def scenario() -> tuple[httpx.Response, httpx.Response, dict]:
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver", headers=auth_headers) as c:
            upload = (await c.post(f"/api/games/{game.id}/uploads", json={"filename": "f.mp4", "size": 300})).json()
            url = f"/api/uploads/{upload['id']}/chunk"

            async def stalls_after_100_bytes():
                yield b"x" * 100
                await asyncio.sleep(30)
                yield b"y" * 200

            stalled = await asyncio.wait_for(c.put(url, params={"offset": 0}, content=stalls_after_100_bytes(), headers=OCTETS), 5)
            resumed = await asyncio.wait_for(c.put(url, params={"offset": 0}, content=b"z" * 300, headers=OCTETS), 5)
            return stalled, resumed, upload

    stalled, resumed, upload = asyncio.run(scenario())
    # 409 + the session is what the upload page already treats as "resume from upload.received".
    assert stalled.status_code == 409 and stalled.json()["error"]["code"] == "UPLOAD_INCOMPLETE"
    assert stalled.json()["upload"]["received"] == 0
    assert resumed.status_code == 200 and resumed.json()["received"] == 300
    assert storage.upload_part_path(upload["id"]).read_bytes() == b"z" * 300


def _start(client: TestClient, game_id: str, size: int) -> dict:
    r = client.post(f"/api/games/{game_id}/uploads", json={"filename": "film.mp4", "size": size})
    assert r.status_code == 201, r.text
    return r.json()


def _make_idle(upload_id: str, hours: float) -> None:
    session = db.get_upload(upload_id)
    session = session.model_copy(update={"updated_at": db.utcnow() - timedelta(hours=hours)})
    with db.session() as conn:
        conn.execute("UPDATE uploads SET data = ? WHERE id = ?", (session.model_dump_json(), upload_id))


def test_abandoned_uploads_do_not_keep_their_partial_files(client, game):
    """Starting over ("Choose another file", another computer) left the old .part file
    (often gigabytes) on disk until the game was deleted."""
    data = fake_mp4(3000)
    abandoned = _start(client, game.id, len(data))
    client.put(f"/api/uploads/{abandoned['id']}/chunk", params={"offset": 0}, content=data[:1000], headers=OCTETS)
    _make_idle(abandoned["id"], hours=3)
    in_other_tab = _start(client, game.id, len(data))  # still active: must survive a new start

    current = _start(client, game.id, len(data))
    assert not storage.upload_part_path(abandoned["id"]).exists()
    assert db.get_upload(abandoned["id"]).status == "aborted"
    assert db.get_upload(in_other_tab["id"]).status == "open"

    client.put(f"/api/uploads/{current['id']}/chunk", params={"offset": 0}, content=data, headers=OCTETS)
    assert client.post(f"/api/uploads/{current['id']}/complete", params={"auto_start": "false"}).status_code == 200
    # The film was just replaced: the other unfinished attempt is moot and its space is freed.
    assert db.get_upload(in_other_tab["id"]).status == "aborted"
    assert not storage.upload_part_path(in_other_tab["id"]).exists()
    assert db.get_upload(current["id"]).status == "complete"
    r = client.put(f"/api/uploads/{in_other_tab['id']}/chunk", params={"offset": 0}, content=data, headers=OCTETS)
    assert r.status_code == 409


def test_uploads_of_other_games_are_left_alone(client, game):
    other = db.create_game(GameCreate(scouted_team="Other HS"))
    theirs = _start(client, other.id, 3000)
    _make_idle(theirs["id"], hours=3)
    _start(client, game.id, 3000)
    assert db.get_upload(theirs["id"]).status == "open"


# ---------------------------------------------------------------------------
# Input validation that used to end in a 500 or a broken GPU request
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "url",
    [
        "http://[::1/film.mp4",  # unclosed IPv6 literal: urlparse raises
        "https://example.com/film.mp4\nhttps://example.com/other.mp4",  # pasted two lines
        "https://example.com/vs north.mp4",  # urllib on the GPU worker refuses spaces...
        "https://example.com/Ma\u00f1ana.mp4",  # ...and cannot send non-ASCII characters
        "https://example.com/vs\u00a0north.mp4",  # a non-breaking space copied from a document
        "https://user@/film.mp4",  # no host
    ],
)
def test_bad_video_links_are_rejected_clearly(auth_headers, game, url):
    with TestClient(create_app(), headers=auth_headers, raise_server_exceptions=False) as c:
        r = c.post(f"/api/games/{game.id}/video-url", params={"auto_start": "false"}, json={"url": url})
    assert r.status_code == 422, r.text
    assert r.json()["error"]["code"] == "VALIDATION_FAILED"
    assert db.get_game(game.id).video_url is None


def test_a_good_video_link_is_still_accepted(client, game):
    r = client.post(f"/api/games/{game.id}/video-url", params={"auto_start": "false"}, json={"url": "  HTTPS://Films.example.com/vs%20north.mp4?sig=a+b  "})
    assert r.status_code == 200 and r.json()["game"]["video_url"] == "HTTPS://Films.example.com/vs%20north.mp4?sig=a+b"


def test_track_ids_beyond_sqlite_integers_are_a_validation_error(auth_headers, game):
    with TestClient(create_app(), headers=auth_headers, raise_server_exceptions=False) as c:
        r = c.put(f"/api/games/{game.id}/tracks/99999999999999999999", json={"ignore": True})
        assert r.status_code == 422 and r.json()["error"]["code"] == "VALIDATION_FAILED"
        assert c.delete(f"/api/games/{game.id}/tracks/99999999999999999999").status_code == 422


def test_pages_cannot_be_framed_by_other_sites(auth_headers, monkeypatch, tmp_path):
    """Without nginx (the default install) nothing stopped another site from framing a page
    and tricking the coach into clicking "Delete game" or "Re-run analysis"."""
    from scout.api import pages

    (tmp_path / "game.html").write_text("<html>game</html>")
    monkeypatch.setattr(pages, "STATIC_DIR", tmp_path)
    with TestClient(create_app(), headers=auth_headers) as c:
        # A page, the "not installed" placeholder, and the same page straight from /static.
        for path in ("/games/g_123", "/upload", "/static/game.html"):
            r = c.get(path)
            assert r.headers["content-security-policy"] == "frame-ancestors 'self'", path
            assert r.headers["cache-control"] == "no-cache"


def test_report_jobs_from_the_generic_jobs_route_get_the_report_limits(auth_headers, game, monkeypatch):
    """POST /jobs {"kind": "report"} used to hand any coach_focus (any length or type) to Claude."""
    write_analysis(game, monkeypatch)
    with TestClient(make_app(monkeypatch, ANTHROPIC_API_KEY="sk-ant-test"), headers=auth_headers) as c:
        url = f"/api/games/{game.id}/jobs"
        assert c.post(url, json={"kind": "report", "params": {"coach_focus": "x" * 2001}}).status_code == 422
        assert c.post(url, json={"kind": "report", "params": {"coach_focus": {"nested": 1}}}).status_code == 422
        r = c.post(url, json={"kind": "report", "params": {"coach_focus": "We play zone", "other": 1}})
        assert r.status_code == 201 and r.json()["params"] == {"coach_focus": "We play zone"}


# ---------------------------------------------------------------------------
# Verified (no change needed): pinned so they stay true
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", "/api/docs"),
        ("GET", "/api/openapi.json"),
        ("HEAD", "/api/health"),  # HEAD /api/health/live is open too since the fourth review
        ("OPTIONS", "/api/games"),
        ("GET", "/api/health/live/"),
        ("GET", "/static/index.html"),
        ("GET", "/api/games/g_123/export/fastscout-notes"),
    ],
)
def test_everything_but_the_liveness_probe_needs_sign_in(method, path):
    with TestClient(create_app()) as c:
        assert c.request(method, path).status_code == 401


def test_spoofed_forwarded_for_does_not_dodge_the_lockout(auth_headers):
    """uvicorn as deployed (--proxy-headers --forwarded-allow-ips 127.0.0.1) only believes
    X-Forwarded-For from nginx on this machine, and then only nginx's own last hop."""
    from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

    app = ProxyHeadersMiddleware(create_app(), trusted_hosts="127.0.0.1")
    direct = TestClient(app, client=("203.0.113.9", 4000))  # no nginx in front
    via_nginx = TestClient(app, client=("127.0.0.1", 4000))
    with direct, via_nginx:
        for i in range(10):
            spoof = {"X-Forwarded-For": f"10.0.0.{i}"}
            r = direct.get("/api/games", headers={**_basic("coach", "guess"), **spoof})
        assert r.status_code == 429
        for i in range(10):  # nginx appends the real client after whatever the client sent
            spoof = {"X-Forwarded-For": f"10.0.1.{i}, 198.51.100.7"}
            r = via_nginx.get("/api/games", headers={**_basic("coach", "guess"), **spoof})
        assert r.status_code == 429
        assert via_nginx.get("/api/games", headers={**auth_headers, "X-Forwarded-For": "198.51.100.8"}).status_code == 200


# ---------------------------------------------------------------------------
# Second review
# ---------------------------------------------------------------------------

SHARED_ADDRESS = ("203.0.113.50", 4000)  # every device behind one school NAT


def _lock_out_shared_address(app) -> None:
    with TestClient(app, client=SHARED_ADDRESS) as someone_else:
        codes = [someone_else.get("/api/games", headers=_basic("coach", f"guess-{i}")).status_code for i in range(10)]
    assert codes[-1] == 429


def test_a_signed_in_browser_is_not_locked_out_by_others_on_its_address(auth_headers):
    """A school NAT, or a router that loops the public address back inside, gives every
    device one address: anyone behind it used to be able to keep the coach locked out."""
    app = create_app()
    with TestClient(app, client=SHARED_ADDRESS) as coach:
        assert coach.get("/api/games", headers=auth_headers).status_code == 200  # signs in: gets the device cookie
        _lock_out_shared_address(app)
        assert coach.get("/api/games", headers=auth_headers).status_code == 200
        assert coach.get("/", headers=auth_headers).status_code in (200, 503)  # pages too (503: not installed)
        assert coach.get("/api/games", headers=_basic("coach", "typo")).status_code == 401  # still needs the password
    with TestClient(app, client=SHARED_ADDRESS) as new_browser:  # never signed in: the lockout applies
        assert new_browser.get("/api/games", headers=auth_headers).status_code == 429


def test_a_signed_in_browser_still_has_its_own_failure_limit(auth_headers):
    """A copied device cookie gives no extra guesses: after ten failures it is an ordinary browser."""
    app = create_app()
    with TestClient(app, client=SHARED_ADDRESS) as browser:
        assert browser.get("/api/games", headers=auth_headers).status_code == 200
        codes = [browser.get("/api/games", headers=_basic("coach", f"guess-{i}")).status_code for i in range(10)]
        assert codes == [401] * 9 + [429]  # the failures counted for the address too, which is now locked
        assert browser.get("/api/games", headers=auth_headers).status_code == 429


def test_device_cookies_cannot_be_forged_or_kept_across_a_restart(auth_headers):
    with TestClient(create_app(), client=SHARED_ADDRESS) as browser:
        assert browser.get("/api/games", headers=auth_headers).status_code == 200
        genuine = browser.cookies[auth.DEVICE_COOKIE]
    device, _, tag = genuine.partition(".")
    restarted = create_app()  # a new process has a new cookie key
    _lock_out_shared_address(restarted)
    for cookie in (genuine, f"{device}.{'0' * len(tag)}", f"{device}.", "garbage"):
        with TestClient(restarted, client=SHARED_ADDRESS, cookies={auth.DEVICE_COOKIE: cookie}) as c:
            assert c.get("/api/games", headers=auth_headers).status_code == 429, cookie


def test_device_cookie_is_set_once_and_never_readable_by_scripts(auth_headers):
    with TestClient(create_app()) as c:
        assert "set-cookie" not in c.get("/api/games").headers  # not signed in: no cookie
        assert "set-cookie" not in c.get("/api/games", headers=_basic("coach", "wrong")).headers
        cookie = c.get("/api/games", headers=auth_headers).headers["set-cookie"]
        assert cookie.startswith(f"{auth.DEVICE_COOKIE}=")
        for attribute in ("Path=/", "HttpOnly", "SameSite=Lax"):
            assert attribute in cookie
        assert "Secure" not in cookie  # plain http: a Secure cookie would never come back
        assert "set-cookie" not in c.get("/api/games", headers=auth_headers).headers  # the browser keeps it
    with TestClient(create_app(), base_url="https://testserver") as c:
        assert "Secure" in c.get("/api/games", headers=auth_headers).headers["set-cookie"]


@pytest.mark.parametrize("url", ["http://example.com:99999/film.mp4", "http://example.com:abc/film.mp4"])
def test_video_links_with_an_impossible_port_are_rejected(client, game, url):
    """The GPU worker's downloader cannot connect to these: a GPU job used to start and then fail."""
    r = client.post(f"/api/games/{game.id}/video-url", params={"auto_start": "false"}, json={"url": url})
    assert r.status_code == 422, r.text
    assert r.json()["error"]["code"] == "VALIDATION_FAILED"
    assert db.get_game(game.id).video_url is None


def test_a_video_link_frees_the_space_of_unfinished_uploads(client, game):
    """The link replaces the film like a finished upload does; a half-sent file used to stay
    on disk (often gigabytes) until the game was deleted, and could later replace the link."""
    data = fake_mp4(3000)
    upload = _start(client, game.id, len(data))
    client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 0}, content=data[:1000], headers=OCTETS)
    r = client.post(f"/api/games/{game.id}/video-url", params={"auto_start": "false"}, json={"url": "https://example.com/film.mp4"})
    assert r.status_code == 200, r.text
    assert not storage.upload_part_path(upload["id"]).exists()
    assert db.get_upload(upload["id"]).status == "aborted"
    r = client.put(f"/api/uploads/{upload['id']}/chunk", params={"offset": 1000}, content=data[1000:], headers=OCTETS)
    assert r.status_code == 409


def test_analysis_jobs_that_write_the_report_get_the_coach_focus_limits(client, game):
    """REANALYZE with {"report": true}, and ANALYZE when auto-report is on, hand
    params.coach_focus to Claude as well; only kind=report was checked."""
    write_source_video(game.id)
    tracking = storage.tracking_path(game.id)
    tracking.write_bytes(b"{}")
    url = f"/api/games/{game.id}/jobs"
    r = client.post(url, json={"kind": "reanalyze", "params": {"report": True, "coach_focus": "x" * 2001}})
    assert r.status_code == 422 and r.json()["error"]["code"] == "VALIDATION_FAILED"
    assert client.post(url, json={"kind": "analyze", "params": {"coach_focus": ["not", "text"]}}).status_code == 422
    assert db.list_jobs(game_id=game.id) == []
    r = client.post(url, json={"kind": "reanalyze", "params": {"report": True, "coach_focus": "We play zone"}})
    assert r.status_code == 201 and r.json()["params"] == {"report": True, "coach_focus": "We play zone"}


def test_no_job_can_start_on_the_old_film_while_an_upload_completes(client, game, monkeypatch):
    """Completing an upload checks "no analysis running", then reads the film's length
    (ffprobe, up to a minute), then deletes the old film and its tracking. A re-run
    started from another tab in between used to run on the old film's data, and the
    upload then failed with 409 after the old film was already gone."""
    write_source_video(game.id, b"old film" + fake_mp4(3000))
    tracking = storage.tracking_path(game.id)
    tracking.write_bytes(b"old tracking")
    data = fake_mp4(3000)
    upload = _upload_film(client, game.id, data)
    rerun: list[str] = []

    def probe_while_another_tab_reruns(path):
        rerun.append(jobs.start_job(db.require_game(game.id), JobKind.REANALYZE, {}, config.get_settings()).id)
        return None

    monkeypatch.setattr(uploads, "probe_duration_s", probe_while_another_tab_reruns)
    r = client.post(f"/api/uploads/{upload['id']}/complete")
    assert r.status_code == 409 and r.json()["error"]["code"] == "CONFLICT"
    # The re-run got the film it was started on; the new film waits, ready to complete later.
    assert tracking.read_bytes() == b"old tracking"
    assert storage.find_source_video(game.id).read_bytes().startswith(b"old film")
    assert db.get_upload(upload["id"]).status == "open" and storage.upload_part_path(upload["id"]).is_file()
    assert [job.id for job in db.active_jobs_for_game(game.id)] == rerun


def test_the_coachs_requests_do_not_wipe_out_someone_elses_failures(auth_headers):
    """Every successful request used to reset its address's failure count, so on a shared
    address someone could guess without end while the coach's page polled for progress."""
    app = create_app()
    with TestClient(app, client=SHARED_ADDRESS) as coach, TestClient(app, client=SHARED_ADDRESS) as guesser:
        codes = []
        for i in range(30):
            assert coach.get("/api/games", headers=auth_headers).status_code == 200  # progress polling
            codes.append(guesser.get("/api/games", headers=_basic("coach", f"guess-{i}")).status_code)
        assert codes[:9] == [401] * 9 and set(codes[9:]) == {429}
        assert coach.get("/api/games", headers=auth_headers).status_code == 200


def test_video_is_revalidated_so_a_replaced_film_is_never_played_from_the_browser_cache(client, game):
    """The film and overlay URLs stay the same when the film is replaced or re-analysed, and
    Last-Modified without Cache-Control let browsers reuse old bytes for hours (heuristic
    freshness), so the page could play the old film, or a mix of both, against the new timeline."""
    path = write_source_video(game.id, b"old" + fake_mp4(3000))
    annotated = storage.annotated_video_path(game.id)
    annotated.write_bytes(fake_mp4(2000))
    for variant in ("original", "annotated"):
        r = client.get(f"/api/games/{game.id}/video", params={"variant": variant}, headers={"Range": "bytes=0-99"})
        assert r.status_code == 206 and r.headers["cache-control"] == "no-cache", variant
    old_etag = client.get(f"/api/games/{game.id}/video", headers={"Range": "bytes=0-9"}).headers["etag"]
    path.write_bytes(b"new" + fake_mp4(4000))
    r = client.get(f"/api/games/{game.id}/video", headers={"Range": "bytes=0-9", "If-Range": old_etag})
    assert r.status_code == 200 and r.content.startswith(b"new")  # revalidation sees the new film
