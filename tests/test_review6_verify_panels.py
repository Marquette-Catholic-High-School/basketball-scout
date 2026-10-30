"""Sixth review round, verification of the panels area: the game page's job panel, header and report tab, and the
games list, against the real API with an in-process worker in demo mode (``tests/test_review4_integration.py``).

* Every point a cancel can arrive at, for every kind of job: the question the job panel asks, the request the page
  sends, what the pages say after the coach's OK (job panel, header badge, games list, report tab), and what the
  worker then does with that cancel, which must be what the question said (docs/ARCHITECTURE.md, "Job lifecycle").
* The job panel at every kind and stage follows ``scout.schemas.cancel_stops_job``.
"""

from __future__ import annotations

import json
from typing import Any

import pytest

from scout import db
from scout.errors import ErrorCode
from scout.schemas import JobKind, JobStage, cancel_stops_job
from tests.test_review2_frontend import GAME_JS
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
from tests.test_review_frontend import run_page

STOP_QUESTION = "Stop this job? You can start it again later."
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
# The job's message after a cancel request, and the job warnings of a late cancel (docs/ARCHITECTURE.md).
CANCELLING_MESSAGE = "Cancelling..."
TOO_LATE_MESSAGE = "Cancel requested: too late to stop this job, so it will finish."
LATE_WARNINGS = {
    "analyze": (
        "Cancelled after the new GPU results were in place: the analysis was finished.",
        "Cancelled after the new GPU results were in place: the analysis was finished, "
        "the scouting report was skipped.",
    ),
    "reanalyze": (
        "Cancelled after the analysis had started: the analysis was finished.",
        "Cancelled after the analysis had started: the analysis was finished, the scouting report was skipped.",
    ),
}
REPORT_LATE_CANCEL = "Cancelled after Claude had started writing the report: the report was kept."
KIND_LABELS = {"analyze": "Film analysis", "reanalyze": "Re-analysis"}
HEALTH_JS = """
route("GET", "/api/health", json({ status: "ok", version: "1", processor: "mock", queue_backend: "sqlite",
  queue_ok: true, worker_last_seen_s: 5, claude_configured: true, ffmpeg_available: true }));
"""


def _before_stage(monkeypatch, scout, stage: JobStage) -> str:  # noqa: F811
    """``scout.hooks[name]()`` runs just before the worker writes ``stage``: the job is claimed and its stored stage
    is still the one before (the cancel is "asked for before the stage was written", scout/worker.py). Returns the
    hook's name."""
    name = f"before:{stage.value}"
    update = db.update_job

    def update_job(job_id: str, **fields: Any):
        if fields.get("stage") == stage and name in scout.hooks:
            scout.hooks.pop(name)()
        return update(job_id, **fields)

    monkeypatch.setattr(db, "update_job", update_job)
    return name


def _start(scout, monkeypatch, kind: str, report: bool) -> tuple[str, dict]:  # noqa: F811
    """A job of ``kind`` queued as the pages start it, on a game with placeholder rosters. ANALYZE: a Full
    re-analysis of an analysed game (``report``: the server writes the automatic report). REANALYZE: the header's
    Re-run analysis, or (``report``) the retry of an ANALYZE that failed after the GPU, which writes the report.
    REPORT: Generate report."""
    client = scout.client
    if kind == "reanalyze" and report:
        game_id = _new_game(scout)
        _failing_once(monkeypatch, ErrorCode.CONFIG_INVALID)
        failed = _run(scout, _upload_film(client, game_id, auto_start=True)["job"])
        assert (failed["status"], failed["stage"]) == ("failed", "analyzing")
        job = client.post(f"/api/jobs/{failed['id']}/retry").json()
        assert (job["kind"], job["params"]) == ("reanalyze", {"report": True})
        return game_id, job
    game_id, _fix = _analysed_game(scout)
    if kind == "report":
        return game_id, client.post(f"/api/games/{game_id}/reports", json={}).json()
    if kind == "analyze" and not report:  # no Claude key, or SCOUT_AUTO_REPORT=false: no automatic report
        monkeypatch.setattr(scout.worker, "settings", scout.worker.settings.model_copy(update={"auto_report": False}))
    job = client.post(f"/api/games/{game_id}/jobs", json={"kind": kind})
    assert job.status_code == 201, job.text
    return game_id, job.json()


