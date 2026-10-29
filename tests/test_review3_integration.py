"""Third review round, integration: the seams between the areas.

* The upload page leaves a video link's file name to the server, so a long one is cut to 255
  characters keeping its extension (docs/ARCHITECTURE.md "New film") instead of being refused.
* New film also deletes what a download of the old film's results that was cut short left in
  the game's download folder.
* A game's whole job flow through the real API and an in-process worker (demo mode): track
  overrides, team colours, the calibration and the overlay flag change as the docs say.
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from scout import config, db, storage
from scout.analysis import pipeline
from scout.errors import ErrorCode, ScoutError
from scout.main import create_app
from scout.schemas import GameStatus, JobKind, JobStage, JobStatus, TeamSide
from scout.worker import Worker
from tests.test_review_frontend import run_page


def _fake_mp4(size: int = 4096) -> bytes:
    head = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 12
    return head + b"\x11" * (size - len(head))


@pytest.fixture
def client(monkeypatch, auth_headers):
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    config.reset_settings()
    with TestClient(create_app()) as c:
        c.headers.update(auth_headers)
        yield c


def _upload_film(client: TestClient, game_id: str, *, auto_start: bool) -> dict:
    data = _fake_mp4()
    r = client.post(f"/api/games/{game_id}/uploads", json={"filename": "vs-central.mp4", "size": len(data)})
    assert r.status_code == 201, r.text
    upload = r.json()
    r = client.put(
        f"/api/uploads/{upload['id']}/chunk",
        params={"offset": 0},
        content=data,
        headers={"Content-Type": "application/octet-stream"},
    )
    assert r.status_code == 200, r.text
    r = client.post(f"/api/uploads/{upload['id']}/complete", params={"auto_start": str(auto_start).lower()})
    assert r.status_code == 200, r.text
    return r.json()


# --- the upload page's video link -------------------------------------------------------------


def _link_request_from_the_upload_page(tmp_path, url: str) -> dict:
    """What the real upload page posts when the coach pastes ``url`` (the fake server answers)."""
    return run_page(
        tmp_path,
        "upload.html",
        "/upload?game=g_1",
        """
route("GET", "/api/health", json({ status: "ok", max_upload_bytes: 1e12 }));
route("GET", "/api/games/g_1", json(game({ has_video: false, has_analysis: false, status: "draft" })));
let sent = null;
route("POST", "/api/games/g_1/video-url", (req) => {
  sent = { body: req.body, query: req.query };
  return json({ game: game({ has_video: false, video_url: req.body.url, status: "queued" }), job: job() });
});
await import("./js/upload.js");
await settle();
byId("f-url").value = __URL__;
fire(byId("url-form"), "submit");
await settle();
console.log(JSON.stringify({ ...sent, error: textOf(byId("url-error")), navigatedTo: page.window.navigatedTo || null }));
""".replace("__URL__", json.dumps(url)),
    )


@pytest.mark.parametrize(
    ("name", "stored"),
    [
        pytest.param("x" * 300 + ".mp4", "x" * 251 + ".mp4", id="long-name"),
        pytest.param("vs%20north.mp4", "vs north.mp4", id="short-name"),  # guard: named as before
    ],
)
def test_the_upload_page_lets_the_server_name_a_link_film(tmp_path, client, game, name, stored):
    """The page sent the link's decoded name itself, so set_video_url's 255-character cut never ran
    for links added from the page: a longer name answered 422 "Some fields are invalid" and the
    coach could not use the link at all."""
    url = f"https://films.example.com/2026/{name}?sig=1"
    page = _link_request_from_the_upload_page(tmp_path, url)
    assert page["error"] == "" and page["navigatedTo"] == "/games/g_1"
    assert page["query"] == {"auto_start": "true"}

    # The same request, as the real server answers it.
    r = client.post(f"/api/games/{game.id}/video-url", params={"auto_start": "false"}, json=page["body"])
    assert r.status_code == 200, r.text
    assert r.json()["game"]["video_filename"] == stored
    assert r.json()["game"]["video_url"] == url


# --- new film and the download folder ---------------------------------------------------------


@pytest.mark.parametrize("new_film", ["upload", "link"])
def test_new_film_deletes_a_download_of_the_old_films_results_that_was_cut_short(client, game, new_film):
    """The worker downloads an ANALYZE's results into the game's .incoming folder. One killed in the
    middle (a restart during a 1.5 GB overlay download) and then cancelled leaves the partial files
    there; a new film deleted the old film's tracking and overlay but kept those for good."""
    _upload_film(client, game.id, auto_start=False)
    leftover = storage.game_dir(game.id) / ".incoming"  # storage.incoming_dir
    leftover.mkdir()
    (leftover / "tracking.json.gz").write_bytes(b"the old film's results")
    (leftover / ".annotated.mp4.k3j2.part").write_bytes(b"half an overlay")

    if new_film == "upload":
        _upload_film(client, game.id, auto_start=False)
    else:
        r = client.post(
            f"/api/games/{game.id}/video-url",
            params={"auto_start": "false"},
            json={"url": "https://films.example.com/vs-north.mp4"},
        )
        assert r.status_code == 200, r.text

    assert not leftover.exists()
    assert storage.game_dir(game.id).is_dir()  # the folder itself stays (with the new film, if uploaded)


# --- a game's job flow through the API and the worker -----------------------------------------


def _player_track(client: TestClient, game_id: str) -> dict:
    tracks = client.get(f"/api/games/{game_id}/tracks").json()
    return next(a for a in tracks["assignments"] if a["role"] == "player" and a["player_id"])


def _overrides(client: TestClient, game_id: str) -> list[dict]:
    return client.get(f"/api/games/{game_id}/tracks").json()["overrides"]


