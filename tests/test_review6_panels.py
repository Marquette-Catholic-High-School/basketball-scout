"""Sixth review round: the game page's panels, the games list and the report tab.

They run the real pages in the node fake-DOM harness of ``tests/test_review_frontend.py`` (with the probes
of ``tests/test_review2_frontend.py``). The seam tests feed them the real API's bodies, with an in-process
worker in demo mode (``tests/test_review4_integration.py``), and replay on that server what the page sent.

* One rule for "too late to cancel" (docs/ARCHITECTURE.md, "Job lifecycle"): a cancel no longer stops an
  ANALYZE or REANALYZE at ``analyzing`` or ``reporting``, or a REPORT at ``reporting``
  (``scout.schemas.cancel_stops_job``, mirrored by ``tooLateToStop`` in ``static/js/labels.js``). No page
  says "Cancelling…" for such a job: the pages show its stage and "Cancel requested". The job panel's Cancel
  confirm says what the cancel still does, in words that hold whether or not a report is due.
* The game page offers Re-run analysis and Full re-analysis whenever ``Game.has_tracking`` is true (Analyze
  film otherwise), also when a cancel or a failure left the game without an analysis ("Extra rules", Full
  re-analysis).
* Retry on a Full re-analysis that failed before its new results were installed asks first, like the Full
  re-analysis button and Start again on a cancelled one.
* Start again restarts a cancelled job with its kind and params (``POST /api/jobs/{id}/retry``).
"""

from __future__ import annotations

import json

import pytest

from scout.errors import ErrorCode
from scout.reporting import claude_report
from tests.test_review2_frontend import CALIBRATION_JS, GAME_JS
from tests.test_review3_integration import _upload_film
from tests.test_review4_integration import (  # noqa: F401 - the scout fixture
    GAME_PAGE_JS,
    _analysed_game,
    _bodies,
    _failing_once,
    _for_page,
    _new_game,
    _run,
    scout,
)
from tests.test_review5_integration import LATE_CANCEL_JS
from tests.test_review5_panels import CALIBRATE_JS
from tests.test_review5_verify_panels import _gpu_fails_once
from tests.test_review_frontend import run_page

STOP_QUESTION = "Stop this job? You can start it again later."
# The job panel's Cancel confirm for a job a cancel no longer stops (static/js/jobpanel.js, cancelQuestion).
ANALYSIS_QUESTION = (
    "Too late to stop the analysis: the new GPU results are already in place, so it will finish.\n\n"
    "Cancelling now only skips the automatic scouting report, if one was going to be written."
)
REPORTING_QUESTION = (
    "Too late to cancel: the analysis is finished and Claude is already writing the scouting report.\n\n"
    "The job will finish on its own, and the report is kept."
)
RERUN_STARTED = (
    "Too late to stop the re-analysis: it is already redoing the stats (about a minute), so it will finish.\n\n"
)
RERUN_QUESTION = RERUN_STARTED + "There is nothing left to cancel."
RERUN_REPORT_QUESTION = RERUN_STARTED + "Cancelling now only skips the automatic scouting report."
REPORT_QUESTION = (
    "Too late to cancel: Claude is already writing the scouting report.\n\n"
    "It will finish on its own, and the report is kept."
)
# The job's message after a cancel request (docs/ARCHITECTURE.md, "Job lifecycle").
CANCELLING_MESSAGE = "Cancelling..."
TOO_LATE_MESSAGE = "Cancel requested: too late to stop this job, so it will finish."
# The job warnings for a late cancel of a REANALYZE (docs/ARCHITECTURE.md, "Job lifecycle").
RERUN_LATE_CANCEL = "Cancelled after the analysis had started: the analysis was finished."
RERUN_LATE_CANCEL_REPORT_SKIPPED = (
    "Cancelled after the analysis had started: the analysis was finished, the scouting report was skipped."
)
REPORT_LATE_CANCEL = "Cancelled after Claude had started writing the report: the report was kept."
STAGE_LABELS = {"analyzing": "Building box score", "reporting": "Writing scouting report"}
PLAYER_FOCUS = "Watch how they break the press"


def _js(value: object) -> str:
    return json.dumps(value)


def _is_full_run_question(question: str, *, results_on_the_page: bool) -> bool:
    """The Full re-analysis button's question (game.js fullRunConfirm)."""
    return (
        question.startswith("Send the film to the GPU again?")
        and ("The current results stay on this page until it finishes." in question) is results_on_the_page
        and "it clears the track assignments you made on the Roster page" in question
    )


# Records the job panel's Start again / Retry requests (POST /api/jobs/{id}/retry), answered 503, as
# GAME_PAGE_JS does for the seam tests.
RETRIES_JS = """
const retries = [];
route("POST", /^\\/api\\/jobs\\/j_[0-9a-f]+\\/retry$/, (req) => {
  retries.push(req.path.split("/")[3]);
  return fail(503, "QUEUE_UNAVAILABLE", "Not here");
});
"""


# ---------------------------------------------------------------------------
# 1. One rule for "too late to cancel", and no "Cancelling…" for such a job
# ---------------------------------------------------------------------------


def test_too_late_to_stop_is_the_servers_rule(tmp_path):
    """ARCHITECTURE (Job lifecycle): scout.schemas.cancel_stops_job, "mirrored by tooLateToStop in
    static/js/labels.js". The pages had their own rule, in the job panel and for an ANALYZE only (fails on
    HEAD: labels.js exports no tooLateToStop). Every kind at every stage."""
    from scout.schemas import JobKind, JobStage, cancel_stops_job

    cases = [[kind.value, stage.value] for kind in JobKind for stage in JobStage]
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        f"const cases = {_js(cases)};\n"
        + """
const { tooLateToStop } = await import("./js/labels.js");
console.log(JSON.stringify({ late: cases.map(([kind, stage]) => tooLateToStop({ kind, stage, status: "running" })) }));
""",
    )
    expected = {(kind, stage): not cancel_stops_job(JobKind(kind), JobStage(stage)) for kind, stage in cases}
    assert dict(zip(expected, out["late"], strict=True)) == expected