def _cancel_at(scout, monkeypatch, game_id: str, job: dict, where: str) -> dict[str, Any]:  # noqa: F811
    """The coach's cancel at ``where``: "queued" (no worker has the job yet), "before:<stage>" (see _before_stage) or
    a stage hook of the scout fixture. Returns the pages' bodies just before it (``during``), the cancel's answer
    (``cancelled``), the bodies right after it (``after``, the polls while the worker has not noticed it yet or
    carries on) and once the worker is done (``ended``)."""
    client = scout.client
    seen: dict[str, Any] = {}

    def cancel() -> None:
        seen["during"] = _bodies(scout, game_id, job["id"])
        seen["cancelled"] = client.post(f"/api/jobs/{job['id']}/cancel").json()
        seen["after"] = _bodies(scout, game_id, job["id"])

    if where == "queued":
        cancel()
    else:
        before = where.startswith("before:")
        name = _before_stage(monkeypatch, scout, JobStage(where.split(":")[1])) if before else where
        scout.hooks[name] = cancel
    scout.worker.run_once(timeout=0.5)
    assert scout.hooks == {} and "after" in seen, f"the job never got to {where}"
    seen["ended"] = _bodies(scout, game_id, job["id"])
    return seen


# The game page at the moment of the cancel (``phases.during``): the coach clicks Cancel and OK, the polls then
# show ``phases.after`` and, once the worker is done, ``phases.ended``. ``cancels`` has the job ids of the cancels
# the page sent.
CANCEL_PAGE_JS = """
const cancels = [];
route("POST", /^\\/api\\/jobs\\/j_[0-9a-f]+\\/cancel$/, (req) => {
  cancels.push(req.path.split("/")[3]);
  phase = "after";
  return json(cancelled);
});
await import("./js/game.js");
await settle();
const panel = () => ({
  title: textOf($("#job-panel h2")),
  stage: textOf($("#job-panel .job-stage")),
  button: [textOf($("#job-panel .card-head button")), $("#job-panel .card-head button")?.disabled ?? null],
  text: textOf(byId("job-panel")),
  badge: textOf(byId("game-status")),
  pending: byId("analysis-pending").hidden ? null : textOf(byId("analysis-pending")),
});
const before = panel();
$$("#job-panel button").find((b) => textOf(b) === "Cancel").click();
await settle();
const after = panel();
phase = "ended";
await settle();
await settle();
console.log(JSON.stringify({ before, confirms, cancels, after, ended: look() }));
"""

# The games list on bodies polled after the cancel.
GAMES_LIST_JS = """
route("GET", "/api/games", json([listed]));
route("GET", /^\\/api\\/jobs\\/j_[0-9a-f]+$/, json(polled));
await import("./js/index.js");
await settle();
console.log(JSON.stringify({ progress: textOf($("#games-list .progress-text")),
  card: textOf($("#games-list .game-card")) }));
"""

