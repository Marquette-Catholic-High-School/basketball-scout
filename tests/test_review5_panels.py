"""Fifth review round: the game page's calibration and job panels.

They run the real game page in the node fake-DOM harness of ``tests/test_review_frontend.py``
(with the probes of ``tests/test_review2_frontend.py``). The seam tests feed it the real API's
bodies, with an in-process worker in demo mode (``tests/test_review4_integration.py``), and then
check that the server does what the page said it would.

* The calibration panel's button follows the game page's rule: **Analyze film** for a game that
  has not been analysed yet, **Re-run analysis** otherwise (README, "Court calibration").
* The job panel's Cancel confirm says what a late cancel does to an ANALYZE at ``analyzing`` or
  ``reporting`` (docs/ARCHITECTURE.md, "Job lifecycle").
* **Start again** on a cancelled Full re-analysis asks first, like the Full re-analysis button.
"""

from __future__ import annotations

import json

import pytest

from tests.test_review2_frontend import CALIBRATION_JS, GAME_JS
from tests.test_review3_integration import _upload_film
from tests.test_review4_integration import (  # noqa: F401 - the scout fixture
    GAME_PAGE_JS,
    LATE_CANCEL,
    LATE_CANCEL_REPORT_SKIPPED,
    _analysed_game,
    _bodies,
    _for_page,
    _new_game,
    _run,
    scout,
)
from tests.test_review_frontend import run_page

STOP_QUESTION = "Stop this job? You can start it again later."

# Calibrate the court on the game page (four corners), then read the result's buttons.
CALIBRATE_JS = """
route("GET", "/api/court/landmarks", json({ court: {}, landmarks }));
const calibrations = [];
route("PUT", "/api/games/g_1/calibration", (req) => { calibrations.push(req.body); return json({ ...calibration, points: req.body.points }); });
async function saveCalibration() {
  await openCalibration();
  for (const [x, y] of [[20, 300], [600, 300], [60, 40], [560, 40]]) clickFrame(x, y);
  byId("cal-save").click();
  await settle();
}
const resultButtons = () => $$("#cal-result button").map(textOf);
"""


def _js(value: object) -> str:
    return json.dumps(value)


# ---------------------------------------------------------------------------
# 3. The calibration panel's button follows the game page's rule
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("game_over", "job_over", "label", "kind"),
    [
        pytest.param(
            {"status": "uploaded", "has_analysis": False}, None, "Analyze film", "analyze", id="never-analysed"
        ),
        pytest.param(
            {"status": "failed", "has_analysis": False},
            {"kind": "analyze", "status": "failed", "stage": "gpu_processing"},
            "Analyze film",
            "analyze",
            id="only-run-failed-on-the-gpu",
        ),
        pytest.param({"has_tracking": True}, None, "Re-run analysis", "reanalyze", id="analysed"),
        pytest.param(
            {"status": "failed", "has_analysis": False, "has_tracking": True},
            {"kind": "analyze", "status": "failed", "stage": "analyzing"},
            "Re-run analysis",
            "reanalyze",
            id="failed-after-the-gpu",
        ),
    ],
)
def test_calibration_button_names_the_job_the_game_page_starts(tmp_path, game_over, job_over, label, kind):
    """README (Court calibration): "Save calibration, then Re-run analysis (Analyze film for a game that
    has not been analysed yet)". The panel always read "Re-run analysis" (server only, about a minute),
    while its click starts what the game page's header starts: for a game never analysed, or whose only
    run failed on the GPU, an ANALYZE (a first GPU run). The never-analysed and failed-on-the-GPU cases
    failed on HEAD; an analysed game and one whose analysis failed after the GPU are guards."""
    jobs = f"[job({_js(job_over)})]" if job_over else "[]"
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + f"""
const jobs = {jobs};
gamePageRoutes(route, json, {{ gameBody: game({_js(game_over)}), jobs, analysisBody: analysis() }});
route("GET", /^\\/api\\/jobs\\/j_\\d+$/, json(jobs[0] || null));
route("POST", "/api/games/g_1/jobs", (req) => {{ posts.push(req.body); return fail(503, "QUEUE_UNAVAILABLE", "Not here"); }});
"""
        + CALIBRATE_JS
        + """
await import("./js/game.js");
await settle();
await saveCalibration();
const shown = { buttons: resultButtons(), primary: $$("#cal-result button.btn-primary").map(textOf),
  header: textOf(byId("reanalyze-btn")) };
const hint = $$("#cal-result .notice p").map(textOf).pop();
$$("#cal-result button")[0].click();
await settle();
console.log(JSON.stringify({ shown, hint, posts }));
""",
    )
    assert out["shown"] == {"buttons": [label], "primary": [label], "header": label}  # the header's name for it
    assert out["posts"] == [{"kind": kind}]
    if kind == "analyze":  # not "after the analysis runs again" before a first run
        assert out["hint"] == "The new mapping is used the next time the analysis runs."


