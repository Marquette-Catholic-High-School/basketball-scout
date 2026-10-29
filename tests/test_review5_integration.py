"""Fifth review round, integration: the seams between the Roster page and the game page's panels.

Everything here goes through the real API with an in-process worker in demo mode (the mock processor,
the real analysis, Claude faked: ``tests/test_review4_integration.py``). The pages run in the node
fake-DOM harness of ``tests/test_review_frontend.py`` with the server's own bodies, and what they send
is replayed on that server.

* Two tabs: the Roster page in tab A has unsaved track choices when the game page in tab B starts a
  Full re-analysis (the header's button, the calibration result's, or Start again after cancelling
  one). Tab A saves while it runs (refused, the page waits), after it succeeded (nothing is sent, the
  new table), after it failed after its install (no table, a notice that can be seen) or after it was
  cancelled before its install (the save goes ahead). README "Rosters and jersey matching" and "Court
  calibration"; docs/ARCHITECTURE.md "Job lifecycle" and "Extra rules" (Full re-analysis).
* After the coach accepted the late-cancel question ("Too late to cancel: ... The job will finish on
  its own"), the job panel said "Cancelling…" three times for the rest of the analysis or report.
* The calibration result's buttons follow the page's busy state, as the header's and the Data quality
  tab's do: Re-run analysis stayed enabled while the job it had started ran (a click got the server's
  409 as a page error), and Full re-analysis stayed disabled after it was clicked, also once the
  analysis had ended or when it did not start.
* A Roster page waiting for a full analysis that failed after its install hid the table it had said
  would update, without a word, when no choices were pending.
"""

from __future__ import annotations

import json
from typing import Any

import pytest

from scout.errors import ErrorCode
from tests.test_review2_frontend import CALIBRATION_JS, GAME_JS
from tests.test_review3_integration import _upload_film
from tests.test_review4_integration import (  # noqa: F401 - the scout fixture
    GAME_PAGE_JS,
    LATE_CANCEL,
    LATE_CANCEL_REPORT_SKIPPED,
    _analysed_game,
    _bodies,
    _failing_once,
    _for_page,
    _new_game,
    _run,
    scout,
)
from tests.test_review_frontend import run_page

KEEP_TEAM = "__none"  # Unknown player (keep team)
NOT_A_PLAYER = "__ignore"  # Not a player (referee, coach, fan…)
STOP_QUESTION = "Stop this job? You can start it again later."
FREE_THROWS = {"code": "FREE_THROWS_NOT_DETECTED", "message": "Free throws were not detected", "severity": "warning"}


def _tracking(assignment: dict) -> tuple:
    """What a track has from the GPU run alone (the Roster page's comparison)."""
    return (assignment["track_id"], assignment["frames"], assignment["team_id"], assignment["best_read"])


def _numbered_again(before: dict, now: dict) -> bool:
    """The new run uses some of the earlier run's track numbers for other tracks."""
    old = {a["track_id"]: a for a in before["tracks"]["assignments"]}
    new = {a["track_id"]: a for a in now["tracks"]["assignments"]}
    return any(_tracking(old[i]) != _tracking(new[i]) for i in old.keys() & new.keys())


def _is_full_run_question(question: str) -> bool:
    """The Full re-analysis button's question, for a page that shows results (game.js fullRunConfirm)."""
    return (
        question.startswith("Send the film to the GPU again?")
        and "The current results stay on this page until it finishes." in question
        and "it clears the track assignments you made on the Roster page" in question
    )


# ---------------------------------------------------------------------------
# The two pages, fed the real server's bodies
# ---------------------------------------------------------------------------