# (kind, report due, where the cancel arrives, the stage line at that moment, the question, what the worker does).
# Outcomes: "cancelled"; "finished" (the analysis runs to the end, no report was due); "skipped" (it runs to the end
# and the report not started yet is skipped); "kept" (it runs to the end and the report Claude is writing is kept).
CANCEL_POINTS = [
    pytest.param("analyze", True, "queued", "Waiting for the background worker", STOP_QUESTION, "cancelled",
                 id="analyze-queued"),
    pytest.param("analyze", True, "before:uploading_to_gpu", "Preparing the film", STOP_QUESTION, "cancelled",
                 id="analyze-preparing"),
    pytest.param("analyze", True, "uploading", "Uploading film to the GPU", STOP_QUESTION, "cancelled",
                 id="analyze-uploading"),
    pytest.param("analyze", True, "gpu_processing", "Analyzing on the GPU (5%)", STOP_QUESTION, "cancelled",
                 id="analyze-on-the-gpu"),
    pytest.param("analyze", True, "downloading", "Downloading results from the GPU", STOP_QUESTION, "cancelled",
                 id="analyze-downloading"),
    pytest.param("analyze", True, "analyzing", "Building box score", ANALYSIS_QUESTION, "skipped",
                 id="analyze-analyzing-report-due"),
    pytest.param("analyze", False, "analyzing", "Building box score", ANALYSIS_QUESTION, "finished",
                 id="analyze-analyzing-no-report-due"),
    pytest.param("analyze", True, "reporting", "Writing scouting report", REPORTING_QUESTION, "kept",
                 id="analyze-reporting"),
    pytest.param("reanalyze", False, "queued", "Waiting for the background worker", STOP_QUESTION, "cancelled",
                 id="reanalyze-queued"),
    pytest.param("reanalyze", True, "before:analyzing", "Waiting for the background worker", STOP_QUESTION,
                 "cancelled", id="reanalyze-claimed"),
    pytest.param("reanalyze", False, "analyzing", "Building box score", RERUN_QUESTION, "finished",
                 id="reanalyze-analyzing"),
    pytest.param("reanalyze", True, "analyzing", "Building box score", RERUN_REPORT_QUESTION, "skipped",
                 id="reanalyze-analyzing-report-due"),
    pytest.param("reanalyze", True, "reporting", "Writing scouting report", REPORTING_QUESTION, "kept",
                 id="reanalyze-reporting"),
]


@pytest.mark.parametrize(("kind", "report", "where", "stage_text", "question", "outcome"), CANCEL_POINTS)
def test_every_cancel_point_with_the_real_server(
    tmp_path, scout, monkeypatch, kind, report, where, stage_text, question, outcome  # noqa: F811
):
    """ARCHITECTURE (Job lifecycle), at every point a cancel of an analysis job can arrive, with the real API and
    worker: the job panel asks the question for the job's kind and stage, sends the cancel for that job, and then
    shows "Cancelling…" for a job the cancel stops, or its stage and "Cancel requested" (no "Cancelling" anywhere
    on the panel, the header badge or the games list) for one it no longer stops. The worker then does what the
    question said: a job the cancel stops ends cancelled with Start again; one it no longer stops ends succeeded,
    skips the report Claude had not started and keeps the one Claude was writing, with the job warning for it."""
    client = scout.client
    game_id, job = _start(scout, monkeypatch, kind, report)
    reports = len(client.get(f"/api/games/{game_id}/reports").json())
    seen = _cancel_at(scout, monkeypatch, game_id, job, where)
    late = question != STOP_QUESTION

    # What the server says after the cancel request (the worker agent's change).
    if where == "queued":
        assert seen["cancelled"]["status"] == "cancelled"  # at once
    else:
        polled = seen["after"]["job"]
        assert (polled["status"], polled["cancel_requested"]) == ("running", True)
        assert polled["message"] == (TOO_LATE_MESSAGE if late else CANCELLING_MESSAGE)

    # What the worker did with it.
    done = seen["ended"]["job"]
    added = len(client.get(f"/api/games/{game_id}/reports").json()) - reports
    if outcome == "cancelled":
        assert (done["status"], done["warnings"], added) == ("cancelled", [], 0)
    else:
        finished, skipped = LATE_WARNINGS[kind]
        warning = skipped if outcome == "skipped" else finished
        assert (done["status"], done["warnings"]) == ("succeeded", [warning])
        assert added == (1 if outcome == "kept" else 0)
    # ... is what the question said.
    said = {
        "cancelled": question == STOP_QUESTION,
        "kept": "the report is kept" in question,
        "skipped": "only skips the automatic scouting report" in question,
        "finished": question.endswith(("There is nothing left to cancel.", "if one was going to be written.")),
    }
    assert said[outcome], question

    out = run_page(
        tmp_path / "game",
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const phases = {_for_page({p: seen[p] for p in ('during', 'after', 'ended')}, game_id)};\n"
        + f"const cancelled = {_for_page(seen['cancelled'], game_id)};\n"
        + GAME_PAGE_JS
        + CANCEL_PAGE_JS,
    )
    before, after = out["before"], out["after"]
    assert before["title"] == f"{KIND_LABELS[kind]} in progress"
    assert before["stage"] == stage_text
    assert before["button"] == ["Cancel", False]
    assert out["confirms"] == [question]
    assert out["cancels"] == [job["id"]]
    if late:
        assert (after["stage"], after["button"]) == (stage_text, ["Cancel requested", True])
        for shown in ("text", "badge", "pending"):
            assert "Cancelling" not in (after[shown] or ""), after
    elif where != "queued":  # a queued job is cancelled at once: the next poll already shows it finished
        assert (after["stage"], after["button"]) == ("Cancelling…", ["Cancelling…", True])
    ended = out["ended"]
    if outcome == "cancelled":
        assert (ended["panel"], ended["panelButtons"]) == (f"{KIND_LABELS[kind]} was cancelled", ["Start again"])
    else:
        assert ended["panel"] == f"{KIND_LABELS[kind]} finished with warnings"
        assert ended["panelText"].endswith(done["warnings"][0])

    # The games list, polled after the cancel while the game is processing (it is ready once the analysis is saved).
    listed = seen["after"]["game"]
    if listed["status"] != "processing":
        assert where in ("queued", "reporting")
        return
    out = run_page(
        tmp_path / "list",
        "index.html",
        "/",
        f"const listed = {_for_page(listed, game_id)};\nconst polled = {_for_page(seen['after']['job'], game_id)};\n"
        + HEALTH_JS
        + GAMES_LIST_JS,
    )
    pct = round(seen["after"]["job"]["progress"])
    if late:
        assert out["progress"] == f"{stage_text} · {pct}% · Cancel requested"
        assert "Cancelling" not in out["card"]
    else:
        assert out["progress"] == f"Cancelling… · {pct}%"