def test_calibration_button_follows_the_page_when_the_first_analysis_finishes(tmp_path):
    """The calibration result stays on the page while the first analysis runs. Once it has finished, the
    same button starts a Re-run analysis, and its name follows the page (fails on HEAD, where it read
    "Re-run analysis" before the first run too)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + """
let phase = "uploaded";
const run = () => job({ id: "j_2", ...(phase === "ready" ? { status: "succeeded", stage: "done", progress: 100 }
  : { status: "running", stage: "gpu_processing", progress: 40 }) });
gamePageRoutes(route, json, {
  gameBody: () => game(phase === "ready" ? { has_tracking: true, latest_job_id: "j_2" }
    : { status: phase === "uploaded" ? "uploaded" : "processing", has_analysis: false, latest_job_id: phase === "uploaded" ? null : "j_2" }),
  analysisBody: analysis(),
});
route("GET", "/api/games/g_1/jobs", () => json(phase === "uploaded" ? [] : [run()]));
route("GET", "/api/jobs/j_2", () => json(run()));
route("POST", "/api/games/g_1/jobs", (req) => {
  posts.push(req.body);
  if (phase !== "uploaded") return fail(503, "QUEUE_UNAVAILABLE", "Not here");
  phase = "running";
  return json(job({ id: "j_2" }), 201);
});
"""
        + CALIBRATE_JS
        + """
await import("./js/game.js");
await settle();
await saveCalibration();
const before = resultButtons();
$$("#cal-result button")[0].click();
await settle();
const during = { buttons: resultButtons(), panel: textOf($("#job-panel h2")) };
phase = "ready";
await settle();
await settle();
const after = { buttons: resultButtons(), header: textOf(byId("reanalyze-btn")), panelShown: !byId("job-panel").hidden };
$$("#cal-result button")[0].click();
await settle();
console.log(JSON.stringify({ before, during, after, posts }));
""",
    )
    assert out["before"] == ["Analyze film"]
    assert out["during"] == {"buttons": ["Analyze film"], "panel": "Film analysis in progress"}
    assert out["after"] == {"buttons": ["Re-run analysis"], "header": "Re-run analysis", "panelShown": False}
    assert out["posts"] == [{"kind": "analyze"}, {"kind": "reanalyze"}]


def test_double_click_on_the_calibration_button_starts_one_job(tmp_path):
    """Extra: the header's button disables itself on click, the calibration's did not. A double click
    posted a second job, which the server refuses while the first runs (409), and the page showed that
    refusal as an error over the analysis it had just started (fails on HEAD: two posts)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + """
let started = false;
const rerun = job({ id: "j_2", kind: "reanalyze", status: "running", stage: "analyzing", progress: 50 });
gamePageRoutes(route, json, { gameBody: () => game({ has_tracking: true, ...(started ? { status: "processing", latest_job_id: "j_2" } : {}) }),
  analysisBody: analysis() });
route("GET", "/api/games/g_1/jobs", () => json(started ? [rerun] : []));
route("GET", "/api/jobs/j_2", json(rerun));
route("POST", "/api/games/g_1/jobs", (req) => {
  posts.push(req.body);
  if (started) return fail(409, "CONFLICT", "This game's film is being analysed right now", { hint: "Wait for it to finish, or cancel it first." });
  started = true;
  return json({ ...rerun, status: "queued", stage: "queued", progress: 0 }, 201);
});
"""
        + CALIBRATE_JS
        + """
await import("./js/game.js");
await settle();
await saveCalibration();
const button = $$("#cal-result button")[0];
button.click();
button.click();
await settle();
console.log(JSON.stringify({ posts, error: textOf(byId("page-error")), panel: textOf($("#job-panel h2")),
  enabledAgain: !$$("#cal-result button")[0].disabled }));
""",
    )
    assert out["posts"] == [{"kind": "reanalyze"}]
    assert (out["error"], out["panel"]) == ("", "Re-analysis in progress")
    # As the header's: it waits while the job it started runs (round 5, integration: it was enabled again here).
    assert out["enabledAgain"] is False