# Tab A, the Roster page: ``phases`` holds what the server answers at page load ("loaded"), when Save &
# re-run is clicked ("atSave") and, for a wait, once the analysis has ended ("after"); a phase's
# ``refusal`` is the server's 409 for a track change. The coach makes CHOICES, then each of STEPS is
# [name, phase, button to click or null]; ``looks`` has what the page shows after each, with the
# requests it sent meanwhile (repeated polls once).
ROSTER_TAB_JS = """
let phase = "loaded";
const now = () => phases[phase];
const sent = [];
route("GET", "/api/games/g_1", () => json(now().game));
route("GET", "/api/games/g_1/rosters", () => json(now().rosters));
route("GET", "/api/games/g_1/tracks", () => json(now().tracks));
route("GET", /^\\/api\\/jobs\\/[\\w-]+$/, (req) => {
  const body = now().jobs[req.path.split("/").pop()];
  return body ? json(body) : fail(404, "NOT_FOUND", "Not found");
});
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {
  sent.push(["PUT", req.path, req.body]);
  return now().refusal ? json(now().refusal, 409) : json(req.body);
});
route("DELETE", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => { sent.push(["DELETE", req.path, null]); return { status: 204 }; });
route("POST", "/api/games/g_1/jobs", (req) => { sent.push(["POST", req.path, req.body]); return json(job({ kind: req.body.kind }), 201); });
await import("./js/roster.js");
await settle();
for (const [id, value] of CHOICES) {
  const select = $(`#tracks-body select[data-track="${id}"]`);
  select.value = value;
  fire(select, "change");
}
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const look = () => ({
  rows: $$("#tracks-body tr[data-track]").map((tr) => Number(tr.dataset.track)).sort((a, b) => a - b),
  chosen: $$("#tracks-body select[data-track]").filter((s) => s.value !== "").map((s) => Number(s.dataset.track))
    .sort((a, b) => a - b),
  unsaved: textOf(byId("tracks-unsaved")),
  saveDisabled: byId("tracks-save").disabled,
  locked: $$("#tracks-body select[data-track]").some((s) => s.disabled),
  tableShown: !byId("tracks").hidden,
  notices: $$(".notice").filter(visible).map(textOf),
  links: $$("a").filter(visible).filter((a) => textOf(a) === "Open the game page").map((a) => a.getAttribute("href")),
});
const looks = { loaded: look() };
let mark = server.log.length;
for (const [name, next, click] of STEPS) {
  phase = next;
  if (click) byId(click).click();
  await settle();
  await settle();
  looks[name] = { ...look(), requests: server.log.slice(mark).filter((entry, i, all) => entry !== all[i - 1]) };
  mark = server.log.length;
}
console.log(JSON.stringify({ looks, sent, navigatedTo: page.window.navigatedTo || null }));
"""

# Tab B, the game page, on GAME_PAGE_JS (``phases.during``; job posts are recorded in ``posts`` and
# answered 503). ACTIONS are the coach's clicks; confirms are accepted. ``writes`` lists the other
# requests that change something (the calibration, a cancel).
GAME_TAB_JS = """
const writes = [];
route("GET", "/api/court/landmarks", json({ court: {}, landmarks }));
route("PUT", "/api/games/g_1/calibration", (req) => { writes.push(["PUT", req.path, req.body]); return json({ ...calibration, points: req.body.points }); });
route("POST", /^\\/api\\/jobs\\/j_[0-9a-f]+\\/cancel$/, (req) => { writes.push(["POST", req.path, null]); return json({ ...now().job, cancel_requested: true }); });
const button = (scope, text) => $$(`${scope} button`).find((b) => textOf(b) === text);
await import("./js/game.js");
await settle();
const looks = { loaded: look() };
for (const action of ACTIONS) {
  if (action === "full") byId("full-analysis-btn").click();
  if (action === "calibrate") {
    await openCalibration();
    for (const [x, y] of [[20, 300], [600, 300], [60, 40], [560, 40]]) clickFrame(x, y);
    byId("cal-save").click();
  }
  if (action === "calibrationFull") button("#cal-result", "Full re-analysis").click();
  if (action === "cancel") button("#job-panel", "Cancel").click();
  if (action === "startAgain") button("#job-panel", "Start again").click();
  await settle();
  looks[action] = look();
}
console.log(JSON.stringify({ looks, confirms, posts, writes }));
"""


