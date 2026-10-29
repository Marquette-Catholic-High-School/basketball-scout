"""Regression tests from the verification of the fourth frontend review round.

They run the real pages in the node fake-DOM harness of ``tests/test_review_frontend.py`` with
the Roster page routes of ``tests/test_review3_frontend.py`` and ``tests/test_review4_frontend.py``.
The seam tests take their answers from the real API and an in-process worker (demo mode), so the
pages meet the server's own 409, job and game bodies.
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from scout import config
from scout.analysis import pipeline
from scout.errors import ErrorCode, ScoutError
from scout.main import create_app
from scout.processing.base import PollResult
from scout.worker import Worker
from tests.test_review3_frontend import ROSTER_TRACKS_JS, SMITH_SET_BY_COACH_JS, SMITH_TRACK_JS
from tests.test_review3_integration import _upload_film
from tests.test_review4_frontend import ANALYSIS_JS, CONFLICT_JS, WAIT_NOTICE
from tests.test_review_frontend import run_page


@pytest.fixture
def client(monkeypatch, auth_headers):
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    config.reset_settings()
    with TestClient(create_app()) as c:
        c.headers.update(auth_headers)
        yield c


# ---------------------------------------------------------------------------
# The Roster page's wait for a full analysis
# ---------------------------------------------------------------------------


def test_wait_rides_out_a_network_hiccup_and_stops_polling_when_the_analysis_ends(tmp_path):
    """Guard: the page keeps polling through failed checks (no network, a restarting server),
    unlocks when the ANALYZE ends, and then stops asking."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + f"""
setJob({{}});
let calls = 0;
let failures = 0;
route("GET", "/api/jobs/j_1", () => {{
  calls += 1;
  if (calls >= 2 && failures < 4) {{ // four checks in a row fail; the fifth would give up
    failures += 1;
    return failures % 2 ? {{ network: true }} : fail(503, "SERVER_UNAVAILABLE", "Server unavailable", {{ retryable: true }});
  }}
  return json(analysisJob);
}});
await load([{SMITH_TRACK_JS}]);
await pause(20);
const during = {{ wait: wait(), ...locked(), failures }};
setJob({{ status: "cancelled", stage: "done" }});
await settle();
const after = {{ wait: wait(), ...locked() }};
const polled = calls;
await pause(40);
await settle();
console.log(JSON.stringify({{ during, after, more: calls - polled }}));
""",
    )
    during = out["during"]
    assert during.pop("wait").startswith(WAIT_NOTICE)
    assert during == {"selects": [True], "save": True, "rerun": True, "failures": 4}
    assert out["after"] == {"wait": None, "selects": [False], "save": True, "rerun": False}
    assert out["more"] == 0  # no polling once the analysis has ended


def test_a_finished_full_analysis_as_the_latest_job_leaves_assignments_open(tmp_path):
    """Guard: only an ANALYZE that is queued or running locks the assignments; one that has
    finished is read once and not polled."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + f"""
setJob({{ status: "succeeded", stage: "done", progress: 100 }});
await load([{SMITH_TRACK_JS}]);
await pause(20);
console.log(JSON.stringify({{ wait: wait(), ...locked(), polls: server.log.filter((e) => e === "GET /api/jobs/j_1").length }}));
""",
    )
    assert out.pop("polls") <= 1  # looked at most once: no polling
    assert out == {"wait": None, "selects": [False], "save": True, "rerun": False}


def test_refused_rerun_message_goes_when_the_full_analysis_ends(tmp_path):
    """Re-run analysis refused (409) because an ANALYZE had started: the page waited for it, but
    when it ended the refusal ("This game's film is being analysed right now.") stayed at the
    top of the page beside the Re-run analysis button it had enabled again."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + f"""
route("POST", "/api/games/g_1/jobs", () => (analysisJob && ["queued", "running"].includes(analysisJob.status)
  ? fail(409, "CONFLICT", "Conflict", {{ message: "This game's film is being analysed right now." }})
  : json(job({{ kind: "reanalyze" }}), 201)));