def test_analyze_film_after_calibrating_sends_the_film_to_the_gpu_with_the_calibration(
    tmp_path, scout, monkeypatch  # noqa: F811
):
    """README (Court calibration) with the real server: a game with film and no analysis, calibrated
    first. The page's button reads Analyze film (on HEAD: Re-run analysis), and what it posts is a first
    GPU run that takes the calibration along (the options the worker sends with the film)."""
    client = scout.client
    gpu = scout.worker.processor
    submit = gpu.submit
    sent: list[object] = []

    def submitted(**kwargs):
        sent.append(kwargs["options"]["calibration"])
        return submit(**kwargs)

    monkeypatch.setattr(gpu, "submit", submitted)
    game_id = _new_game(scout)
    _upload_film(client, game_id, auto_start=False)
    game = client.get(f"/api/games/{game_id}").json()
    jobs = client.get(f"/api/games/{game_id}/jobs").json()
    assert (game["status"], game["has_analysis"], jobs) == ("uploaded", False, [])
    bodies = {"game": game, "jobs": jobs, "job": None, "analysis": None, "reports": []}

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + f"const phases = {{ during: {_for_page(bodies, game_id)} }};\n"
        + GAME_PAGE_JS
        + CALIBRATE_JS
        + """
await import("./js/game.js");
await settle();
await saveCalibration();
const buttons = resultButtons();
$$("#cal-result button")[0].click();
await settle();
console.log(JSON.stringify({ header: look().header, buttons, calibrations, posts }));
""",
    )
    assert out["header"] == ["Analyze film", False, False]
    assert out["buttons"] == ["Analyze film"]
    assert out["posts"] == [{"kind": "analyze"}]

    # What the page sent, as the real server takes it: the calibration, then the job.
    [body] = out["calibrations"]
    assert client.put(f"/api/games/{game_id}/calibration", json=body).status_code == 200
    started = client.post(f"/api/games/{game_id}/jobs", json=out["posts"][0])
    assert started.status_code == 201, started.text
    assert _run(scout, started.json())["status"] == "succeeded"
    assert scout.gpu_runs == [started.json()["id"]]
    [calibration] = sent
    assert calibration is not None and calibration["video_width"] == body["video_width"]
    assert client.get(f"/api/games/{game_id}").json()["has_analysis"] is True


# ---------------------------------------------------------------------------
# 4. The job panel's Cancel confirm says what a late cancel does
# ---------------------------------------------------------------------------


def _cancel_question_says(question: str, stage: str | None, kind: str = "analyze") -> None:
    """The confirm for a cancel of a ``kind`` job at ``stage`` (None: another stage) says what the worker then
    does with it (scout/worker.py). Round 6: the ANALYZE question at analyzing holds whether or not a report is
    due, and a REANALYZE at analyzing (here one without a report to write) says it will finish too."""
    if kind == "reanalyze" and stage == "analyzing":
        assert question.startswith("Too late to stop the re-analysis")
        assert question.endswith("There is nothing left to cancel.")
    elif stage == "analyzing":
        assert question.startswith("Too late to stop the analysis")
        assert "the new GPU results are already in place, so it will finish" in question
        assert question.endswith("Cancelling now only skips the automatic scouting report, if one was going to be written.")
    elif stage == "reporting":
        assert question.startswith("Too late to cancel")
        assert "the analysis is finished and Claude is already writing the scouting report" in question
        assert question.endswith("the report is kept.")
    else:
        assert question == STOP_QUESTION


@pytest.mark.parametrize(
    ("kind", "stage"),
    [
        pytest.param("analyze", "analyzing", id="analyze-building-the-box-score"),
        pytest.param("analyze", "reporting", id="analyze-writing-the-report"),
        pytest.param("analyze", "gpu_processing", id="analyze-on-the-gpu"),
        pytest.param("analyze", "downloading_results", id="analyze-downloading"),
        pytest.param("reanalyze", "analyzing", id="reanalyze"),
    ],
)
def test_cancel_confirm_says_what_a_cancel_does_at_that_stage(tmp_path, kind, stage):
    """ARCHITECTURE (Job lifecycle): "The job panel's Cancel confirm says so for an ANALYZE at analyzing
    or reporting": the new results are installed, so the analysis is finished and a cancel only skips
    the automatic report (one Claude is already writing is kept). It always asked "Stop this job? You can
    start it again later." (the analyzing and reporting cases failed on HEAD). Up to the download a
    cancel stops an ANALYZE (guards); since round 6 a REANALYZE at analyzing says it will finish too.
    Declining sends nothing; OK sends the cancel."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"""