def _roster_bodies(scout, game_id: str, refusal: dict | None = None) -> dict:  # noqa: F811
    """What the Roster page reads now (and the server's answer to a track change it refuses)."""
    client = scout.client
    return {
        "game": client.get(f"/api/games/{game_id}").json(),
        "rosters": client.get(f"/api/games/{game_id}/rosters").json(),
        "tracks": client.get(f"/api/games/{game_id}/tracks").json(),
        "jobs": {job["id"]: job for job in client.get(f"/api/games/{game_id}/jobs").json()},
        "refusal": refusal,
    }


def _roster_tab(tmp_path, game_id: str, phases: dict, choices: list, steps: list) -> dict:
    return run_page(
        tmp_path / "roster",
        "roster.html",
        "/games/g_1/roster",
        f"const phases = {_for_page(phases, game_id)};\n"
        f"const CHOICES = {json.dumps(choices)};\n"
        f"const STEPS = {json.dumps(steps)};\n" + ROSTER_TAB_JS,
    )


def _game_tab(tmp_path, game_id: str, bodies: dict, actions: list[str], *, free_throws_missing=False) -> dict:
    if free_throws_missing:  # a film whose court the GPU could not map: the calibration offers a Full re-analysis
        bodies = json.loads(json.dumps(bodies))
        bodies["analysis"]["data_quality"]["warnings"].append(FREE_THROWS)
    return run_page(
        tmp_path / "game",
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + f"const phases = {{ during: {_for_page(bodies, game_id)} }};\n"
        + GAME_PAGE_JS
        + f"const ACTIONS = {json.dumps(actions)};\n"
        + GAME_TAB_JS,
    )


def _replay(client, game_id: str, writes: list) -> list[int]:
    """Send what a page sent to the real server; its status codes."""
    return [
        client.request(method, path.replace("g_1", game_id), json=body).status_code for method, path, body in writes
    ]


def _start_full_reanalysis(tmp_path, scout, game_id: str, trigger: str) -> dict:  # noqa: F811
    """Tab B starts a Full re-analysis with ``trigger``; the page's requests, replayed. Returns the job."""
    client = scout.client
    latest = client.get(f"/api/games/{game_id}").json()["latest_job_id"]
    if trigger == "calibration":
        actions = ["calibrate", "calibrationFull"]
    else:
        actions = ["full"]
    out = _game_tab(tmp_path / "b1", game_id, _bodies(scout, game_id, latest), actions,
                    free_throws_missing=trigger == "calibration")
    [question] = out["confirms"]
    assert _is_full_run_question(question), question
    assert out["posts"] == [{"kind": "analyze"}]
    calibrated = [["PUT", "/api/games/g_1/calibration"]] if trigger == "calibration" else []
    assert [w[:2] for w in out["writes"]] == calibrated
    assert _replay(client, game_id, out["writes"]) == [200] * len(out["writes"])
    started = client.post(f"/api/games/{game_id}/jobs", json=out["posts"][0])
    assert started.status_code == 201, started.text
    full = started.json()
    if trigger != "start-again":
        return full
    # Tab B cancels it while it waits in the queue (stopped at once), then clicks Start again.
    out = _game_tab(tmp_path / "b2", game_id, _bodies(scout, game_id, full["id"]), ["cancel"])
    assert (out["looks"]["loaded"]["panelButtons"], out["confirms"]) == (["Cancel"], [STOP_QUESTION])
    assert out["writes"] == [["POST", f"/api/jobs/{full['id']}/cancel", None]]
    assert _replay(client, game_id, out["writes"]) == [200]
    assert client.get(f"/api/jobs/{full['id']}").json()["status"] == "cancelled"
    out = _game_tab(tmp_path / "b3", game_id, _bodies(scout, game_id, full["id"]), ["startAgain"])
    loaded = out["looks"]["loaded"]
    assert (loaded["panel"], loaded["panelButtons"]) == ("Film analysis was cancelled", ["Start again"])
    [question] = out["confirms"]
    assert _is_full_run_question(question), question  # the Full re-analysis button's own question
    assert out["posts"] == [{"kind": "analyze"}]
    started = client.post(f"/api/games/{game_id}/jobs", json=out["posts"][0])
    assert started.status_code == 201, started.text
    return started.json()