# The report tab while a REPORT job runs: its status line in each phase (the report tab has no Cancel button: the
# cancel comes from elsewhere, here the API), and what it says once the job has ended.
REPORT_TAB_JS = """
await import("./js/game.js");
await settle();
const status = () => textOf(byId("report-status"));
const seen = { during: status() };
phase = "after";
await settle();
seen.after = status();
phase = "ended";
await settle();
await settle();
seen.ended = { status: status(), error: textOf(byId("report-error")), generate: byId("report-generate").disabled,
  panel: textOf(byId("job-panel")), body: textOf(byId("report-body")) };
console.log(JSON.stringify(seen));
"""


@pytest.mark.parametrize(
    ("where", "during", "after", "outcome"),
    [
        pytest.param("queued", "Waiting for the background worker… This usually takes one to three minutes.", None,
                     "cancelled", id="queued"),
        pytest.param("before:reporting", "Waiting for the background worker… This usually takes one to three minutes.",
                     "Cancelling…", "cancelled", id="claimed-before-claude-starts"),
        pytest.param("reporting", "Writing scouting report… This usually takes one to three minutes.",
                     "Writing scouting report… Cancel requested: Claude is already writing it, so it will finish and "
                     "be kept.", "kept", id="claude-writing"),
    ],
)
def test_every_cancel_point_of_a_report_with_the_real_server(
    tmp_path, scout, monkeypatch, where, during, after, outcome  # noqa: F811
):
    """ARCHITECTURE (Job lifecycle): "a REPORT only until Claude starts writing (stage reporting)". The report tab, on
    the real server's bodies: before Claude starts, a cancel stops the report ("Cancelling…", then "Report generation
    was cancelled."); once Claude writes it, the tab says it will finish and be kept, and the worker keeps it with
    the job warning."""
    client = scout.client
    game_id, job = _start(scout, monkeypatch, "report", True)
    reports = len(client.get(f"/api/games/{game_id}/reports").json())
    seen = _cancel_at(scout, monkeypatch, game_id, job, where)
    done = seen["ended"]["job"]
    added = len(client.get(f"/api/games/{game_id}/reports").json()) - reports
    if outcome == "cancelled":
        assert (done["status"], done["warnings"], added) == ("cancelled", [], 0)
    else:
        assert (done["status"], done["warnings"], added) == ("succeeded", [REPORT_LATE_CANCEL], 1)
    if where != "queued":
        polled = seen["after"]["job"]
        assert polled["message"] == (TOO_LATE_MESSAGE if outcome == "kept" else CANCELLING_MESSAGE)
    # A REPORT job is never the job panel's: the panel keeps the game's analysis job.
    phases = {p: seen[p] for p in ("during", "after", "ended")}
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS + f"const phases = {_for_page(phases, game_id)};\n" + GAME_PAGE_JS + REPORT_TAB_JS,
    )
    assert out["during"] == during
    if after is not None:
        assert out["after"] == after
    ended = out["ended"]
    assert (ended["status"], ended["generate"]) == ("", False)
    assert "Cancelling" not in ended["panel"]
    if outcome == "cancelled":
        assert ended["error"] == "Report generation was cancelled."
    else:
        assert ended["error"] in ("", None)
        assert ended["body"].startswith("Scouting report:")