# (kind, stage): what jobStageText says once a cancel was requested.
STAGE_TEXT_AFTER_A_CANCEL = {
    ("analyze", "queued"): "Cancelling…",
    ("analyze", "preparing"): "Cancelling…",
    ("analyze", "uploading_to_gpu"): "Cancelling…",
    ("analyze", "gpu_processing"): "Cancelling…",
    ("analyze", "downloading_results"): "Cancelling…",
    ("analyze", "analyzing"): "Building box score",
    ("analyze", "reporting"): "Writing scouting report",
    ("reanalyze", "queued"): "Cancelling…",
    ("reanalyze", "analyzing"): "Building box score",
    ("reanalyze", "reporting"): "Writing scouting report",
    ("report", "queued"): "Cancelling…",
    ("report", "reporting"): "Writing scouting report",
}


def test_job_stage_text_keeps_the_stage_of_a_job_a_cancel_no_longer_stops(tmp_path):
    """ARCHITECTURE (Job lifecycle): "no page says 'Cancelling…' for it: the pages show its stage". jobStageText
    said "Cancelling…" for every job with a cancel request (fails on HEAD for the analyzing and reporting
    stages of every kind); a job a cancel still stops keeps "Cancelling…" (guards)."""
    cases = [list(key) for key in STAGE_TEXT_AFTER_A_CANCEL]
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        f"const cases = {_js(cases)};\n"
        + """
const { jobStageText } = await import("./js/labels.js");
console.log(JSON.stringify({ texts: cases.map(([kind, stage]) => jobStageText(job({ kind, stage, status: "running",
  progress: 60, cancel_requested: true }))) }));
""",
    )
    assert dict(zip(STAGE_TEXT_AFTER_A_CANCEL, out["texts"], strict=True)) == STAGE_TEXT_AFTER_A_CANCEL


# The game page's job panel on a running KIND job at STAGE with PARAMS; the coach declines the Cancel confirm,
# then accepts it, and the polls show the job with its cancel request and the server's message for it.
JOB_PANEL_CANCEL_JS = """
const running = job({ kind: KIND, status: "running", stage: STAGE, progress: 80, params: PARAMS,
  message: "Building the timeline, plays and box score" });
let requested = false;
const now = () => (requested ? { ...running, cancel_requested: true, message: MESSAGE } : running);
gamePageRoutes(route, json, { gameBody: game({ status: "processing", has_tracking: true, latest_job_id: "j_1" }),
  jobs: [running], analysisBody: analysis() });
route("GET", "/api/jobs/j_1", () => json(now()));
let cancels = 0;
route("POST", "/api/jobs/j_1/cancel", () => { cancels += 1; requested = true; return json(now()); });
await import("./js/game.js");
await settle();
const panel = () => ({
  stage: textOf($("#job-panel .job-stage")),
  button: [textOf($("#job-panel .card-head button")), $("#job-panel .card-head button").disabled],
  details: textOf($("#job-panel .job-details")),
  text: textOf(byId("job-panel")),
});
const cancel = () => $$("#job-panel button").find((b) => textOf(b) === "Cancel");
globalThis.confirmAnswer = false;
cancel().click();
await settle();
const declined = { cancels, ...panel() };
globalThis.confirmAnswer = true;
cancel().click();
await settle();
console.log(JSON.stringify({ confirms, declined, cancels, after: panel() }));
"""

CANCEL_CASES = [
    pytest.param("analyze", "preparing", {}, STOP_QUESTION, id="analyze-preparing"),
    pytest.param("analyze", "uploading_to_gpu", {}, STOP_QUESTION, id="analyze-uploading"),
    pytest.param("analyze", "gpu_processing", {}, STOP_QUESTION, id="analyze-on-the-gpu"),
    pytest.param("analyze", "downloading_results", {}, STOP_QUESTION, id="analyze-downloading"),
    pytest.param("analyze", "analyzing", {}, ANALYSIS_QUESTION, id="analyze-building-the-box-score"),
    pytest.param("analyze", "reporting", {}, REPORTING_QUESTION, id="analyze-writing-the-report"),
    pytest.param("reanalyze", "queued", {}, STOP_QUESTION, id="reanalyze-claimed"),
    pytest.param("reanalyze", "analyzing", {}, RERUN_QUESTION, id="reanalyze-no-report"),
    pytest.param(
        "reanalyze", "analyzing", {"report": True, "coach_focus": PLAYER_FOCUS}, RERUN_REPORT_QUESTION,
        id="reanalyze-report-to-write",
    ),
    pytest.param("reanalyze", "reporting", {"report": True}, REPORTING_QUESTION, id="reanalyze-writing-the-report"),
]


@pytest.mark.parametrize(("kind", "stage", "params", "question"), CANCEL_CASES)
def test_job_panel_cancel_confirm_and_what_the_panel_says_after_it(tmp_path, kind, stage, params, question):
    """ARCHITECTURE (Job lifecycle): "The job panel's Cancel confirm says what a cancel still does to such a job,
    in words that hold whether or not a report is due", and after the cancel request "the pages show its stage
    and 'Cancel requested'". A REANALYZE always asked "Stop this job?" and the panel then said "Cancelling…"
    on its stage line and button and showed the server's message (fails on HEAD). The ANALYZE question at
    analyzing promised that the cancel skips the automatic report, which there is none of without a Claude
    key or with SCOUT_AUTO_REPORT=false (fails on HEAD). A cancel that still stops the job keeps "Stop this
    job?" and "Cancelling…", and the ANALYZE question at reporting is unchanged (guards). Declining sends
    nothing."""
    late = question != STOP_QUESTION
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const KIND = {_js(kind)};\nconst STAGE = {_js(stage)};\nconst PARAMS = {_js(params)};\n"
        + f"const MESSAGE = {_js(TOO_LATE_MESSAGE if late else CANCELLING_MESSAGE)};\n"
        + JOB_PANEL_CANCEL_JS,
    )
    assert out["confirms"] == [question, question]
    assert (out["declined"]["cancels"], out["declined"]["button"]) == (0, ["Cancel", False])
    after = out["after"]
    assert out["cancels"] == 1
    if late:
        assert (after["stage"], after["button"]) == (STAGE_LABELS[stage], ["Cancel requested", True])
        assert "Cancelling" not in after["text"], after["text"]
        assert after["details"] == "80% overall"  # not the server's message: the button says it
    else:
        assert (after["stage"], after["button"]) == ("Cancelling…", ["Cancelling…", True])