# ---------------------------------------------------------------------------
# Two tabs: a Full re-analysis from the game page, Save & re-run on a Roster page opened before it
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("trigger", "outcome"),
    [
        pytest.param("header", "running", id="header-save-while-it-runs"),
        pytest.param("calibration", "succeeded", id="calibration-save-after-it-succeeded"),
        pytest.param("start-again", "failed-after-install", id="start-again-save-after-it-failed-after-its-install"),
        pytest.param("header", "cancelled-before-install", id="header-save-after-it-was-cancelled-before-its-install"),
    ],
)
def test_two_tabs_full_reanalysis_from_the_game_page_and_save_on_the_roster_page(
    tmp_path, scout, monkeypatch, trigger, outcome  # noqa: F811
):
    """README (Rosters and jersey matching): "If the film was analysed again (a Full re-analysis, for example
    from another tab) since you opened the page, Save & re-run analysis shows the new table instead of
    saving"; README (Court calibration): the Roster page "locks them while it runs and takes new ones once it
    has finished", and "Cancelling it before its new results are in place keeps the earlier results". The game
    page in tab B asks the Full re-analysis question and posts an ANALYZE; the Roster page in tab A, opened
    before, then sends exactly what the server can take for the tracks it shows, and each page ends showing
    what the server holds."""
    client = scout.client
    game_id, fix = _analysed_game(scout)
    loaded = _roster_bodies(scout, game_id)  # tab A opens the Roster page on the first run
    keep, ignored = [a for a in loaded["tracks"]["assignments"]
                     if a["role"] == "player" and a["side"] and a["track_id"] != fix["track_id"]][:2]
    choices = [[keep["track_id"], KEEP_TEAM], [ignored["track_id"], NOT_A_PLAYER]]
    bodies = [  # what Save & re-run sends for those choices: "keep team" keeps the team the table shows
        {"track_id": keep["track_id"], "player_id": None, "side": keep["side"], "ignore": False},
        {"track_id": ignored["track_id"], "player_id": None, "side": ignored["side"], "ignore": True},
    ]
    gpu_runs = len(scout.gpu_runs)

    full = _start_full_reanalysis(tmp_path, scout, game_id, trigger)
    phases: dict[str, Any] = {"loaded": loaded}
    steps = [["saved", "atSave", "tracks-save"]]
    if outcome == "running":
        # Queued when tab A saves: the tracks are the same, so the page sends the change, which the server refuses.
        refused = client.put(f"/api/games/{game_id}/tracks/{keep['track_id']}", json=bodies[0])
        assert refused.status_code == 409, refused.text
        phases["atSave"] = _roster_bodies(scout, game_id, refused.json())
        assert _run(scout, full)["status"] == "succeeded"
        phases["after"] = _roster_bodies(scout, game_id)
        steps.append(["ended", "after", None])
    elif outcome == "succeeded":
        assert _run(scout, full)["status"] == "succeeded"
        phases["atSave"] = _roster_bodies(scout, game_id)
    elif outcome == "failed-after-install":
        _failing_once(monkeypatch, ErrorCode.ANALYSIS_FAILED)
        done = _run(scout, full)
        assert (done["status"], done["stage"]) == ("failed", "analyzing")
        phases["atSave"] = _roster_bodies(scout, game_id)
    else:
        scout.hooks["gpu_processing"] = lambda: client.post(f"/api/jobs/{full['id']}/cancel")
        scout.worker.run_once(timeout=0.5)
        assert client.get(f"/api/jobs/{full['id']}").json()["status"] == "cancelled"
        phases["atSave"] = _roster_bodies(scout, game_id)
    assert scout.gpu_runs[gpu_runs:] == [full["id"]]  # the film went to the GPU again

    out = _roster_tab(tmp_path / "a", game_id, phases, choices, steps)
    first = out["looks"]["loaded"]
    picked = sorted([fix["track_id"], keep["track_id"], ignored["track_id"]])  # with the fix saved earlier
    assert (first["unsaved"], first["chosen"]) == ("2 unsaved changes", picked)
    saved = out["looks"]["saved"]
    reads = ["GET /api/games/g_1/tracks", "GET /api/games/g_1", f"GET /api/jobs/{full['id']}"]
    new_tracks = phases.get("after", phases["atSave"])["tracks"]["assignments"]
    if outcome == "running":
        assert saved["requests"] == [reads[0], f"PUT /api/games/g_1/tracks/{keep['track_id']}", *reads[1:]]
        assert out["sent"] == [["PUT", f"/api/games/g_1/tracks/{keep['track_id']}", bodies[0]]]  # refused, above
        wait, error = saved["notices"]
        assert wait.startswith("Film analysis in progress")
        assert error == "".join(refused.json()["error"][k] for k in ("title", "message", "hint"))
        assert (saved["unsaved"], saved["saveDisabled"], saved["locked"]) == ("2 unsaved changes", True, True)
        ended = out["looks"]["ended"]
        assert ended["requests"] == [f"GET /api/jobs/{full['id']}", "GET /api/games/g_1", "GET /api/games/g_1/tracks"]
        [shown] = ended["notices"]
        assert shown.startswith("Film analysis finished") and "your unsaved track choices were dropped" in shown
        assert (ended["rows"], ended["chosen"]) == (sorted(a["track_id"] for a in new_tracks), [])
        assert (ended["unsaved"], ended["saveDisabled"], ended["locked"]) == ("", True, False)
        assert out["navigatedTo"] is None
    elif outcome in ("succeeded", "failed-after-install"):
        assert saved["requests"] == reads  # it read the tracks again, found others, and sent nothing
        assert out["sent"] == []
        [shown] = saved["notices"]
        assert shown.startswith("Film analysed again") and "your unsaved track choices were dropped" in shown
        assert (saved["chosen"], saved["unsaved"], saved["saveDisabled"]) == ([], "", True)
        if outcome == "succeeded":
            assert _numbered_again(loaded, phases["atSave"])
            assert (saved["rows"], saved["tableShown"]) == (sorted(a["track_id"] for a in new_tracks), True)
            assert shown.endswith("Make them again in the new table.")
        else:
            assert (saved["rows"], saved["tableShown"], new_tracks) == ([], False, [])
            assert "There are no tracks to assign now: see the game page." in shown
            assert saved["links"] == ["/games/g_1"]
        assert out["navigatedTo"] is None
    else:
        assert saved["requests"] == [
            reads[0],
            *[f"PUT /api/games/g_1/tracks/{body['track_id']}" for body in bodies],
            "POST /api/games/g_1/jobs",
        ]
        assert out["sent"] == [*[["PUT", f"/api/games/g_1/tracks/{b['track_id']}", b] for b in bodies],
                               ["POST", "/api/games/g_1/jobs", {"kind": "reanalyze"}]]
        assert (saved["notices"], out["navigatedTo"]) == ([], "/games/g_1")
        # What the page sent, as the real server takes it: the choices land on the tracks the coach saw.
        assert _replay(client, game_id, out["sent"]) == [200, 200, 201]
        rerun = client.get(f"/api/games/{game_id}").json()["latest_job_id"]
        assert _run(scout, {"id": rerun})["status"] == "succeeded"
        landed = {a["track_id"]: a for a in client.get(f"/api/games/{game_id}/tracks").json()["assignments"]}
        for chosen, body in zip((keep, ignored), bodies, strict=True):
            now = landed[chosen["track_id"]]
            assert _tracking(now) == _tracking(chosen)
            assert (now["side"], now["player_id"], now["ignored"], now["method"]) == (
                body["side"], None, body["ignore"], "manual")
        assert scout.gpu_runs[gpu_runs:] == [full["id"]]  # the re-run stayed on this server

    # Tab B at the end, with what the server holds now.
    game = client.get(f"/api/games/{game_id}").json()
    end = _game_tab(tmp_path / "b-end", game_id, _bodies(scout, game_id, game["latest_job_id"]), [])["looks"]["loaded"]
    if outcome == "failed-after-install":
        assert (end["panel"], end["panelButtons"], end["results"]) == ("Analysis failed", ["Re-run analysis"], False)
        assert end["header"] == ["Re-run analysis", False, True]
    else:
        assert (end["panelButtons"], end["results"], end["header"]) == ([], True, ["Re-run analysis", False, True])