const running = job({{ kind: {_js(kind)}, status: "running", stage: {_js(stage)}, progress: 80 }});
let requested = false;
gamePageRoutes(route, json, {{ gameBody: game({{ status: "processing", latest_job_id: "j_1" }}), jobs: [running], analysisBody: analysis() }});
route("GET", "/api/jobs/j_1", () => json({{ ...running, cancel_requested: requested }}));
let cancels = 0;
route("POST", "/api/jobs/j_1/cancel", () => {{ cancels += 1; requested = true; return json({{ ...running, cancel_requested: true }}); }});
"""
        + """
await import("./js/game.js");
await settle();
const cancel = () => $$("#job-panel button").find((b) => textOf(b) === "Cancel");
globalThis.confirmAnswer = false;
cancel().click();
await settle();
const declined = { cancels, button: textOf($("#job-panel .card-head button")) };
globalThis.confirmAnswer = true;
cancel().click();
await settle();
console.log(JSON.stringify({ confirms, declined, cancels, button: textOf($("#job-panel .card-head button")) }));
""",
    )
    first, second = out["confirms"]
    assert first == second
    _cancel_question_says(first, stage, kind)
    assert out["declined"] == {"cancels": 0, "button": "Cancel"}
    # Too late to stop it: the job carries on, so the button no longer says "Cancelling…" (round 5, integration).
    late = stage in ("analyzing", "reporting")
    assert (out["cancels"], out["button"]) == (1, "Cancel requested" if late else "Cancelling…")


@pytest.mark.parametrize("stage", ["gpu_processing", "downloading", "analyzing", "reporting"])
def test_cancel_confirm_matches_what_the_worker_does_with_the_cancel(tmp_path, scout, stage):  # noqa: F811
    """The seam: a Full re-analysis as the real server shows it at ``stage`` (the page the coach clicks
    Cancel on), the question the page asks there, and what the worker then does with that cancel. Up to
    the download it stops the job (cancelled, Start again); from the analysis on the job succeeds with
    the warning, without the report, or with it when Claude was already writing it (the analyzing and
    reporting questions failed on HEAD)."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    reports = len(client.get(f"/api/games/{game_id}/reports").json())
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    seen: dict[str, object] = {}

    def cancel() -> None:
        seen["during"] = _bodies(scout, game_id, full["id"])
        assert client.post(f"/api/jobs/{full['id']}/cancel").status_code == 200  # the coach's OK

    scout.hooks[stage] = cancel
    scout.worker.run_once(timeout=0.5)
    assert scout.hooks == {} and "during" in seen
    done = client.get(f"/api/jobs/{full['id']}").json()

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const phases = {{ during: {_for_page(seen['during'], game_id)} }};\n"
        + GAME_PAGE_JS
        + """
const cancels = [];
route("POST", /^\\/api\\/jobs\\/j_[0-9a-f]+\\/cancel$/, () => { cancels.push(now().job.id); return json({ ...now().job, cancel_requested: true }); });
await import("./js/game.js");
await settle();
const stageText = textOf($("#job-panel .job-stage"));
globalThis.confirmAnswer = false; // the real cancel was sent above
$$("#job-panel button").find((b) => textOf(b) === "Cancel").click();
await settle();
console.log(JSON.stringify({ stageText, confirms, cancels }));
""",
    )
    [question] = out["confirms"]
    _cancel_question_says(question, stage)
    assert out["cancels"] == []
    reports_after = len(client.get(f"/api/games/{game_id}/reports").json())
    if stage in ("gpu_processing", "downloading"):
        assert (done["status"], done["warnings"]) == ("cancelled", [])  # stopped: it can start again
        assert reports_after == reports
    elif stage == "analyzing":
        assert (out["stageText"], done["status"]) == ("Building box score", "succeeded")
        assert done["warnings"] == [LATE_CANCEL_REPORT_SKIPPED]  # finished, without the report
        assert reports_after == reports
    else:
        assert (out["stageText"], done["status"]) == ("Writing scouting report", "succeeded")
        assert done["warnings"] == [LATE_CANCEL]
        assert reports_after == reports + 1  # the report Claude was writing is kept


