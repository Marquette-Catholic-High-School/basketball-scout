"""Sixth review round, integration: the seams between the worker, the panels and the Roster page.

Everything here goes through the real API (and, where a job runs, the in-process worker in demo mode of
``tests/test_review4_integration.py``); the pages run in the node fake-DOM harness of
``tests/test_review_frontend.py`` with the server's own bodies, and what they send is replayed on that server.

* One rule for "too late to cancel": ``scout.schemas.cancel_stops_job`` and ``tooLateToStop`` in
  ``static/js/labels.js`` agree for every kind and stage, and what each page shows after a cancel request is
  what the server answered it with: "Cancelling…" exactly where the job's message is "Cancelling...", its stage
  and "Cancel requested" where it is "Cancel requested: too late to stop this job, so it will finish."
  (docs/ARCHITECTURE.md, "Job lifecycle").
* After a cancel request the job panel showed the server's "Cancelling..." under its own "Cancelling…", where
  the games list now leaves the job's message out (fixed in ``static/js/jobpanel.js``).
* ``Game.has_tracking`` across the game and job shapes the coach can get to: the game page's header, Full
  re-analysis button, calibration result and Retry / Start again, and the Roster page's Re-run analysis banner
  after a roster save, against what the server then does with what they send (a GPU run or not). Also for a
  database the previous version wrote, whose games have no ``has_tracking`` stored ("Extra rules", Full
  re-analysis, and "Job lifecycle").
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from fastapi.testclient import TestClient

from scout import db
from scout.errors import ErrorCode
from scout.main import create_app
from scout.schemas import GameCreate, JobKind, JobStage, JobStatus, cancel_stops_job
from tests.test_review2_frontend import CALIBRATION_JS, GAME_JS
from tests.test_review3_integration import _upload_film
from tests.test_review4_integration import (  # noqa: F401 - the scout fixture
    GAME_PAGE_JS,
    _analysed_game,
    _failing_once,
    _for_page,
    _new_game,
    _run,
    scout,
)
from tests.test_review5_integration import _roster_bodies
from tests.test_review5_panels import CALIBRATE_JS
from tests.test_review5_verify_panels import _gpu_fails_once
from tests.test_review6_roster import REAL_JS, _roster_body
from tests.test_review_frontend import run_page

CANCELLING_MESSAGE = "Cancelling..."
TOO_LATE_MESSAGE = "Cancel requested: too late to stop this job, so it will finish."
HEALTH_JS = """
route("GET", "/api/health", json({ status: "ok", version: "1", processor: "mock", queue_backend: "sqlite",
  queue_ok: true, worker_last_seen_s: 5, claude_configured: true, ffmpeg_available: true }));