await load([{SMITH_TRACK_JS}]);
$$("#roster-columns section")[0].querySelectorAll("button").find((b) => textOf(b) === "Save roster").click();
await settle();
setJob({{ status: "queued", stage: "queued" }});
byId("rerun-btn").click();
await settle();
const refused = {{ error: textOf($("#page-error .notice-title")), wait: wait() }};
setJob({{ status: "cancelled", stage: "done" }});
await settle();
console.log(JSON.stringify({{ refused, error: textOf(byId("page-error")), wait: wait(), ...locked() }}));
""",
    )
    assert out["refused"]["error"] == "Conflict"
    assert out["refused"]["wait"].startswith(WAIT_NOTICE)
    assert out["error"] == ""
    assert (out["wait"], out["selects"], out["rerun"]) == (None, [False], False)


def test_earlier_runs_tracks_go_when_the_analysis_ends_without_its_analysis(tmp_path):
    """ARCHITECTURE (Full re-analysis): installing the new run deletes the earlier run's
    analysis, "so no page shows the earlier run's track ids over the new tracking, also when
    that analysis fails". A job that fails after installing but before its stage says
    "analyzing" (a full disk while moving the overlay, a database error) ends at
    downloading_results; the page went by the stage only, so it kept the earlier run's table,
    with its cleared assignment and the choices kept after the 409, and unlocked them."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + CONFLICT_JS
        + f"""
let analysed = true;
route("GET", "/api/games/g_1", () => json(game(analysisJob ? {{ status: "processing", latest_job_id: "j_1", has_analysis: analysed }} : {{}})));
route("GET", "/api/games/g_1/tracks", () => json(analysed
  ? {{ assignments: [{SMITH_TRACK_JS}, assignment({{ track_id: 8, side: "other", team_id: 1 }})],
      overrides: [{{ track_id: 8, player_id: null, side: "other", ignore: false }}] }}
  : {{ assignments: [], overrides: [] }}));
await import("./js/roster.js");
await settle();
pickText(7, "Unknown player (Lincoln)");
setJob({{}});
byId("tracks-save").click();
await settle();
const refused = {{ wait: wait(), ...pending() }};
analysed = false;
setJob({{ status: "failed", stage: "downloading_results", error: {{ code: "INTERNAL_ERROR", title: "Something went wrong",
  message: "x", hint: null, retryable: true, detail: null }} }});
await settle();
console.log(JSON.stringify({{
  refused,
  tracksShown: !byId("tracks").hidden,
  rows: rows(),
  ...pending(),
  ...locked(),
}}));
""",
    )
    assert out["refused"]["wait"].startswith(WAIT_NOTICE)
    assert out["refused"]["note"] == "1 unsaved change"
    assert out["tracksShown"] is False
    assert out["rows"] == []
    assert (out["note"], out["saveDisabled"]) == ("", True)
    assert out["rerun"] is False


def test_refused_removal_of_an_assignment_keeps_the_choice_and_waits(tmp_path):
    """Guard: "Automatic" for a track the coach had assigned sends DELETE, which the server
    also refuses (409) while an ANALYZE is queued or running; the choice stays and the page
    waits, as for a refused PUT, and saves it once the analysis was cancelled."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + f"""