@pytest.mark.parametrize(
    ("stage", "question", "after"),
    [
        pytest.param(
            "reporting", REPORT_QUESTION, ["Writing scouting report", "Cancel requested"], id="claude-writing"
        ),
        pytest.param("queued", STOP_QUESTION, ["Cancelling…", "Cancelling…"], id="claimed-not-started"),
    ],
)
def test_job_panel_with_a_report_job(tmp_path, stage, question, after):
    """The same rule for a REPORT job in the job panel (ARCHITECTURE: "a REPORT at reporting"): Claude is already
    writing it, so the question says it will finish and be kept, and the panel then shows its stage and "Cancel
    requested" (fails on HEAD: "Stop this job?", then "Cancelling…"). Before Claude starts, a cancel stops it
    (guard). The game page shows only analysis jobs in its panel, so the panel is built on its own here."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const STAGE = {_js(stage)};\n"
        + f"const MESSAGE = {_js(TOO_LATE_MESSAGE if stage == 'reporting' else CANCELLING_MESSAGE)};\n"
        + """
const running = job({ id: "j_r", kind: "report", status: "running", stage: STAGE, progress: 60 });
let requested = false;
const now = () => (requested ? { ...running, cancel_requested: true, message: MESSAGE } : running);
route("GET", "/api/jobs/j_r", () => json(now()));
route("POST", "/api/jobs/j_r/cancel", () => { requested = true; return json(now()); });
const { JobPanel } = await import("./js/jobpanel.js");
const panel = new JobPanel({ onChange() {} });
panel.show(running);
await settle();
$$("#job-panel button").find((b) => textOf(b) === "Cancel").click();
await settle();
console.log(JSON.stringify({ confirms, after: [textOf($("#job-panel .job-stage")), textOf($("#job-panel .card-head button"))],
  text: textOf(byId("job-panel")) }));
""",
    )
    assert out["confirms"] == [question]
    assert out["after"] == after
    if stage == "reporting":
        assert "Cancelling" not in out["text"], out["text"]


# Analysis jobs on the games list, each the latest job of its own game: (kind, stage, the job's message or None
# for a cancel request with the server's message for it, what the list says).
GAMES_LIST_CASES = [
    ("analyze", "queued", None, "Cancelling… · 40%"),
    ("analyze", "gpu_processing", None, "Cancelling… · 40%"),
    ("analyze", "downloading_results", None, "Cancelling… · 40%"),
    ("analyze", "analyzing", None, "Building box score · 40% · Cancel requested"),
    ("analyze", "reporting", None, "Writing scouting report · 40% · Cancel requested"),
    ("reanalyze", "queued", None, "Cancelling… · 40%"),
    ("reanalyze", "analyzing", None, "Building box score · 40% · Cancel requested"),
    ("reanalyze", "reporting", None, "Writing scouting report · 40% · Cancel requested"),
    ("analyze", "gpu_processing", "On the GPU", "Analyzing on the GPU (40%) · 40% · On the GPU"),
    ("reanalyze", "analyzing", "Building the box score", "Building box score · 40% · Building the box score"),
]


def test_games_list_shows_the_stage_and_cancel_requested(tmp_path):
    """ARCHITECTURE (Job lifecycle): the games list said "Cancelling… · 40% · Cancelling..." for a job with a cancel
    request, also for one a cancel no longer stops (fails on HEAD). It now shows such a job's stage and "Cancel
    requested", and "Cancelling…" once (not the server's "Cancelling..." again) for a job the cancel stops. A job
    without a cancel request keeps its message (guards). REPORT jobs are never a game's latest job here."""
    jobs = [
        {"kind": kind, "stage": stage, "cancel_requested": message is None,
         "message": message or (TOO_LATE_MESSAGE if stage in STAGE_LABELS else CANCELLING_MESSAGE)}
        for kind, stage, message, _text in GAMES_LIST_CASES
    ]
    out = run_page(
        tmp_path,
        "index.html",
        "/",
        f"const jobs = {_js(jobs)};\n"
        + """
const games = jobs.map((over, i) => game({ id: `g_${i + 1}`, status: "processing", latest_job_id: `j_${i + 1}`,
  display_title: `Game ${i + 1}` }));
route("GET", "/api/games", json(games));
jobs.forEach((over, i) => route("GET", `/api/jobs/j_${i + 1}`, json(job({ id: `j_${i + 1}`, game_id: `g_${i + 1}`,
  status: "running", progress: 40, ...over }))));
route("GET", "/api/health", json({ status: "ok", version: "1", processor: "mock", queue_backend: "sqlite", queue_ok: true,
  worker_last_seen_s: 5, claude_configured: true, ffmpeg_available: true }));
await import("./js/index.js");
await settle();
console.log(JSON.stringify({ texts: $$("#games-list .progress-text").map(textOf) }));
""",
    )
    assert out["texts"] == [text for *_case, text in GAMES_LIST_CASES]


@pytest.mark.parametrize(
    ("stage", "requested", "status"),
    [
        pytest.param(
            "reporting", True, "Writing scouting report… Cancel requested: Claude is already writing it, so it will "
            "finish and be kept.", id="cancel-while-claude-writes",
        ),
        pytest.param("queued", True, "Cancelling…", id="cancel-before-claude-starts"),
        pytest.param(
            "reporting", False, "Writing scouting report… This usually takes one to three minutes.", id="no-cancel",
        ),
    ],
)
def test_report_tab_shows_the_stage_and_cancel_requested(tmp_path, stage, requested, status):
    """ARCHITECTURE (Job lifecycle): the report tab said "Cancelling…… This usually takes one to three minutes."
    for a REPORT job with a cancel request, also once Claude was writing it, when the report is finished and
    kept (fails on HEAD). Before Claude starts, a cancel stops it: "Cancelling…", without a second ellipsis or
    the time it takes (fails on HEAD). Without a cancel request it is unchanged (guard)."""
    message = (TOO_LATE_MESSAGE if stage == "reporting" else CANCELLING_MESSAGE) if requested else ""
    writing = {"id": "j_r", "kind": "report", "status": "running", "stage": stage, "progress": 60,
               "cancel_requested": requested, "message": message}
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const writing = job({_js(writing)});\n"
        + """
gamePageRoutes(route, json, { gameBody: game({ has_tracking: true }), jobs: [writing], analysisBody: analysis() });
route("GET", "/api/jobs/j_r", json(writing));
await import("./js/game.js");
await settle();
console.log(JSON.stringify({ status: textOf(byId("report-status")), generate: byId("report-generate").disabled }));
""",
    )
    assert out == {"status": status, "generate": True}