# ---------------------------------------------------------------------------
# After a late cancel the job panel says the job carries on
# ---------------------------------------------------------------------------

# The game page with the bodies at the coach's click (``before``), after the cancel (``after``) and once
# the job has ended (``ended``); the cancel is answered with the server's own answer.
LATE_CANCEL_JS = """
route("POST", /^\\/api\\/jobs\\/j_[0-9a-f]+\\/cancel$/, () => { phase = "after"; return json(cancelled); });
await import("./js/game.js");
await settle();
const panel = () => ({
  stage: textOf($("#job-panel .job-stage")),
  button: [textOf($("#job-panel .card-head button")), $("#job-panel .card-head button").disabled],
  details: textOf($("#job-panel .job-details")),
  text: textOf(byId("job-panel")),
});
const before = panel();
$$("#job-panel button").find((b) => textOf(b) === "Cancel").click();
await settle();
const after = panel();
phase = "ended";
await settle();
await settle();
console.log(JSON.stringify({ before, confirms, after, ended: look() }));
"""


@pytest.mark.parametrize("stage", ["analyzing", "reporting", "gpu_processing"])
def test_after_a_late_cancel_the_job_panel_says_the_job_carries_on(tmp_path, scout, stage):  # noqa: F811
    """ARCHITECTURE (Job lifecycle): once the new results are installed, "the analysis runs to the end and the
    job ends succeeded; a cancel then only skips the automatic report", and the Cancel confirm says so. The
    coach clicked OK on "Too late to cancel: ... The job will finish on its own, and the report is kept." and
    the panel then said "Cancelling…" on its button and stage line, and the server's "Cancelling..." in its
    details, for the rest of the analysis or the whole report (fails on HEAD and before the fix). Now it shows
    what the job does, with the button as "Cancel requested". A cancel before the install still says
    "Cancelling…": the job does stop (guard)."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    seen: dict[str, Any] = {}

    def cancel() -> None:
        seen["before"] = _bodies(scout, game_id, full["id"])  # the page the coach clicks Cancel on
        seen["cancelled"] = client.post(f"/api/jobs/{full['id']}/cancel").json()  # the coach's OK
        seen["after"] = _bodies(scout, game_id, full["id"])  # the polls while it carries on

    scout.hooks[stage] = cancel
    scout.worker.run_once(timeout=0.5)
    assert scout.hooks == {} and "after" in seen
    assert seen["after"]["job"]["cancel_requested"] is True
    ended = _bodies(scout, game_id, full["id"])
    phases = {"during": seen["before"], "after": seen["after"], "ended": ended}

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const phases = {_for_page(phases, game_id)};\n"
        + f"const cancelled = {_for_page(seen['cancelled'], game_id)};\n"
        + GAME_PAGE_JS
        + LATE_CANCEL_JS,
    )
    [question] = out["confirms"]
    after = out["after"]
    if stage == "gpu_processing":  # stopped: it is being cancelled
        assert question == STOP_QUESTION
        assert (after["stage"], after["button"]) == ("Cancelling…", ["Cancelling…", True])
        assert (out["ended"]["panel"], out["ended"]["panelButtons"]) == ("Film analysis was cancelled", ["Start again"])
        return
    assert question.startswith("Too late to")
    label = {"analyzing": "Building box score", "reporting": "Writing scouting report"}[stage]
    assert out["before"]["stage"] == label
    assert after["stage"] == label  # it carries on, as the question said
    assert after["button"] == ["Cancel requested", True]
    assert "Cancelling" not in after["text"], after["text"]
    assert after["details"].startswith(out["before"]["details"].split(" · ")[0])  # its progress, as before
    warning = LATE_CANCEL_REPORT_SKIPPED if stage == "analyzing" else LATE_CANCEL
    assert ended["job"]["warnings"] == [warning]
    assert out["ended"]["panel"] == "Film analysis finished with warnings"
    assert out["ended"]["panelText"].endswith(warning)


# ---------------------------------------------------------------------------
# The calibration result's buttons follow the page's busy state
# ---------------------------------------------------------------------------

# The game page with the bodies before the click (``during``), once a job runs (``busy``) and once it has
# ended (``ended``). The coach saves a calibration and clicks CLICK in its result; the job post is answered
# with the server's own answer (``answer``, at ``status``).
CALIBRATION_BUSY_JS = """
route("GET", "/api/court/landmarks", json({ court: {}, landmarks }));
route("PUT", "/api/games/g_1/calibration", (req) => json({ ...calibration, points: req.body.points }));
route("POST", "/api/games/g_1/jobs", (req) => { posts.push(req.body); phase = "busy"; return json(answer, status); });
const result = () => $$("#cal-result button").map((b) => [textOf(b), b.disabled, b.getAttribute("title")]);
await import("./js/game.js");
await settle();
await openCalibration();
for (const [x, y] of [[20, 300], [600, 300], [60, 40], [560, 40]]) clickFrame(x, y);
byId("cal-save").click();
await settle();
const shown = result();
$$("#cal-result button").find((b) => textOf(b) === CLICK).click();
await settle();
const busy = { result: result(), header: look().header, panel: textOf($("#job-panel h2")), error: textOf($("#page-error .notice-title")) };
phase = "ended";
await settle();
await settle();
const ended = { result: result(), header: look().header };
posts.splice(0);
$$("#cal-result button").find((b) => textOf(b) === CLICK).click(); // the coach can start it from here again
await settle();
console.log(JSON.stringify({ shown, busy, ended, again: posts, confirms: confirms.length }));
"""


@pytest.mark.parametrize("click", ["Re-run analysis", "Full re-analysis"])
def test_the_calibration_results_buttons_wait_while_an_analysis_runs(tmp_path, scout, click):  # noqa: F811
    """The header's buttons and the Data quality tab's Full re-analysis are disabled while an analysis runs
    ("An analysis is already running") and come back when it has ended; the calibration result's did not
    (fails on HEAD and before the fix):

    * Re-run analysis was enabled again while the job it had just started ran: a click got the server's 409
      ("This game's film is being analysed right now") as an error over that job.
    * Full re-analysis stayed disabled once clicked ("refresh() redraws them" covered only the others): here
      tab A's Save & re-run had started a Re-run analysis meanwhile, so the server refused it, and once that
      had ended the coach could not start it from the calibration any more."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    before = _bodies(scout, game_id, client.get(f"/api/games/{game_id}").json()["latest_job_id"])
    if click == "Re-run analysis":
        answer = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"})  # what the click posts
        running = answer.json()
    else:
        running = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json()  # tab A's
        answer = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"})  # what the click gets
        assert answer.status_code == 409, answer.text
    busy = _bodies(scout, game_id, running["id"])
    assert busy["game"]["status"] == "queued"
    assert _run(scout, running)["status"] == "succeeded"
    phases = {"during": before, "busy": busy, "ended": _bodies(scout, game_id, running["id"])}
    for bodies in phases.values():  # a film whose court the GPU could not map: the result offers both
        bodies["analysis"]["data_quality"]["warnings"].append(FREE_THROWS)

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + f"const phases = {_for_page(phases, game_id)};\n"
        + f"const [answer, status] = [{_for_page(answer.json(), game_id)}, {answer.status_code}];\n"
        + f"const CLICK = {json.dumps(click)};\n"
        + GAME_PAGE_JS
        + CALIBRATION_BUSY_JS,
    )
    assert out["shown"] == [["Re-run analysis", False, None], ["Full re-analysis", False, None]]
    waiting = "An analysis is already running"
    busy_look = out["busy"]
    assert busy_look["result"] == [["Re-run analysis", True, waiting], ["Full re-analysis", True, waiting]]
    assert busy_look["header"] == ["Re-run analysis", True, True]
    assert busy_look["panel"] == "Re-analysis in progress"
    if click == "Re-run analysis":
        assert busy_look["error"] is None
    else:
        assert busy_look["error"] == answer.json()["error"]["title"]  # the server's refusal, shown once
    assert out["ended"] == {"result": [["Re-run analysis", False, None], ["Full re-analysis", False, None]],
                            "header": ["Re-run analysis", False, True]}
    assert out["again"] == [{"kind": "reanalyze" if click == "Re-run analysis" else "analyze"}]