const deletes = [];
route("DELETE", "/api/games/g_1/tracks/7", () => {{
  deletes.push(analysisJob?.status ?? null);
  return analysisJob && ["queued", "running"].includes(analysisJob.status)
    ? fail(409, "CONFLICT", "Conflict", {{ message: "This game's film is being analysed on the GPU." }})
    : {{ status: 204 }};
}});
await load([{SMITH_SET_BY_COACH_JS}], [{{ track_id: 7, player_id: "p_1", side: "scouted", ignore: false }}]);
pickText(7, "Automatic (best jersey match)");
setJob({{}});
byId("tracks-save").click();
await settle();
const refused = {{ error: textOf($("#tracks-error .notice-title")), wait: wait(), shown: shown(7), ...pending(), ...locked() }};
setJob({{ status: "cancelled", stage: "done" }});
await settle();
const reopened = {{ wait: wait(), shown: shown(7), ...pending() }};
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ refused, reopened, deletes, navigatedTo: page.window.navigatedTo || null }}));
""",
    )
    refused = out["refused"]
    assert refused.pop("wait").startswith(WAIT_NOTICE)
    assert refused == {
        "error": "Conflict",
        "shown": "Automatic (best jersey match)",
        "note": "1 unsaved change",
        "saveDisabled": True,
        "changed": [7],
        "selects": [True],
        "save": True,
        "rerun": True,
    }
    assert out["reopened"] == {
        "wait": None,
        "shown": "Automatic (best jersey match)",
        "note": "1 unsaved change",
        "saveDisabled": False,
        "changed": [7],
    }
    assert out["deletes"] == ["running", "cancelled"]
    assert out["navigatedTo"] == "/games/g_1"


# ---------------------------------------------------------------------------
# Seams: the real server's answers through the pages
# ---------------------------------------------------------------------------


def _for_page(body: object, game_id: str) -> str:
    """A real API body as JS, with the game's id as the pages' fixtures name it (g_1)."""
    return json.dumps(body).replace(game_id, "g_1")


def test_the_real_servers_refusal_puts_the_roster_page_into_the_wait(tmp_path, client):
    """The Roster page against the real API: a full re-analysis queued after the page loaded,
    the server's own 409 for the track change (scout/api/tracks.py), its job and game bodies
    while it is queued and once the worker has finished it."""
    worker = Worker(worker_id="w-verify-frontend")
    game_id = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North"}).json()["id"]
    players = [{"jersey": str(n), "first_name": "Test", "last_name": f"Player {n}"} for n in (3, 10, 23)]
    for side in ("scouted", "other"):
        assert client.put(f"/api/games/{game_id}/rosters/{side}", json={"players": players}).status_code == 200
    first = _upload_film(client, game_id, auto_start=True)["job"]
    assert worker.run_once(timeout=2)
    before = {
        "game": client.get(f"/api/games/{game_id}").json(),
        "rosters": client.get(f"/api/games/{game_id}/rosters").json(),
        "tracks": client.get(f"/api/games/{game_id}/tracks").json(),
        "job": client.get(f"/api/jobs/{first['id']}").json(),
    }
    track = next(a for a in before["tracks"]["assignments"] if a["role"] == "player" and a["side"])
    track_id = track["track_id"]
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    body = {"track_id": track_id, "player_id": None, "side": track["side"], "ignore": False}
    refused = client.put(f"/api/games/{game_id}/tracks/{track_id}", json=body)
    assert refused.status_code == 409, refused.text
    during = {"game": client.get(f"/api/games/{game_id}").json(), "job": client.get(f"/api/jobs/{full['id']}").json()}
    assert worker.run_once(timeout=2)
    after = {
        "game": client.get(f"/api/games/{game_id}").json(),
        "job": client.get(f"/api/jobs/{full['id']}").json(),
        "tracks": client.get(f"/api/games/{game_id}/tracks").json(),
    }
    assert (after["job"]["status"], after["tracks"]["overrides"]) == ("succeeded", [])

    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        f"""