# ---------------------------------------------------------------------------
# 5. Start again on a cancelled Full re-analysis asks first
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("analysis_loads", [True, False], ids=["results-on-the-page", "analysis-did-not-load"])
def test_start_again_on_a_cancelled_full_reanalysis_asks_first(tmp_path, analysis_loads):
    """ARCHITECTURE (Job lifecycle): "Start again on a cancelled Full re-analysis asks first, like the Full
    re-analysis button (the film goes to the GPU again and the track assignments are cleared)". It posted
    the ANALYZE at once (fails on HEAD). The question is the button's own, with "the current results stay"
    only when the page shows results; declining posts nothing, OK sends the server's retry of the job (round 6:
    POST /api/jobs/{id}/retry, which restarts it with its kind and params)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const analysisLoads = {_js(analysis_loads)};\n"
        + """
const cancelled = job({ kind: "analyze", status: "cancelled", stage: "done", progress: 40, message: "Cancelled" });
let started = false;
gamePageRoutes(route, json, {
  gameBody: () => game({ has_tracking: true, ...(started ? { status: "queued", latest_job_id: "j_2" } : { latest_job_id: "j_1" }) }),
  jobs: [cancelled],
  analysisBody: analysis(),
});
if (!analysisLoads) route("GET", "/api/games/g_1/analysis", fail(500, "INTERNAL_ERROR", "Something went wrong"));
route("GET", "/api/games/g_1/jobs", () => json(started ? [job({ id: "j_2" }), cancelled] : [cancelled]));
route("GET", "/api/jobs/j_2", json(job({ id: "j_2", status: "running", stage: "gpu_processing", progress: 12 })));
route("POST", "/api/games/g_1/jobs", (req) => { posts.push(req.body); started = true; return json(job({ id: "j_2" }), 201); });
const retries = [];
route("POST", "/api/jobs/j_1/retry", (req) => { retries.push(req.path); started = true; return json(job({ id: "j_2" })); });
await import("./js/game.js");
await settle();
globalThis.confirmAnswer = false;
byId("full-analysis-btn").click(); // the Full re-analysis button's question, for comparison
await settle();
const startAgain = () => $$("#job-panel button").find((b) => textOf(b) === "Start again");
const offered = { title: textOf($("#job-panel .notice-title")), buttons: $$("#job-panel button").map(textOf) };
startAgain().click();
await settle();
const declined = { retries: retries.length, buttons: $$("#job-panel button").map(textOf) };
globalThis.confirmAnswer = true;
startAgain()?.click();
await settle();
console.log(JSON.stringify({ offered, confirms, declined, posts, retries, panel: textOf($("#job-panel h2")) }));
""",
    )
    assert out["offered"] == {"title": "Film analysis was cancelled", "buttons": ["Start again"]}
    button_question = out["confirms"][0]
    assert out["confirms"] == [button_question] * 3  # the button's, then Start again's (declined, accepted)
    assert "GPU again" in button_question
    assert "clears the track assignments you made on the Roster page" in button_question
    assert ("current results stay" in button_question) is analysis_loads
    assert out["declined"] == {"retries": 0, "buttons": ["Start again"]}
    assert (out["posts"], out["retries"]) == ([], ["/api/jobs/j_1/retry"])  # round 6: the server's retry
    assert out["panel"] == "Film analysis in progress"


@pytest.mark.parametrize(
    ("game_over", "kind"),
    [
        pytest.param({"status": "uploaded", "has_analysis": False}, "analyze", id="first-analysis"),
        pytest.param({"has_tracking": True}, "reanalyze", id="re-run-analysis"),
    ],
)
def test_guard_start_again_starts_other_cancelled_jobs_at_once(tmp_path, game_over, kind):
    """Guard: a cancelled first analysis (no results to lose) and a cancelled Re-run analysis start again
    at once, without a question, as before."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"""