@pytest.mark.parametrize(
    ("report", "stage", "question", "warning", "reports_added"),
    [
        pytest.param(False, "analyzing", RERUN_QUESTION, RERUN_LATE_CANCEL, 0, id="re-run-analysis"),
        pytest.param(
            True, "analyzing", RERUN_REPORT_QUESTION, RERUN_LATE_CANCEL_REPORT_SKIPPED, 0, id="report-to-write"
        ),
        pytest.param(True, "reporting", REPORTING_QUESTION, RERUN_LATE_CANCEL, 1, id="claude-writing-the-report"),
    ],
)
def test_a_late_cancel_of_a_reanalyze_does_what_the_question_said(
    tmp_path, scout, monkeypatch, report, stage, question, warning, reports_added  # noqa: F811
):
    """The seam: a REANALYZE as the real server shows it at ``stage`` (the header's Re-run analysis, or the retry of
    an ANALYZE that failed after the GPU, which writes the report), the question the page asks there, what the
    panel and the games list say after the coach's OK, and what the worker then does with that cancel: the
    analysis is finished, the report not started yet is skipped and one Claude is writing is kept, with the job
    warning (fails on HEAD: "Stop this job?", "Cancelling…", and the job ended cancelled after its analysis)."""
    client = scout.client
    if report:
        game_id = _new_game(scout)
        _failing_once(monkeypatch, ErrorCode.CONFIG_INVALID)
        failed = _run(scout, _upload_film(client, game_id, auto_start=True)["job"])
        assert (failed["status"], failed["stage"]) == ("failed", "analyzing")
        rerun = client.post(f"/api/jobs/{failed['id']}/retry").json()
        assert (rerun["kind"], rerun["params"]) == ("reanalyze", {"report": True})
    else:
        game_id, _fix = _analysed_game(scout)
        rerun = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json()
    reports = len(client.get(f"/api/games/{game_id}/reports").json())
    seen: dict[str, object] = {}

    def cancel() -> None:
        seen["during"] = _bodies(scout, game_id, rerun["id"])  # the page the coach clicks Cancel on
        seen["cancelled"] = client.post(f"/api/jobs/{rerun['id']}/cancel").json()  # the coach's OK
        seen["after"] = _bodies(scout, game_id, rerun["id"])  # the polls while it carries on

    scout.hooks[stage] = cancel
    scout.worker.run_once(timeout=0.5)
    assert scout.hooks == {} and "after" in seen
    ended = _bodies(scout, game_id, rerun["id"])
    phases = {"during": seen["during"], "after": seen["after"], "ended": ended}

    out = run_page(
        tmp_path / "game",
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const phases = {_for_page(phases, game_id)};\n"
        + f"const cancelled = {_for_page(seen['cancelled'], game_id)};\n"
        + GAME_PAGE_JS
        + LATE_CANCEL_JS,
    )
    assert out["confirms"] == [question]
    assert out["before"]["stage"] == STAGE_LABELS[stage]
    after = out["after"]
    assert (after["stage"], after["button"]) == (STAGE_LABELS[stage], ["Cancel requested", True])
    assert "Cancelling" not in after["text"], after["text"]
    assert out["ended"]["panel"] == "Re-analysis finished with warnings"
    assert out["ended"]["panelText"].endswith(warning)
    done = ended["job"]
    assert (done["status"], done["warnings"]) == ("succeeded", [warning])
    assert len(client.get(f"/api/games/{game_id}/reports").json()) == reports + reports_added

    # The games list, polled while it carries on (once its analysis is saved the game is ready: no progress there).
    listed = seen["after"]["game"]
    assert listed["status"] == ("processing" if stage == "analyzing" else "ready")
    if stage != "analyzing":
        return
    out = run_page(
        tmp_path / "list",
        "index.html",
        "/",
        f"const listed = {_for_page(listed, game_id)};\nconst polled = {_for_page(seen['after']['job'], game_id)};\n"
        + """
route("GET", "/api/games", json([listed]));
route("GET", /^\\/api\\/jobs\\/j_[0-9a-f]+$/, json(polled));
route("GET", "/api/health", json({ status: "ok", version: "1", processor: "mock", queue_backend: "sqlite", queue_ok: true,
  worker_last_seen_s: 5, claude_configured: true, ffmpeg_available: true }));
await import("./js/index.js");
await settle();
console.log(JSON.stringify({ text: textOf($("#games-list .progress-text")) }));
""",
    )
    assert out["text"].startswith(f"{STAGE_LABELS[stage]} · ")
    assert out["text"].endswith(" · Cancel requested")


def test_a_late_cancel_of_a_report_keeps_it_as_the_report_tab_says(tmp_path, scout):  # noqa: F811
    """The seam for a REPORT: cancelled while Claude writes it, as the real server shows it, the report tab says it
    will finish and be kept (on HEAD: "Cancelling…… This usually takes one to three minutes."), and the worker
    keeps the report, with the job warning."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    reports = len(client.get(f"/api/games/{game_id}/reports").json())
    writing = client.post(f"/api/games/{game_id}/reports", json={}).json()
    seen: dict[str, object] = {}

    def cancel() -> None:
        assert client.post(f"/api/jobs/{writing['id']}/cancel").status_code == 200
        seen["after"] = _bodies(scout, game_id, writing["id"])  # the polls while Claude writes it

    scout.hooks["reporting"] = cancel
    scout.worker.run_once(timeout=0.5)
    assert scout.hooks == {} and "after" in seen
    done = client.get(f"/api/jobs/{writing['id']}").json()
    assert (done["status"], done["warnings"]) == ("succeeded", [REPORT_LATE_CANCEL])
    assert len(client.get(f"/api/games/{game_id}/reports").json()) == reports + 1

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const phases = {{ during: {_for_page(seen['after'], game_id)} }};\n"
        + GAME_PAGE_JS
        + """