const before = {_for_page(before, game_id)};
const during = {_for_page(during, game_id)};
const after = {_for_page(after, game_id)};
const refused = {_for_page(refused.json(), game_id)};
let phase = "before";
const puts = [];
route("GET", "/api/games/g_1", () => json(({{ before, during, after }})[phase].game));
route("GET", "/api/games/g_1/rosters", json(before.rosters));
route("GET", "/api/games/g_1/tracks", () => json(phase === "after" ? after.tracks : before.tracks));
route("GET", "/api/jobs/" + before.job.id, json(before.job));
route("GET", "/api/jobs/" + during.job.id, () => json(phase === "after" ? after.job : during.job));
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {{ puts.push(req.body); return json(refused, 409); }});
await import("./js/roster.js");
await settle();
const select = $(`#tracks-body select[data-track="{track_id}"]`);
select.value = "__none"; // Unknown player (keep team)
fire(select, "change");
phase = "during";
byId("tracks-save").click();
await settle();
const wait = () => (byId("tracks-wait").hidden ? null : textOf(byId("tracks-wait")));
const seen = {{
  error: $("#tracks-error .notice-error")?.children.map(textOf),
  wait: wait(),
  locked: $$("#tracks-body select[data-track]").every((s) => s.disabled),
  unsaved: textOf(byId("tracks-unsaved")),
}};
phase = "after";
await settle();
console.log(JSON.stringify({{
  puts,
  seen,
  wait: wait(),
  rows: $$("#tracks-body tr[data-track]").map((tr) => Number(tr.dataset.track)).sort((a, b) => a - b),
  locked: $$("#tracks-body select[data-track]").some((s) => s.disabled),
  unsaved: textOf(byId("tracks-unsaved")),
}}));
""",
    )
    assert out["puts"] == [body]
    info = refused.json()["error"]
    assert out["seen"]["error"] == [info["title"], info["message"], info["hint"]]
    assert out["seen"]["wait"].startswith(WAIT_NOTICE)
    assert (out["seen"]["locked"], out["seen"]["unsaved"]) == (True, "1 unsaved change")
    assert out["wait"].startswith("Film analysis finished")  # the choice made for the earlier run's track went
    assert out["rows"] == sorted(a["track_id"] for a in after["tracks"]["assignments"])
    assert (out["locked"], out["unsaved"]) == (False, "")


def test_keep_team_from_the_page_keeps_the_team_through_the_real_analysis(tmp_path, client):
    """README (Rosters and jersey matching): "Unknown player (keep team) keeps the team the
    table shows." The page's own bodies for a track the coach had moved to the other team's
    player and for a referee, sent to the real server and re-analysed (matcher._apply_override):
    each track keeps the team the table showed, without a player."""
    worker = Worker(worker_id="w-verify-frontend")

    def run(job: dict) -> None:
        assert worker.run_once(timeout=2)
        assert client.get(f"/api/jobs/{job['id']}").json()["status"] == "succeeded"

    game_id = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North"}).json()["id"]
    players = [{"jersey": str(n), "first_name": "Test", "last_name": f"Player {n}"} for n in (3, 10, 23)]
    for side in ("scouted", "other"):
        assert client.put(f"/api/games/{game_id}/rosters/{side}", json={"players": players}).status_code == 200
    run(_upload_film(client, game_id, auto_start=True)["job"])
    assignments = client.get(f"/api/games/{game_id}/tracks").json()["assignments"]
    moved = next(a for a in assignments if a["role"] == "player" and a["side"] == "scouted")
    referee = next(a for a in assignments if a["role"] == "referee")
    north = client.get(f"/api/games/{game_id}/rosters").json()["other"]["players"][0]
    choice = {"track_id": moved["track_id"], "player_id": north["id"], "side": "other", "ignore": False}
    assert client.put(f"/api/games/{game_id}/tracks/{moved['track_id']}", json=choice).status_code == 200
    run(client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json())
    state = {
        "game": client.get(f"/api/games/{game_id}").json(),
        "rosters": client.get(f"/api/games/{game_id}/rosters").json(),
        "tracks": client.get(f"/api/games/{game_id}/tracks").json(),
    }
    shown = {a["track_id"]: a["side"] for a in state["tracks"]["assignments"]}
    assert (shown[moved["track_id"]], shown[referee["track_id"]]) == ("other", None)

    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        f"""