const cancelled = job({{ kind: {_js(kind)}, status: "cancelled", stage: "done", message: "Cancelled" }});
gamePageRoutes(route, json, {{ gameBody: game({{ ...{_js(game_over)}, latest_job_id: "j_1" }}), jobs: [cancelled], analysisBody: analysis() }});
route("GET", "/api/jobs/j_2", json(job({{ id: "j_2", kind: {_js(kind)}, status: "running", stage: "analyzing", progress: 12 }})));
route("POST", "/api/games/g_1/jobs", (req) => {{ posts.push(req.body); return json(job({{ id: "j_2", kind: req.body.kind }}), 201); }});
const retries = [];
route("POST", "/api/jobs/j_1/retry", (req) => {{ retries.push(req.path); return json(job({{ id: "j_2", kind: {_js(kind)} }})); }});
"""
        + """
await import("./js/game.js");
await settle();
globalThis.confirmAnswer = false; // a question would stop it
$$("#job-panel button").find((b) => textOf(b) === "Start again").click();
await settle();
console.log(JSON.stringify({ confirms, posts, retries }));
""",
    )
    assert out == {"confirms": [], "posts": [], "retries": ["/api/jobs/j_1/retry"]}  # round 6: the server's retry


@pytest.mark.parametrize("earlier_run", [True, False], ids=["full-reanalysis", "first-analysis"])
def test_start_again_after_a_cancel_on_the_gpu_with_the_real_server(tmp_path, scout, earlier_run):  # noqa: F811
    """The seam: an ANALYZE cancelled on the GPU, as the real server leaves it. For a Full re-analysis the
    game keeps its results and track fix, Start again asks the Full re-analysis question first, and what
    it then posts does what that question says: the film goes to the GPU again and the track fix is
    cleared (on HEAD it posted at once). A cancelled first analysis starts again at once (guard)."""
    client = scout.client
    if earlier_run:
        game_id, fix = _analysed_game(scout)
        analysis_job = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    else:
        game_id, fix = _new_game(scout), None
        analysis_job = _upload_film(client, game_id, auto_start=True)["job"]
    scout.hooks["gpu_processing"] = lambda: client.post(f"/api/jobs/{analysis_job['id']}/cancel")
    scout.worker.run_once(timeout=0.5)
    cancelled = client.get(f"/api/jobs/{analysis_job['id']}").json()
    assert (cancelled["kind"], cancelled["status"]) == ("analyze", "cancelled")
    overrides = client.get(f"/api/games/{game_id}/tracks").json()["overrides"]
    assert [o["track_id"] for o in overrides] == ([fix["track_id"]] if fix else [])

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const phases = {{ during: {_for_page(_bodies(scout, game_id, cancelled['id']), game_id)} }};\n"
        + GAME_PAGE_JS
        + """
await import("./js/game.js");
await settle();
const seen = look();
globalThis.confirmAnswer = false;
if (!byId("full-analysis-btn").hidden) byId("full-analysis-btn").click(); // its question, for comparison
await settle();
const startAgain = () => $$("#job-panel button").find((b) => textOf(b) === "Start again");
startAgain().click();
await settle();
const declined = retries.length;
globalThis.confirmAnswer = true;
startAgain()?.click();
await settle();
console.log(JSON.stringify({ seen, confirms, declined, posts, retries }));
""",
    )
    seen = out["seen"]
    assert (seen["panel"], seen["panelButtons"]) == ("Film analysis was cancelled", ["Start again"])
    assert (out["posts"], out["retries"]) == ([], [cancelled["id"]])  # round 6: the server's retry
    if earlier_run:
        assert seen["header"] == ["Re-run analysis", False, True]
        button_question = out["confirms"][0]
        assert out["confirms"] == [button_question] * 3  # the button's, then Start again's (declined, accepted)
        assert "current results stay" in button_question
        assert out["declined"] == 0
    else:
        assert seen["header"] == ["Analyze film", False, False]
        assert (out["confirms"], out["declined"]) == ([], 1)

    # What the page sends, as the real server runs it: an ANALYZE again.
    gpu_runs = list(scout.gpu_runs)
    started = client.post(f"/api/jobs/{out['retries'][0]}/retry")
    assert started.status_code == 200, started.text
    assert started.json()["kind"] == "analyze"
    assert _run(scout, started.json())["status"] == "succeeded"
    assert scout.gpu_runs == [*gpu_runs, started.json()["id"]]  # the film went to the GPU again
    assert client.get(f"/api/games/{game_id}/tracks").json()["overrides"] == []  # the track fix went