await import("./js/game.js");
await settle();
console.log(JSON.stringify({ status: textOf(byId("report-status")), panel: textOf(byId("job-panel")) }));
""",
    )
    assert out["status"] == (
        "Writing scouting report… Cancel requested: Claude is already writing it, so it will finish and be kept."
    )
    assert "Cancelling" not in out["panel"]


# ---------------------------------------------------------------------------
# 2. Re-run analysis whenever the GPU results are on the server
# ---------------------------------------------------------------------------

FAILED_PAST_THE_GPU = {"id": "j_1", "kind": "analyze", "status": "failed", "stage": "analyzing", "progress": 75}
# The game shapes: the Game body and the jobs (newest first), as the server leaves them.
SHAPES = {
    # A Full re-analysis started after an earlier run failed past the GPU, cancelled before its install.
    "full-reanalysis-cancelled-after-a-failure-past-the-gpu": (
        {"status": "uploaded", "has_analysis": False, "has_tracking": True, "latest_job_id": "j_2"},
        [{"id": "j_2", "kind": "analyze", "status": "cancelled", "stage": "done", "message": "Cancelled"},
         FAILED_PAST_THE_GPU],
    ),
    # Its Retry (a REANALYZE, with the report the ANALYZE would have written) cancelled while queued.
    "re-run-cancelled-while-queued": (
        {"status": "uploaded", "has_analysis": False, "has_tracking": True, "latest_job_id": "j_2"},
        [{"id": "j_2", "kind": "reanalyze", "status": "cancelled", "stage": "done", "message": "Cancelled",
          "params": {"report": True}}, FAILED_PAST_THE_GPU],
    ),
    "never-analysed": ({"status": "uploaded", "has_analysis": False, "has_tracking": False}, []),
    # A new film after that failure deleted its tracking; the new film's analysis was cancelled while queued.
    "new-film": (
        {"status": "uploaded", "has_analysis": False, "has_tracking": False, "latest_job_id": "j_2"},
        [{"id": "j_2", "kind": "analyze", "status": "cancelled", "stage": "done", "message": "Cancelled"},
         FAILED_PAST_THE_GPU],
    ),
}

# Saves a calibration, then clicks the header's button and the calibration result's (job posts answered 503),
# then Start again (declined). ``retries`` has the Start again requests.
HEADER_AND_CALIBRATION_JS = """
await import("./js/game.js");
await settle();
const seen = {
  header: [textOf(byId("reanalyze-btn")), byId("reanalyze-btn").disabled, !byId("full-analysis-btn").hidden],
  pending: $$("#analysis-pending .notice p").map(textOf),
};
byId("reanalyze-btn").click();
await settle();
seen.headerPosts = posts.splice(0);
await saveCalibration();
seen.calibration = resultButtons();
$$("#cal-result button")[0].click();
await settle();
seen.calibrationPosts = posts.splice(0);
globalThis.confirmAnswer = false;
const startAgain = $$("#job-panel button").find((b) => textOf(b) === "Start again");
if (startAgain) startAgain.click();
await settle();
seen.startAgain = { offered: Boolean(startAgain), confirms: confirms.splice(0), retries: retries.splice(0) };
console.log(JSON.stringify(seen));
"""

PENDING_SAVED = [
    "The GPU results for this film are saved, but the stats have not been built from them yet.",
    "Click Re-run analysis to build them on this server (about a minute, no GPU).",
]
PENDING_NEW = ["This film hasn't been analyzed yet.", "Click Analyze film to send it to the GPU."]


@pytest.mark.parametrize("shape", list(SHAPES))
def test_header_and_calibration_offer_re_run_analysis_whenever_the_gpu_results_are_saved(tmp_path, shape):
    """ARCHITECTURE (Extra rules, Full re-analysis): "The game page offers Re-run analysis and Full re-analysis
    whenever has_tracking is true (Analyze film otherwise)." The page guessed from has_analysis and the latest
    job, so a game left uploaded without an analysis but with its GPU results (a Full re-analysis cancelled after
    a failure past the GPU, or the Re-run analysis retried from that failure, cancelled while queued) offered
    Analyze film, a new GPU run, in the header and the calibration result, and Start again on that Full
    re-analysis asked nothing (both fail on HEAD). The notice under the header named Analyze film too. A game
    never analysed, and one with a new film, keep Analyze film (guards; the new film's Start again fails on HEAD
    only because it now sends the server's retry, item 4)."""
    game_over, jobs = SHAPES[shape]
    saved = game_over["has_tracking"]
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + f"const jobs = {_js(jobs)}.map((over) => job(over));\n"
        + f"gamePageRoutes(route, json, {{ gameBody: game({_js(game_over)}), jobs, analysisBody: analysis() }});\n"
        + """
route("GET", /^\\/api\\/jobs\\/j_\\d+$/, (req) => json(jobs.find((j) => j.id === req.path.split("/").pop())));
route("POST", "/api/games/g_1/jobs", (req) => { posts.push(req.body); return fail(503, "QUEUE_UNAVAILABLE", "Not here"); });
"""
        + RETRIES_JS
        + CALIBRATE_JS
        + HEADER_AND_CALIBRATION_JS,
    )
    label, kind = ("Re-run analysis", "reanalyze") if saved else ("Analyze film", "analyze")
    assert out["header"] == [label, False, saved]  # Full re-analysis beside it with the GPU results saved
    assert out["pending"] == (PENDING_SAVED if saved else PENDING_NEW)
    assert out["headerPosts"] == [{"kind": kind}]
    assert out["calibration"] == [label]
    assert out["calibrationPosts"] == [{"kind": kind}]
    start_again = out["startAgain"]
    assert start_again["offered"] is bool(jobs)
    if shape == "full-reanalysis-cancelled-after-a-failure-past-the-gpu":  # a GPU run that clears the track fixes
        [question] = start_again["confirms"]
        assert _is_full_run_question(question, results_on_the_page=False), question
        assert start_again["retries"] == []  # declined
    elif jobs:  # a Re-run analysis, or a first analysis of the new film: at once
        assert start_again == {"offered": True, "confirms": [], "retries": ["j_2"]}