# The job panel on a running job of each kind at each stage (params.report set or not): the coach clicks Cancel and
# OK, and the polls then show the job with its cancel request.
EVERY_STAGE_JS = """
const { JobPanel } = await import("./js/jobpanel.js");
const results = [];
for (const [kind, stage, params] of cases) {
  const running = job({ id: "j_x", kind, status: "running", stage, progress: 50, params, message: "From the server" });
  let requested = false;
  const now = () => (requested ? { ...running, cancel_requested: true, message: "Message after the cancel" } : running);
  route("GET", "/api/jobs/j_x", () => json(now()));
  route("POST", "/api/jobs/j_x/cancel", () => { requested = true; return json(now()); });
  const panel = new JobPanel({ onChange() {} });
  panel.show(running);
  await settle();
  confirms.length = 0;
  $$("#job-panel button").find((b) => textOf(b) === "Cancel").click();
  await settle();
  results.push({ question: confirms[0], stage: textOf($("#job-panel .job-stage")),
    button: [textOf($("#job-panel .card-head button")), $("#job-panel .card-head button").disabled],
    text: textOf(byId("job-panel")) });
  panel.stop();
}
console.log(JSON.stringify({ results }));
"""
STAGE_LABELS = {"analyzing": "Building box score", "reporting": "Writing scouting report"}


def test_the_job_panel_follows_the_servers_rule_at_every_kind_and_stage(tmp_path):
    """ARCHITECTURE (Job lifecycle): the Cancel confirm asks "Stop this job?" exactly where
    scout.schemas.cancel_stops_job says a cancel still stops the job, and after the OK the panel says "Cancelling…"
    exactly there; everywhere else it asks what the cancel still does and then shows the job's stage and "Cancel
    requested", with no "Cancelling" and not the server's message (on HEAD a REANALYZE and a REPORT asked "Stop this
    job?" at every stage)."""
    cases = [
        [kind.value, stage.value, params]
        for kind in JobKind
        for stage in JobStage
        if stage != JobStage.DONE
        for params in ({}, {"report": True})
    ]
    script = GAME_JS + f"const cases = {json.dumps(cases)};\n" + EVERY_STAGE_JS
    out = run_page(tmp_path, "game.html", "/games/g_1", script)
    for (kind, stage, params), seen in zip(cases, out["results"], strict=True):
        case = (kind, stage, params, seen)
        if cancel_stops_job(JobKind(kind), JobStage(stage)):
            assert seen["question"] == STOP_QUESTION, case
            assert (seen["stage"], seen["button"]) == ("Cancelling…", ["Cancelling…", True]), case
        else:
            assert seen["question"] != STOP_QUESTION and "will finish" in seen["question"], case
            assert (seen["stage"], seen["button"]) == (STAGE_LABELS[stage], ["Cancel requested", True]), case
            assert "Cancelling" not in seen["text"] and "Message after the cancel" not in seen["text"], case