def test_a_games_job_flow_keeps_its_fixes_as_documented(client, monkeypatch):
    """Upload -> analysis -> a track fix and the team colours -> Re-run analysis keeps the fix ->
    calibration -> Full re-analysis (the calibration goes to the GPU; the fix goes, the team colours
    and the calibration stay) -> a failure after the GPU and its Retry (a re-analysis that keeps a fix
    made for the new run) -> cancel while queued -> new film (everything from the old film goes)."""
    worker = Worker(worker_id="w-integration")
    submitted: list[dict] = []
    real_submit = worker.processor.submit

    def submit(*, job_id, video, options):
        submitted.append(options)
        return real_submit(job_id=job_id, video=video, options=options)

    monkeypatch.setattr(worker.processor, "submit", submit)

    def run(job: dict) -> dict:
        assert worker.run_once(timeout=2)
        done = client.get(f"/api/jobs/{job['id']}").json()
        assert done["status"] != JobStatus.RUNNING
        return done

    game_id = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North"}).json()["id"]
    first = _upload_film(client, game_id, auto_start=True)["job"]
    assert run(first)["status"] == JobStatus.SUCCEEDED

    # The Roster page's "Unknown player (North)" for a matched track, and the team colours.
    track = _player_track(client, game_id)
    fix = {"track_id": track["track_id"], "player_id": None, "side": "other", "ignore": False}
    assert client.put(f"/api/games/{game_id}/tracks/{track['track_id']}", json=fix).status_code == 200
    team_map = {"0": TeamSide.OTHER.value, "1": TeamSide.SCOUTED.value}
    assert client.patch(f"/api/games/{game_id}", json={"team_id_map": team_map}).status_code == 200
    rerun = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json()
    assert run(rerun)["status"] == JobStatus.SUCCEEDED
    assigned = {a["track_id"]: a for a in client.get(f"/api/games/{game_id}/tracks").json()["assignments"]}
    assert (assigned[track["track_id"]]["side"], assigned[track["track_id"]]["method"]) == ("other", "manual")
    assert _overrides(client, game_id) == [fix]

    # Calibration clicked on a 1280x720 copy, then a Full re-analysis.
    landmarks = list(client.get("/api/court/landmarks").json()["landmarks"])[:4]
    points = [{"landmark": name, "px": [100.0 + 300 * (i % 2), 200.0 + 250 * (i // 2)]} for i, name in enumerate(landmarks)]
    body = {"points": points, "frame_t": 12.0, "video_width": 1280, "video_height": 720}
    calibration = client.put(f"/api/games/{game_id}/calibration", json=body)
    assert calibration.status_code == 200, calibration.text
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    assert run(full)["status"] == JobStatus.SUCCEEDED
    sent = submitted[-1]["calibration"]
    assert (sent["matrix"], sent["video_width"], sent["video_height"]) == (calibration.json()["matrix"], 1280, 720)
    stored = client.get(f"/api/games/{game_id}").json()
    assert _overrides(client, game_id) == []  # the new run numbered its tracks anew
    assert stored["team_id_map"] == team_map and stored["calibration"] == calibration.json()
    assert (stored["status"], stored["has_analysis"], stored["has_annotated_video"]) == ("ready", True, False)

    # A failure after the GPU: Retry re-analyses the installed tracking, keeping the fix made for it.
    calls = {"n": 0}
    real_analyze = pipeline.analyze_game

    def analyze_once_failing(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise ScoutError(ErrorCode.ANALYSIS_FAILED, detail="test")
        return real_analyze(*args, **kwargs)

    monkeypatch.setattr(pipeline, "analyze_game", analyze_once_failing)
    failing = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    failed = run(failing)
    assert (failed["status"], failed["stage"], failed["error"]["retryable"]) == ("failed", JobStage.ANALYZING, True)
    assert client.get(f"/api/games/{game_id}").json()["status"] == GameStatus.FAILED
    new_fix = {"track_id": track["track_id"], "player_id": None, "side": None, "ignore": True}
    assert client.put(f"/api/games/{game_id}/tracks/{track['track_id']}", json=new_fix).status_code == 200
    retried = client.post(f"/api/jobs/{failing['id']}/retry").json()
    assert retried["kind"] == JobKind.REANALYZE
    assert run(retried)["status"] == JobStatus.SUCCEEDED
    assert len(submitted) == 3  # the retry sent nothing to the GPU
    assert _overrides(client, game_id) == [new_fix]
    assert client.get(f"/api/games/{game_id}").json()["status"] == GameStatus.READY

    # Cancelled while queued: at once, and the game is ready again.
    queued = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    assert client.get(f"/api/games/{game_id}").json()["status"] == GameStatus.QUEUED
    assert client.post(f"/api/jobs/{queued['id']}/cancel").json()["status"] == JobStatus.CANCELLED
    assert client.get(f"/api/games/{game_id}").json()["status"] == GameStatus.READY
    assert not worker.run_once(timeout=0.2)

    # New film: the old film's tracks, team colours and calibration mean nothing for it.
    r = client.post(
        f"/api/games/{game_id}/video-url", params={"auto_start": "false"}, json={"url": "https://films.example.com/g2.mp4"}
    )
    assert r.status_code == 200, r.text
    stored = r.json()["game"]
    assert (stored["status"], stored["has_video"], stored["has_analysis"]) == ("uploaded", False, False)
    assert (stored["team_id_map"], stored["calibration"], stored["has_annotated_video"]) == ({}, None, False)
    assert _overrides(client, game_id) == []
    assert db.list_track_overrides(game_id) == []
    assert not storage.tracking_path(game_id).exists() and not storage.analysis_path(game_id).exists()