@pytest.mark.parametrize(
    ("kind", "stage", "hint"),
    [
        pytest.param("reanalyze", "analyzing", "Re-run analysis takes about a minute on this server.", id="re-run"),
        pytest.param(
            "analyze", "gpu_processing", "Long games can take 30-60 minutes on the GPU.", id="full-reanalysis"
        ),
    ],
)
def test_a_re_run_on_a_game_without_an_analysis_says_it_takes_about_a_minute(tmp_path, kind, stage, hint):
    """Extra: while the Re-run analysis the page now offers for such a game runs, the notice under the header said
    "Long games can take 30-60 minutes on the GPU" (fails on HEAD). A GPU run keeps that hint (guard)."""
    running = {"id": "j_3", "kind": kind, "status": "running", "stage": stage, "progress": 20}
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const running = job({_js(running)});\n"
        + """
gamePageRoutes(route, json, { gameBody: game({ status: "processing", has_analysis: false, has_tracking: true, latest_job_id: "j_3" }),
  jobs: [running] });
route("GET", "/api/jobs/j_3", json(running));
await import("./js/game.js");
await settle();
console.log(JSON.stringify({ pending: $$("#analysis-pending .notice p").map(textOf) }));
""",
    )
    assert out["pending"] == ["Results will appear here when the analysis finishes.", hint]


@pytest.mark.parametrize(
    "shape", ["full-reanalysis-cancelled-after-a-failure-past-the-gpu", "re-run-cancelled-while-queued"]
)
def test_gpu_results_without_an_analysis_with_the_real_server(tmp_path, scout, monkeypatch, shape):  # noqa: F811
    """The seam: the two shapes as the real API and worker leave them (a first analysis failed after the GPU, then a
    Full re-analysis, or its Retry, cancelled while queued): the game is uploaded, without an analysis, with
    has_tracking. The header and the calibration offer Re-run analysis (on HEAD: Analyze film), Start again on the
    Full re-analysis asks first, and what the header posts only redoes the stats here, without a GPU run."""
    client = scout.client
    game_id = _new_game(scout)
    _failing_once(monkeypatch, ErrorCode.CONFIG_INVALID)
    failed = _run(scout, _upload_film(client, game_id, auto_start=True)["job"])
    assert (failed["status"], failed["stage"]) == ("failed", "analyzing")
    if shape.startswith("full"):
        queued = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    else:
        queued = client.post(f"/api/jobs/{failed['id']}/retry").json()
        assert queued["kind"] == "reanalyze"
    assert client.post(f"/api/jobs/{queued['id']}/cancel").json()["status"] == "cancelled"  # at once
    bodies = _bodies(scout, game_id, queued["id"])
    game = bodies["game"]
    assert (game["status"], game["has_analysis"], game["has_tracking"]) == ("uploaded", False, True)

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + f"const phases = {{ during: {_for_page(bodies, game_id)} }};\n"
        + GAME_PAGE_JS
        + CALIBRATE_JS
        + HEADER_AND_CALIBRATION_JS,
    )
    assert out["header"] == ["Re-run analysis", False, True]
    assert out["pending"] == PENDING_SAVED
    assert out["headerPosts"] == out["calibrationPosts"] == [{"kind": "reanalyze"}]
    assert out["calibration"] == ["Re-run analysis"]
    start_again = out["startAgain"]
    if shape.startswith("full"):
        [question] = start_again["confirms"]
        assert _is_full_run_question(question, results_on_the_page=False), question
        assert start_again["retries"] == []
    else:
        assert (start_again["confirms"], start_again["retries"]) == ([], [queued["id"]])

    # What the header posts, as the real server runs it: the stats from the saved GPU results, no GPU run.
    gpu_runs = list(scout.gpu_runs)
    started = client.post(f"/api/games/{game_id}/jobs", json=out["headerPosts"][0])
    assert started.status_code == 201, started.text
    assert _run(scout, started.json())["status"] == "succeeded"
    assert scout.gpu_runs == gpu_runs
    assert client.get(f"/api/games/{game_id}").json()["has_analysis"] is True


# ---------------------------------------------------------------------------
# 3. Retry on a Full re-analysis that failed before its new results were installed asks first
# ---------------------------------------------------------------------------

# The game page with its latest job failed (FAILED, on GAME); Retry is clicked with the coach declining, then
# accepting any question. The retry answers with a new job of RETRIED_KIND.
RETRY_JS = """
const failed = job({ id: "j_1", status: "failed", progress: 30, ...FAILED,
  error: { code: "PIPELINE_FAILED", title: "The GPU analysis failed", message: "It stopped.", hint: null, retryable: true, detail: null } });
let retried = null;
gamePageRoutes(route, json, { gameBody: () => game(retried ? { status: "queued", latest_job_id: "j_2" } : GAME),
  jobs: [], analysisBody: analysis() });
route("GET", "/api/games/g_1/jobs", () => json(retried ? [retried, failed] : [failed]));
route("GET", "/api/jobs/j_1", json(failed));
route("GET", "/api/jobs/j_2", () => json({ ...retried, status: "running", stage: "analyzing", progress: 50 }));
const retries = [];
route("POST", "/api/jobs/j_1/retry", (req) => {
  retries.push(req.path);
  retried = job({ id: "j_2", kind: RETRIED_KIND });
  return json(retried);
});
route("POST", "/api/games/g_1/jobs", (req) => { posts.push(req.body); return fail(503, "QUEUE_UNAVAILABLE", "Not here"); });
await import("./js/game.js");
await settle();
const offered = $$("#job-panel button").map(textOf);
const retry = () => $$("#job-panel button").find((b) => ["Retry", "Re-run analysis"].includes(textOf(b)));
globalThis.confirmAnswer = false;
retry().click();
await settle();
const declined = { retries: retries.length, buttons: $$("#job-panel button").map(textOf) };
globalThis.confirmAnswer = true;
retry()?.click();
await settle();
console.log(JSON.stringify({ offered, confirms, declined, retries, posts, panel: textOf($("#job-panel h2")) }));
"""