const state = {_for_page(state, game_id)};
route("GET", "/api/games/g_1", json(state.game));
route("GET", "/api/games/g_1/rosters", json(state.rosters));
route("GET", "/api/games/g_1/tracks", json(state.tracks));
route("GET", "/api/jobs/" + state.game.latest_job_id, json(job({{ id: state.game.latest_job_id, kind: "reanalyze", status: "succeeded", stage: "done" }})));
const puts = [];
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {{ puts.push(req.body); return json(req.body); }});
route("POST", "/api/games/g_1/jobs", json(job({{ kind: "reanalyze" }}), 201));
await import("./js/roster.js");
await settle();
for (const id of [{moved["track_id"]}, {referee["track_id"]}]) {{
  const select = $(`#tracks-body select[data-track="${{id}}"]`);
  select.value = "__none"; // Unknown player (keep team)
  fire(select, "change");
}}
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ puts }}));
""",
    )
    puts = sorted(out["puts"], key=lambda body: body["track_id"])
    assert [(body["track_id"], body["player_id"], body["side"]) for body in puts] == sorted(
        [(moved["track_id"], None, "other"), (referee["track_id"], None, None)]
    )
    for body in puts:
        assert client.put(f"/api/games/{game_id}/tracks/{body['track_id']}", json=body).status_code == 200
    run(client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json())
    after = {a["track_id"]: a for a in client.get(f"/api/games/{game_id}/tracks").json()["assignments"]}
    kept = [after[moved["track_id"]], after[referee["track_id"]]]
    assert [(a["side"], a["player_id"], a["method"]) for a in kept] == [
        ("other", None, "manual"),
        (None, None, "manual"),
    ]


def _failing(monkeypatch, worker: Worker, step: str, code: ErrorCode) -> None:
    """Make the worker's ANALYZE fail with ``code`` at ``step``."""

    def fail(*_args, **_kwargs):
        raise ScoutError(code)

    if step == "poll":
        monkeypatch.setattr(
            worker.processor, "poll", lambda _handle: PollResult(state="failed", error=ScoutError(code))
        )
    elif step == "fetch":
        monkeypatch.setattr(worker.processor, "fetch", fail)
    else:
        monkeypatch.setattr(pipeline, "analyze_game", fail)


@pytest.mark.parametrize(
    ("step", "code", "stage", "buttons", "retried_as"),
    [
        ("analyze", ErrorCode.CONFIG_INVALID, "analyzing", ["Re-run analysis"], "reanalyze"),
        ("analyze", ErrorCode.ANALYSIS_FAILED, "analyzing", ["Re-run analysis"], "reanalyze"),
        ("poll", ErrorCode.PIPELINE_FAILED, "gpu_processing", ["Retry"], "analyze"),
        ("fetch", ErrorCode.TRACKING_RESULT_INVALID, "downloading_results", [], None),
    ],
    ids=["config-error-after-the-gpu", "analysis-error-after-the-gpu", "gpu-failure", "bad-gpu-output"],
)
def test_job_panel_names_the_retry_the_server_makes_of_a_failed_analysis(
    tmp_path, client, monkeypatch, step, code, stage, buttons, retried_as
):
    """ARCHITECTURE (Job lifecycle, Retry): failed ANALYZE jobs as the worker leaves them, in the
    game page's job panel. "Re-run analysis" is offered exactly when the server's retry is a
    REANALYZE (the GPU results are saved), also for an error that is not retryable."""
    worker = Worker(worker_id="w-verify-frontend")
    _failing(monkeypatch, worker, step, code)
    game_id = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North"}).json()["id"]
    job = _upload_film(client, game_id, auto_start=True)["job"]
    assert worker.run_once(timeout=2)
    failed = client.get(f"/api/jobs/{job['id']}").json()
    game = client.get(f"/api/games/{game_id}").json()
    assert (failed["status"], failed["stage"], failed["error"]["code"]) == ("failed", stage, code)
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        f"""
const failed = {_for_page(failed, game_id)};
gamePageRoutes(route, json, {{ gameBody: {_for_page(game, game_id)}, jobs: [failed] }});
route("GET", "/api/jobs/" + failed.id, json(failed));
await import("./js/game.js");
await settle();
console.log(JSON.stringify({{ buttons: $$("#job-panel button").map(textOf) }}));
""",
    )
    assert out["buttons"] == buttons
    if retried_as:
        retried = client.post(f"/api/jobs/{job['id']}/retry")
        assert (retried.status_code, retried.json()["kind"]) == (200, retried_as)