"""


@pytest.fixture
def api(auth_headers):
    with TestClient(create_app()) as client:
        client.headers.update(auth_headers)
        yield client


# ---------------------------------------------------------------------------
# One rule for "too late to cancel", from the server's answer to every page
# ---------------------------------------------------------------------------


def _cancel_answers(api: TestClient) -> list[dict[str, Any]]:
    """The real server's answer to a cancel request for a job of every kind at every stage it can be at while
    queued or running: running (claimed by a worker), queued with a GPU call (``external_id``, as an older
    version's Redis reaper left them) and queued without one (stage ``queued``: cancelled at once)."""
    game = db.create_game(GameCreate(scouted_team="Central", other_team="North"))
    answers = []
    for kind in JobKind:
        for stage in JobStage:
            if stage == JobStage.DONE:  # only a finished job is there
                continue
            shapes = [(JobStatus.RUNNING, None), (JobStatus.QUEUED, "fc-1")]
            if stage == JobStage.QUEUED:
                shapes.append((JobStatus.QUEUED, None))
            for status, handle in shapes:
                job = db.create_job(game.id, kind)
                db.update_job(job.id, status=status, stage=stage, progress=40.0, external_id=handle,
                              worker_id="w-1" if status == JobStatus.RUNNING else None, message="On its way")
                answer = api.post(f"/api/jobs/{job.id}/cancel")
                assert answer.status_code == 200, answer.text
                answers.append(answer.json())
    return answers


# Each page fed the server's answers: the stage text (labels.js), the job panel (analysis jobs: the game page
# shows no other), the report tab's status line (a REPORT job) and the games list's progress line (analysis jobs:
# a game's latest_job_id). ``table`` is tooLateToStop for every kind and stage, ``done`` among them.
CANCEL_ANSWERS_JS = """
const { jobStageText, tooLateToStop } = await import("./js/labels.js");
const { JobPanel } = await import("./js/jobpanel.js");
const { Report } = await import("./js/report.js");
route("GET", /^\\/api\\/jobs\\/[\\w-]+$/, (req) => json(answers.find((a) => a.id === req.path.split("/").pop())));
const panel = new JobPanel({ onChange() {} });
const report = new Report({ gameId: "g_1" });
const active = (job) => ["queued", "running"].includes(job.status);
const seen = answers.map((job) => {
  const out = { stage: jobStageText(job), late: tooLateToStop(job) };
  if (active(job) && job.kind !== "report") {
    panel.renderActive(job);
    out.panel = textOf(byId("job-panel"));
  }
  if (active(job) && job.kind === "report") {
    report.track(job); // its status line is written at once, then the polls go on: stopped here
    out.report = textOf(byId("report-status"));
    report.polling.abort();
  }
  return out;
});
await settle();
const table = TABLE.map(([kind, stage]) => tooLateToStop({ kind, stage, status: "running" }));
console.log(JSON.stringify({ seen, table }));
"""

GAMES_LIST_JS = """
route("GET", "/api/games", json(answers.map((a) => game({ id: `g_${a.id}`, display_title: a.id, status: "processing",
  latest_job_id: a.id }))));
route("GET", /^\\/api\\/jobs\\/[\\w-]+$/, (req) => json(answers.find((a) => a.id === req.path.split("/").pop())));
await import("./js/index.js");
await settle();
const progress = Object.fromEntries($$("#games-list .game-card").map((card) =>
  [card.getAttribute("aria-label"), textOf(card.querySelector(".progress-text"))]));
console.log(JSON.stringify({ progress }));
"""


def test_every_page_says_what_the_servers_cancel_answer_says_for_every_kind_and_stage(tmp_path, api):
    """ARCHITECTURE (Job lifecycle): "A cancel no longer stops an ANALYZE or REANALYZE at analyzing or reporting, or
    a REPORT at reporting (scout.schemas.cancel_stops_job, mirrored by tooLateToStop in static/js/labels.js)": both
    tables, run over every kind and stage. Then the seam: the server's answer to a cancel request (its message,
    from cancel_stops_job) and what the pages show for that answer (from tooLateToStop) agree for every kind, stage,
    status and GPU call: "Cancelling…" on the job panel, the report tab and the games list exactly where the server
    said "Cancelling...", and the job's stage with "Cancel requested" (no "Cancelling") exactly where it said it is
    too late. A queued job without a GPU call is cancelled at once and shows "Cancelled". (Fails on HEAD: labels.js
    has no tooLateToStop, and the server said "Cancelling..." for every job.)"""
    answers = _cancel_answers(api)
    table = [[kind.value, stage.value] for kind in JobKind for stage in JobStage]
    script = f"const answers = {json.dumps(answers)};\nconst TABLE = {json.dumps(table)};\n"
    out = run_page(tmp_path / "game", "game.html", "/games/g_1", script + HEALTH_JS + CANCEL_ANSWERS_JS)
    listed = [a for a in answers if a["kind"] != "report" and a["status"] in ("queued", "running")]
    games_list = run_page(
        tmp_path / "list", "index.html", "/", f"const answers = {json.dumps(listed)};\n" + HEALTH_JS + GAMES_LIST_JS
    )["progress"]

    # The two tables: every kind at every stage.
    keys = [tuple(case) for case in table]
    expected = [not cancel_stops_job(JobKind(kind), JobStage(stage)) for kind, stage in table]
    assert dict(zip(keys, out["table"], strict=True)) == dict(zip(keys, expected, strict=True))

    for answer, seen in zip(answers, out["seen"], strict=True):
        case = (answer["kind"], answer["stage"], answer["status"], answer["external_id"], answer["message"], seen)
        if answer["status"] == "cancelled":  # queued without a GPU call: at once
            assert (answer["stage"], seen["stage"]) == ("done", "Cancelled"), case
            continue
        too_late = not cancel_stops_job(JobKind(answer["kind"]), JobStage(answer["stage"]))
        assert answer["cancel_requested"] is True, case
        assert answer["message"] == (TOO_LATE_MESSAGE if too_late else CANCELLING_MESSAGE), case
        assert seen["late"] is too_late, case
        shown = [seen["stage"], seen.get("panel") or seen.get("report"), games_list.get(answer["id"])]
        shown = [text for text in shown if text is not None]
        assert len(shown) == (2 if answer["kind"] == "report" else 3), case
        for text in shown:
            if too_late:
                assert "Cancelling" not in text, case
            else:
                assert "Cancelling…" in text and "Cancel requested" not in text, case
        if too_late:
            assert seen["stage"] != "Cancelling…" and all("Cancel requested" in text for text in shown[1:]), case


# The job panel on each answer, as the game page shows the latest analysis job: its stage line, its button and
# its details line (progress, the server's message, how long it has run).
PANEL_DETAILS_JS = """
const { JobPanel } = await import("./js/jobpanel.js");
const panel = new JobPanel({ onChange() {} });
const seen = answers.map((job) => {
  panel.renderActive(job);
  return { stage: textOf($("#job-panel .job-stage")), button: textOf($("#job-panel .card-head button")),
    details: textOf($("#job-panel .job-details")), text: textOf(byId("job-panel")) };
});
console.log(JSON.stringify({ seen }));
"""


def test_after_a_cancel_request_the_job_panel_leaves_out_the_servers_message_as_the_games_list_does(tmp_path, api):
    """Integration (panels): after a cancel request the games list leaves out the job's message ("Cancelling… ·
    40%", round 6), and so did the job panel for a job a cancel no longer stops, but for one it still stops the
    panel showed the server's "Cancelling..." on its details line under "Cancelling…" on its stage line and its
    button: "Cancelling" three times, twice with three dots, for as long as the worker takes to stop the job (the
    next GPU poll, or the end of a results download). Now the details line has the progress and time only, for
    every kind and stage, like the games list (fails before the fix for every job a cancel still stops)."""
    answers = [a for a in _cancel_answers(api) if a["kind"] != "report" and a["status"] in ("queued", "running")]
    out = run_page(tmp_path, "game.html", "/games/g_1", f"const answers = {json.dumps(answers)};\n" + HEALTH_JS
                   + PANEL_DETAILS_JS)
    for answer, seen in zip(answers, out["seen"], strict=True):
        case = (answer["kind"], answer["stage"], answer["status"], answer["message"], seen)
        assert seen["details"] == "40% overall", case
        if cancel_stops_job(JobKind(answer["kind"]), JobStage(answer["stage"])):
            assert (seen["stage"], seen["button"]) == ("Cancelling…", "Cancelling…"), case
            assert seen["text"].count("Cancelling") == 2, case
        else:
            assert seen["button"] == "Cancel requested" and "Cancelling" not in seen["text"], case


# ---------------------------------------------------------------------------
# Game.has_tracking, end to end
# ---------------------------------------------------------------------------


def _cancel_on_the_gpu(scout, job: dict) -> dict:  # noqa: F811
    """The coach cancels ``job`` while it waits for the GPU (before its new results are installed)."""
    scout.hooks["gpu_processing"] = lambda: scout.client.post(f"/api/jobs/{job['id']}/cancel")
    done = _run(scout, job)
    assert (done["status"], done["warnings"]) == ("cancelled", []), done
    return done


def _make_shape(scout, monkeypatch, shape: str) -> str:  # noqa: F811
    """A game left in ``shape`` by the real API and worker (with the upload page's auto start); its id."""
    client = scout.client

    def start(game_id: str, kind: str) -> dict:
        r = client.post(f"/api/games/{game_id}/jobs", json={"kind": kind})
        assert r.status_code == 201, r.text
        return r.json()

    def failed_past_the_gpu(game_id: str, job: dict) -> None:
        _failing_once(monkeypatch, ErrorCode.CONFIG_INVALID)
        done = _run(scout, job)
        assert (done["status"], done["stage"]) == ("failed", "analyzing"), done

    if shape == "never-analysed":
        game_id = _new_game(scout)
        _upload_film(client, game_id, auto_start=False)
    elif shape == "first-run-failed-on-the-gpu":
        game_id = _new_game(scout)
        _gpu_fails_once(monkeypatch, scout)
        assert _run(scout, _upload_film(client, game_id, auto_start=True)["job"])["stage"] == "gpu_processing"
    elif shape in ("first-run-failed-after-the-gpu", "new-film-after-a-failure-past-the-gpu"):
        game_id = _new_game(scout)
        failed_past_the_gpu(game_id, _upload_film(client, game_id, auto_start=True)["job"])
        if shape.startswith("new-film"):  # the new film's analysis, cancelled while queued
            queued = _upload_film(client, game_id, auto_start=True)["job"]
            assert client.post(f"/api/jobs/{queued['id']}/cancel").json()["status"] == "cancelled"
    else:
        game_id, _fix = _analysed_game(scout)
        if shape == "full-reanalysis-failed-on-the-gpu":
            _gpu_fails_once(monkeypatch, scout)
            assert _run(scout, start(game_id, "analyze"))["stage"] == "gpu_processing"
        elif shape == "full-reanalysis-cancelled-before-its-install":
            _cancel_on_the_gpu(scout, start(game_id, "analyze"))
        elif shape == "full-reanalysis-cancelled-after-a-failure-past-the-gpu":
            failed_past_the_gpu(game_id, start(game_id, "analyze"))
            _cancel_on_the_gpu(scout, start(game_id, "analyze"))
        elif shape == "re-run-cancelled-while-queued":
            assert client.post(f"/api/jobs/{start(game_id, 'reanalyze')['id']}/cancel").json()["status"] == "cancelled"
        else:
            assert shape == "analysed", shape
    return game_id


def _stored_without_has_tracking(game_id: str) -> None:
    """The game's document as the previous version stored it: no has_tracking at all."""
    with db.session() as conn:
        row = conn.execute("SELECT data FROM games WHERE id = ?", (game_id,)).fetchone()
        document = json.loads(row["data"])
        document.pop("has_tracking", None)
        conn.execute("UPDATE games SET data = ? WHERE id = ?", (json.dumps(document), game_id))


def _game_page_bodies(scout, game_id: str) -> dict[str, Any]:  # noqa: F811
    """The game page's requests, as the real server answers them now (``job``: the game's latest job)."""
    client = scout.client
    game = client.get(f"/api/games/{game_id}").json()
    jobs = client.get(f"/api/games/{game_id}/jobs").json()
    analysis = client.get(f"/api/games/{game_id}/analysis")
    return {
        "game": game,
        "jobs": jobs,
        "job": next((j for j in jobs if j["kind"] != "report"), None),
        "analysis": analysis.json() if analysis.status_code == 200 else None,
        "reports": client.get(f"/api/games/{game_id}/reports").json(),
    }


# The coach on the game page: the header's button, the calibration result's (after saving a calibration) and the
# job panel's Retry / Re-run analysis / Start again, every question accepted. Job posts are answered 503
# (GAME_PAGE_JS), so each click starts from the page as loaded.
SHAPE_GAME_PAGE_JS = """
await import("./js/game.js");
await settle();
const pending = byId("analysis-pending").hidden ? null : $$("#analysis-pending .notice p").map(textOf);
const seen = { ...look(), pending };
byId("reanalyze-btn").click();
await settle();
seen.headerPosts = posts.splice(0);
await saveCalibration();
seen.calibration = resultButtons();
$$("#cal-result button")[0].click();
await settle();
seen.calibrationPosts = posts.splice(0);
const action = $$("#job-panel button").find((b) => ["Retry", "Re-run analysis", "Start again"].includes(textOf(b)));
seen.action = action ? textOf(action) : null;
confirms.length = 0;
if (action) action.click();
await settle();
seen.actionConfirms = confirms.splice(0);
seen.actionPosts = [...posts.splice(0), ...retries.splice(0).map((id) => ({ retry: id }))];
console.log(JSON.stringify(seen));
"""

# The coach on the Roster page: a FastScout name typed in and the roster saved, then the banner's Re-run analysis.
SHAPE_ROSTER_PAGE_JS = """
const name = editor("scouted").querySelector(`input[data-i="${rowOf("scouted", "3")}"][data-key="fastscout_name"]`);
name.value = "Test Player 3";
fire(name, "input");
editor("scouted").querySelectorAll("button").find((b) => textOf(b) === "Save roster").click();
await settle();
const banner = !byId("rerun-banner").hidden;
if (banner) {
  byId("rerun-btn").click();
  await settle();
}
console.log(JSON.stringify({ banner, sent }));
"""

FULL_RUN_QUESTION = "Send the film to the GPU again?"
SAVED_NOT_BUILT = [
    "The GPU results for this film are saved, but the stats have not been built from them yet.",
    "Click Re-run analysis to build them on this server (about a minute, no GPU).",
]
SHAPES = [
    "never-analysed",
    "analysed",
    "first-run-failed-on-the-gpu",
    "first-run-failed-after-the-gpu",
    "full-reanalysis-failed-on-the-gpu",
    "full-reanalysis-cancelled-before-its-install",
    "full-reanalysis-cancelled-after-a-failure-past-the-gpu",
    "re-run-cancelled-while-queued",
    "new-film-after-a-failure-past-the-gpu",
]
NO_GPU_RESULTS = ("never-analysed", "first-run-failed-on-the-gpu", "new-film-after-a-failure-past-the-gpu")
# The previous version's database, for a game with the GPU results and without (an analysis, a failure after the GPU
# and a cancel after it; none yet).
STORED_BEFORE_THE_FIELD = [
    "analysed",
    "first-run-failed-after-the-gpu",
    "full-reanalysis-cancelled-after-a-failure-past-the-gpu",
    "never-analysed",
]


def _replayed(scout, game_id: str, request: dict) -> tuple[str, bool, int]:  # noqa: F811
    """What the server does with a request a page sent: the job it starts, whether that sent the film to the GPU,
    and how many track assignments the game has once it has run."""
    client = scout.client
    if "retry" in request:
        r = client.post(f"/api/jobs/{request['retry']}/retry")
        assert r.status_code == 200, r.text
    else:
        r = client.post(f"/api/games/{game_id}/jobs", json=request)
        assert r.status_code == 201, r.text
    gpu_runs = len(scout.gpu_runs)
    done = _run(scout, r.json())
    assert done["status"] == "succeeded", done
    overrides = client.get(f"/api/games/{game_id}/tracks").json()["overrides"]
    return done["kind"], len(scout.gpu_runs) > gpu_runs, len(overrides)


@pytest.mark.parametrize(
    ("shape", "stored_by"),
    [(shape, "this-version") for shape in SHAPES]
    + [(shape, "the-previous-version") for shape in STORED_BEFORE_THE_FIELD],
)
def test_every_page_offers_what_the_server_then_does_for_every_game_shape(
    tmp_path, scout, monkeypatch, shape, stored_by  # noqa: F811
):
    """ARCHITECTURE (Extra rules, Full re-analysis): "The game page offers Re-run analysis and Full re-analysis
    whenever has_tracking is true (Analyze film otherwise)", and has_tracking is in every Game body "also for games
    saved before the field existed, and also after a cancel or a failure left the game without an analysis". For
    every shape: the header, the calibration result and the Roster page's banner after a roster save name a Re-run
    analysis exactly when the server holds the GPU results, and what they send then runs without the GPU (with the
    previous version's database too, without a manual step); Analyze film sends the film to the GPU. Retry and Start
    again ask the Full re-analysis button's question exactly when the server's retry sends the film to the GPU again
    over saved GPU results (clearing the track fixes), and a Retry labelled Re-run analysis never does."""
    client = scout.client
    game_id = _make_shape(scout, monkeypatch, shape)
    if stored_by == "the-previous-version":
        _stored_without_has_tracking(game_id)
    bodies = _game_page_bodies(scout, game_id)
    game = bodies["game"]
    saved = game["has_tracking"]
    assert saved is (shape not in NO_GPU_RESULTS)
    roster_loaded = _roster_bodies(scout, game_id)
    roster_put = _roster_body(roster_loaded, "scouted", fastscout={"3": "Test Player 3"})
    put = client.put(f"/api/games/{game_id}/rosters/scouted", json=roster_put)  # what the Roster page's save sends
    assert put.status_code == 200, put.text
    roster_saved = {**_roster_bodies(scout, game_id), "put": put.json()}
    fixes = len(client.get(f"/api/games/{game_id}/tracks").json()["overrides"])

    page = run_page(
        tmp_path / "game",
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + f"const phases = {{ during: {_for_page(bodies, game_id)} }};\n"
        + GAME_PAGE_JS
        + CALIBRATE_JS
        + SHAPE_GAME_PAGE_JS,
    )
    roster = run_page(
        tmp_path / "roster",
        "roster.html",
        "/games/g_1/roster",
        f"const phases = {_for_page({'loaded': roster_loaded, 'saved': roster_saved}, game_id)};\n"
        + REAL_JS
        + SHAPE_ROSTER_PAGE_JS,
    )

    # What the pages offer.
    label, kind = ("Re-run analysis", "reanalyze") if saved else ("Analyze film", "analyze")
    assert page["header"] == [label, False, saved]  # Full re-analysis beside Re-run analysis
    assert page["calibration"] == [label]
    assert page["headerPosts"] == page["calibrationPosts"] == [{"kind": kind}]
    if bodies["analysis"] is None and game["status"] == "uploaded":
        assert (page["pending"] == SAVED_NOT_BUILT) is saved, page["pending"]
    assert roster["banner"] is saved
    assert roster["sent"][0] == ["PUT", "/api/games/g_1/rosters/scouted", roster_put]
    assert roster["sent"][1:] == ([["POST", "/api/games/g_1/jobs", {"kind": "reanalyze"}]] if saved else [])
    action = {
        "first-run-failed-on-the-gpu": "Retry",
        "first-run-failed-after-the-gpu": "Re-run analysis",
        "full-reanalysis-failed-on-the-gpu": "Retry",
        "full-reanalysis-cancelled-before-its-install": "Start again",
        "full-reanalysis-cancelled-after-a-failure-past-the-gpu": "Start again",
        "re-run-cancelled-while-queued": "Start again",
        "new-film-after-a-failure-past-the-gpu": "Start again",
    }.get(shape)
    assert page["action"] == action
    asked = [q for q in page["actionConfirms"] if q.startswith(FULL_RUN_QUESTION)]
    assert asked == page["actionConfirms"]
    if action:
        [request] = page["actionPosts"]
        assert request == {"retry": bodies["job"]["id"]}

    # What the server does with them, in the order the coach could click them. The banner's Re-run analysis first:
    # the server takes it exactly when the banner showed, and it runs without the GPU.
    rerun = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"})
    if saved:
        assert rerun.status_code == 201, rerun.text
        gpu_runs = len(scout.gpu_runs)
        assert _run(scout, rerun.json())["status"] == "succeeded"
        assert len(scout.gpu_runs) == gpu_runs
    else:
        assert (rerun.status_code, rerun.json()["error"]["code"]) == (409, "ANALYSIS_NOT_READY")
    if action:  # Retry / Start again: a question exactly when it sends the film to the GPU over saved results
        retried, on_the_gpu, left = _replayed(scout, game_id, page["actionPosts"][0])
        assert bool(asked) is (on_the_gpu and saved), (retried, on_the_gpu, asked)
        if asked:
            assert ("The current results stay on this page" in asked[0]) is (bodies["analysis"] is not None)
            assert left == 0  # "it clears the track assignments you made on the Roster page"
        if action == "Re-run analysis":
            assert (retried, on_the_gpu, left) == ("reanalyze", False, fixes)
    # The header's button: Re-run analysis only redoes the stats here, Analyze film sends the film to the GPU.
    started, on_the_gpu, _left = _replayed(scout, game_id, page["headerPosts"][0])
    assert (started, on_the_gpu) == (kind, not saved)