@pytest.mark.parametrize("analysis_loads", [True, False], ids=["results-on-the-page", "no-analysis"])
def test_retry_of_a_full_reanalysis_that_failed_before_its_install_asks_first(tmp_path, analysis_loads):
    """ARCHITECTURE (Job lifecycle): "and so does Retry on a Full re-analysis that failed before its new results
    were installed". The server retries such a job as an ANALYZE: the film goes to the GPU again and the install
    clears the track assignments. Retry posted it at once (fails on HEAD). The question is the Full re-analysis
    button's, with "the current results stay" only when the page shows results; declining posts nothing."""
    game_over = {"status": "failed", "has_tracking": True, "has_analysis": analysis_loads, "latest_job_id": "j_1"}
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const GAME = {_js(game_over)};\n"
        + 'const FAILED = { kind: "analyze", stage: "gpu_processing" };\nconst RETRIED_KIND = "analyze";\n'
        + RETRY_JS,
    )
    assert out["offered"] == ["Retry"]
    question, again = out["confirms"]
    assert question == again
    assert _is_full_run_question(question, results_on_the_page=analysis_loads), question
    assert out["declined"] == {"retries": 0, "buttons": ["Retry"]}
    assert (out["retries"], out["posts"]) == (["/api/jobs/j_1/retry"], [])
    assert out["panel"] == "Film analysis in progress"


@pytest.mark.parametrize(
    ("game_over", "failed", "button", "retried_kind"),
    [
        pytest.param(
            {"status": "failed", "has_analysis": False, "has_tracking": True},
            {"kind": "analyze", "stage": "analyzing"},
            "Re-run analysis",
            "reanalyze",
            id="failed-after-its-install",
        ),
        pytest.param(
            {"status": "failed", "has_analysis": False, "has_tracking": False},
            {"kind": "analyze", "stage": "gpu_processing"},
            "Retry",
            "analyze",
            id="first-analysis-failed-on-the-gpu",
        ),
        pytest.param(
            {"status": "failed", "has_analysis": False, "has_tracking": True},
            {"kind": "reanalyze", "stage": "analyzing"},
            "Retry",
            "reanalyze",
            id="re-run-analysis-failed",
        ),
    ],
)
def test_guard_other_retries_post_at_once(tmp_path, game_over, failed, button, retried_kind):
    """Guard: a Retry the server turns into a REANALYZE (an ANALYZE that failed at analyzing or reporting, the
    button reads Re-run analysis), a Retry of a first analysis (no GPU results to lose) and a Retry of a Re-run
    analysis post at once, without a question."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const GAME = {_js({**game_over, 'latest_job_id': 'j_1'})};\nconst FAILED = {_js(failed)};\n"
        + f"const RETRIED_KIND = {_js(retried_kind)};\n"
        + RETRY_JS,
    )
    assert out["offered"] == [button]
    assert out["confirms"] == []
    assert out["declined"]["retries"] == 1  # posted at the first click, with nothing to decline
    assert out["retries"] == ["/api/jobs/j_1/retry"]


@pytest.mark.parametrize("earlier_run", [True, False], ids=["full-reanalysis", "first-analysis"])
def test_retry_after_a_failure_on_the_gpu_with_the_real_server(tmp_path, scout, monkeypatch, earlier_run):  # noqa: F811
    """The seam: an ANALYZE that failed on the GPU (retryable), as the real server leaves it. For a Full
    re-analysis the game keeps its results and track fix, Retry asks the Full re-analysis question first (on HEAD
    it posted at once), and the retry it then sends does what that question says: the film goes to the GPU again
    and the track fix is cleared. A first analysis that failed on the GPU is retried at once (guard)."""
    client = scout.client
    if earlier_run:
        game_id, fix = _analysed_game(scout)
        _gpu_fails_once(monkeypatch, scout)
        failed = _run(scout, client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json())
    else:
        game_id, fix = _new_game(scout), None
        _gpu_fails_once(monkeypatch, scout)
        failed = _run(scout, _upload_film(client, game_id, auto_start=True)["job"])
    assert (failed["kind"], failed["status"], failed["stage"]) == ("analyze", "failed", "gpu_processing")
    assert failed["error"]["retryable"] is True
    bodies = _bodies(scout, game_id, failed["id"])
    assert (bodies["game"]["has_tracking"], bodies["game"]["has_analysis"]) == (earlier_run, earlier_run)
    overrides = client.get(f"/api/games/{game_id}/tracks").json()["overrides"]
    assert [o["track_id"] for o in overrides] == ([fix["track_id"]] if fix else [])  # kept by the failed run

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const phases = {{ during: {_for_page(bodies, game_id)} }};\n"
        + GAME_PAGE_JS
        + """