# ---------------------------------------------------------------------------
# A Roster page waiting for a full analysis that failed after its install says why the table went
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("earlier_run", [True, False], ids=["full-reanalysis", "first-analysis"])
def test_a_table_that_goes_when_the_analysis_fails_after_its_install_is_explained(
    tmp_path, scout, monkeypatch, earlier_run  # noqa: F811
):
    """The Roster page opened while a Full re-analysis waited in the queue shows the earlier run's table,
    locked, with "This table updates when the analysis is done." The analysis then failed after installing
    its new run, which leaves no tracks: the table went and nothing said why when no choices were pending
    (fails on HEAD and before the fix). Now the notice where the table was says so and links to the game page,
    as it does when choices were dropped. A page that showed no table (a first analysis) says nothing (guard)."""
    client = scout.client
    if earlier_run:
        game_id, _fix = _analysed_game(scout)
        full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    else:
        game_id = _new_game(scout)
        full = _upload_film(client, game_id, auto_start=True)["job"]
    loaded = _roster_bodies(scout, game_id)  # opened while it waits in the queue
    _failing_once(monkeypatch, ErrorCode.ANALYSIS_FAILED)
    done = _run(scout, full)
    assert (done["status"], done["stage"]) == ("failed", "analyzing")
    after = _roster_bodies(scout, game_id)
    assert (after["game"]["has_analysis"], after["tracks"]["assignments"]) == (False, [])

    out = _roster_tab(tmp_path, game_id, {"loaded": loaded, "after": after}, [], [["ended", "after", None]])
    first, ended = out["looks"]["loaded"], out["looks"]["ended"]
    assert (first["tableShown"], first["locked"]) == (earlier_run, earlier_run)
    assert ended["requests"] == [f"GET /api/jobs/{full['id']}", "GET /api/games/g_1"]
    assert (ended["tableShown"], ended["rows"], out["sent"]) == (False, [], [])
    if not earlier_run:
        assert (ended["notices"], ended["links"]) == ([], [])
        return
    [shown] = ended["notices"]
    assert shown == (
        "Film analysis finished without results"
        "There are no tracks to assign now."
        "See the game page for what went wrong."
        "Open the game page"
    )
    assert ended["links"] == ["/games/g_1"]