await import("./js/game.js");
await settle();
const seen = look();
const retry = () => $$("#job-panel button").find((b) => textOf(b) === "Retry");
globalThis.confirmAnswer = false;
retry().click();
await settle();
const declined = retries.length;
globalThis.confirmAnswer = true;
retry()?.click();
await settle();
console.log(JSON.stringify({ seen, confirms, declined, retries, posts }));
""",
    )
    assert out["seen"]["panelButtons"] == ["Retry"]
    assert out["posts"] == []
    if earlier_run:
        question, again = out["confirms"]
        assert question == again and _is_full_run_question(question, results_on_the_page=True), question
        assert (out["declined"], out["retries"]) == (0, [failed["id"]])
    else:  # sent at the first click (answered 503 here, so the panel shows that error and no Retry after it)
        assert (out["confirms"], out["declined"], out["retries"]) == ([], 1, [failed["id"]])

    # What the page sends, as the real server runs it.
    gpu_runs = list(scout.gpu_runs)
    retried = client.post(f"/api/jobs/{failed['id']}/retry")
    assert retried.status_code == 200, retried.text
    assert retried.json()["kind"] == "analyze"
    assert _run(scout, retried.json())["status"] == "succeeded"
    assert scout.gpu_runs == [*gpu_runs, retried.json()["id"]]  # the film went to the GPU again
    overrides = client.get(f"/api/games/{game_id}/tracks").json()["overrides"]
    assert overrides == []  # the track fix went (for a Full re-analysis, as its question said)


# ---------------------------------------------------------------------------
# 4. Start again keeps the job's params
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("cancelled", "game_over"),
    [
        pytest.param(
            {"kind": "reanalyze", "params": {"report": True, "coach_focus": PLAYER_FOCUS}},
            {"status": "uploaded", "has_analysis": False, "has_tracking": True},
            id="reanalyze-with-its-report-and-focus",
        ),
        pytest.param({"kind": "analyze", "params": {}}, {"status": "uploaded", "has_analysis": False}, id="analyze"),
    ],
)
def test_start_again_restarts_the_cancelled_job_with_its_params(tmp_path, cancelled, game_over):
    """ARCHITECTURE (Job lifecycle): "Start again restarts a cancelled job with its kind and params (POST
    /api/jobs/{id}/retry)". It posted {kind} to /api/games/{id}/jobs, which dropped the report and coach focus of
    a REANALYZE retried from a failed ANALYZE (fails on HEAD). A cancelled first analysis restarts at once through
    the same request (it also fails on HEAD, which posted {kind: "analyze"}; the seam tests of
    tests/test_review5_panels.py show that the server's retry of it is an ANALYZE)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const CANCELLED = {_js({'status': 'cancelled', 'stage': 'done', 'message': 'Cancelled', **cancelled})};\n"
        + "const cancelled = job(CANCELLED);\n"
        + f"const GAME = {_js({**game_over, 'latest_job_id': 'j_1'})};\n"
        + """
let restarted = null;
gamePageRoutes(route, json, { gameBody: () => game(restarted ? { status: "queued", latest_job_id: "j_2" } : GAME), analysisBody: analysis() });
route("GET", "/api/games/g_1/jobs", () => json(restarted ? [restarted, cancelled] : [cancelled]));
route("GET", "/api/jobs/j_2", () => json({ ...restarted, status: "running", stage: "analyzing", progress: 20 }));
const retries = [];
route("POST", /^\\/api\\/jobs\\/j_\\d+\\/retry$/, (req) => {
  retries.push(req.path);
  restarted = job({ id: "j_2", kind: cancelled.kind, params: cancelled.params });
  return json(restarted);
});
route("POST", "/api/games/g_1/jobs", (req) => { posts.push(req.body); return json(job({ id: "j_2", kind: req.body.kind }), 201); });
await import("./js/game.js");
await settle();
globalThis.confirmAnswer = false; // a question would stop it
$$("#job-panel button").find((b) => textOf(b) === "Start again").click();
await settle();
console.log(JSON.stringify({ confirms, retries, posts, panel: textOf($("#job-panel h2")) }));
""",
    )
    assert out["confirms"] == []
    assert (out["retries"], out["posts"]) == (["/api/jobs/j_1/retry"], [])
    in_progress = "Re-analysis in progress" if cancelled["kind"] == "reanalyze" else "Film analysis in progress"
    assert out["panel"] == in_progress


def test_start_again_keeps_the_report_and_focus_of_a_cancelled_reanalyze_with_the_real_server(
    tmp_path, scout, monkeypatch  # noqa: F811
):
    """The seam: an ANALYZE with a coach focus fails after the GPU; its Retry is a REANALYZE that writes the report
    with that focus, and the coach cancels it while it waits in the queue. Start again on the game page sends the
    server's retry (on HEAD: a REANALYZE without params, so no report), and the job it starts has the report and
    the focus, and writes the report with the focus."""
    client = scout.client
    focused: list[str | None] = []
    generate = claude_report.generate_report  # the scout fixture's

    def generate_report(analysis, game, rosters, **kwargs):
        focused.append(kwargs.get("coach_focus"))
        return generate(analysis, game, rosters, **kwargs)

    monkeypatch.setattr(claude_report, "generate_report", generate_report)
    game_id = _new_game(scout)
    _upload_film(client, game_id, auto_start=False)
    _failing_once(monkeypatch, ErrorCode.CONFIG_INVALID)
    first = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze", "params": {"coach_focus": PLAYER_FOCUS}})
    assert first.status_code == 201, first.text
    failed = _run(scout, first.json())
    assert (failed["status"], failed["stage"]) == ("failed", "analyzing")
    rerun = client.post(f"/api/jobs/{failed['id']}/retry").json()
    params = {"report": True, "coach_focus": PLAYER_FOCUS}
    assert (rerun["kind"], rerun["params"]) == ("reanalyze", params)
    assert client.post(f"/api/jobs/{rerun['id']}/cancel").json()["status"] == "cancelled"  # at once
    bodies = _bodies(scout, game_id, rerun["id"])

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const phases = {{ during: {_for_page(bodies, game_id)} }};\n"
        + GAME_PAGE_JS
        + """
await import("./js/game.js");
await settle();
const seen = look();
globalThis.confirmAnswer = false; // a question would stop it
$$("#job-panel button").find((b) => textOf(b) === "Start again").click();
await settle();
console.log(JSON.stringify({ seen, confirms, retries, posts }));
""",
    )
    assert (out["seen"]["panel"], out["seen"]["panelButtons"]) == ("Re-analysis was cancelled", ["Start again"])
    assert (out["confirms"], out["retries"], out["posts"]) == ([], [rerun["id"]], [])

    # What the page sends, as the real server runs it: the same job again, report and focus included.
    reports = len(client.get(f"/api/games/{game_id}/reports").json())
    restarted = client.post(f"/api/jobs/{out['retries'][0]}/retry")
    assert restarted.status_code == 200, restarted.text
    assert (restarted.json()["kind"], restarted.json()["params"]) == ("reanalyze", params)
    assert _run(scout, restarted.json())["status"] == "succeeded"
    assert len(client.get(f"/api/games/{game_id}/reports").json()) == reports + 1
    assert focused == [PLAYER_FOCUS]
