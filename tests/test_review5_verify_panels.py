"""Fifth review round, verification of the game page's calibration and job panels.

The real game page runs in the node fake-DOM harness of ``tests/test_review_frontend.py``; the seam test
feeds it the bodies the real API answers with an in-process worker in demo mode
(``tests/test_review4_integration.py``) and then replays what the page posts on that server.

* The calibration result's button is renamed only when the job it starts changes: the result is a live
  region, and writing the same name again with every refresh could read it out again.
* Removing a calibration on a game that has not been analysed yet no longer says "Re-run the analysis"
  (README, "Court calibration": Analyze film for a game that has not been analysed yet).
* Across the game shapes the real server leaves (failed on the GPU, a Re-run analysis that failed, a
  Full re-analysis or a first analysis cancelled while queued, a new film after a failure past the GPU),
  the calibration's button has the header's name, posts the header's kind and does what its name says,
  and Start again asks the Full re-analysis question exactly for a cancelled Full re-analysis.
"""

from __future__ import annotations

import json

import pytest

from scout.errors import ErrorCode, ScoutError
from scout.processing.base import PollResult
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
from tests.test_review5_panels import CALIBRATE_JS
from tests.test_review_frontend import run_page


def _js(value: object) -> str:
    return json.dumps(value)


# ---------------------------------------------------------------------------
# The calibration result's button keeps its name until the job it starts changes
# ---------------------------------------------------------------------------


def test_a_refresh_leaves_the_calibration_buttons_name_alone_until_it_changes(tmp_path):
    """The calibration result (#cal-result) is a polite live region. setup() wrote the button's name again
    with every refresh of the page, a new text node each time, so a screen reader could read "Analyze film"
    out again when the analysis it had just started was shown (fails on the fix agent's version). The name
    is now written only when it changes: once the first analysis has finished, it reads Re-run analysis."""
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
route("POST", "/api/games/g_1/jobs", (req) => { posts.push(req.body); phase = "running"; return json(job({ id: "j_2" }), 201); });
"""
        + CALIBRATE_JS
        + """
await import("./js/game.js");
await settle();
await saveCalibration();
const button = () => $$("#cal-result button")[0];
const name = button().firstChild;
button().click();
await settle();
const started = { label: textOf(button()), rewritten: button().firstChild !== name, panel: textOf($("#job-panel h2")) };
phase = "ready";
await settle();
await settle();
console.log(JSON.stringify({ started, finished: textOf(button()), posts }));
""",
    )
    assert out["started"] == {"label": "Analyze film", "rewritten": False, "panel": "Film analysis in progress"}
    assert out["finished"] == "Re-run analysis"
    assert out["posts"] == [{"kind": "analyze"}]


# ---------------------------------------------------------------------------
# Removing the calibration says what the next analysis does
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("game_over", "button", "message"),
    [
        pytest.param(
            {"status": "uploaded", "has_analysis": False},
            "Analyze film",
            "Calibration removed. The analysis will use automatic court detection.",
            id="never-analysed",
        ),
        pytest.param(
            {"has_tracking": True},
            "Re-run analysis",
            "Calibration removed. Re-run the analysis to go back to automatic court detection.",
            id="analysed",
        ),
    ],
)
def test_removing_the_calibration_says_what_the_next_analysis_does(tmp_path, game_over, button, message):
    """README (Court calibration): Re-run analysis, or Analyze film for a game that has not been analysed
    yet. After Remove saved calibration the panel said "Re-run the analysis to go back to automatic court
    detection" also on a game with nothing to re-run, whose page offers only Analyze film (the never-analysed
    case fails on HEAD and on the fix agent's version). An analysed game keeps that hint (guard)."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + f"""
gamePageRoutes(route, json, {{ gameBody: game({{ ...{_js(game_over)}, calibration }}), analysisBody: analysis() }});
route("GET", "/api/court/landmarks", json({{ court: {{}}, landmarks }}));
const deletes = [];
route("DELETE", "/api/games/g_1/calibration", (req) => {{ deletes.push(req.path); return {{ status: 204 }}; }});
"""
        + """
await import("./js/game.js");
await settle();
await openCalibration();
const shown = { buttons: $$("#cal-result button").map(textOf), header: textOf(byId("reanalyze-btn")) };
byId("cal-delete").click();
await settle();
console.log(JSON.stringify({ shown, removed: textOf($("#cal-result .notice")), deletes, confirms }))
""",
    )
    assert out["shown"] == {"buttons": [button], "header": button}
    assert out["confirms"] == ["Remove the saved court calibration for this game?"]
    assert out["deletes"] == ["/api/games/g_1/calibration"]
    assert out["removed"] == message


# ---------------------------------------------------------------------------
# The seam: every game shape names and starts the same job in the header and the calibration
# ---------------------------------------------------------------------------


def _gpu_fails_once(monkeypatch, scout) -> None:  # noqa: F811
    """The next GPU run fails on the GPU (PIPELINE_FAILED: retryable)."""
    gpu = scout.worker.processor
    poll = gpu.poll
    left = {"n": 1}

    def polled(handle: str) -> PollResult:
        if left["n"]:
            left["n"] -= 1
            return PollResult(state="failed", error=ScoutError(ErrorCode.PIPELINE_FAILED))
        return poll(handle)

    monkeypatch.setattr(gpu, "poll", polled)


def _make_shape(scout, monkeypatch, shape: str) -> str:  # noqa: F811
    """A game left in ``shape`` by the real API and worker; returns its id."""
    client = scout.client
    if shape == "first-run-failed-on-the-gpu":
        game_id = _new_game(scout)
        _gpu_fails_once(monkeypatch, scout)
        assert _run(scout, _upload_film(client, game_id, auto_start=True)["job"])["stage"] == "gpu_processing"
    elif shape == "re-run-failed":
        game_id, _fix = _analysed_game(scout)
        _failing_once(monkeypatch, ErrorCode.ANALYSIS_FAILED)
        assert _run(scout, client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json())["status"] == "failed"
    elif shape in ("full-reanalysis-cancelled-while-queued", "first-analysis-cancelled-while-queued"):
        if shape.startswith("full"):
            game_id, _fix = _analysed_game(scout)
            queued = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
        else:
            game_id = _new_game(scout)
            queued = _upload_film(client, game_id, auto_start=True)["job"]
        assert client.post(f"/api/jobs/{queued['id']}/cancel").json()["status"] == "cancelled"  # at once
    else:  # a new film after a first analysis that failed past the GPU (its tracking is deleted)
        game_id = _new_game(scout)
        _failing_once(monkeypatch, ErrorCode.CONFIG_INVALID)
        assert _run(scout, _upload_film(client, game_id, auto_start=True)["job"])["stage"] == "analyzing"
        _upload_film(client, game_id, auto_start=False)
    return game_id


SHAPE_PAGE_JS = """
await import("./js/game.js");
await settle();
const seen = look();
await saveCalibration();
seen.calibration = resultButtons();
$$("#cal-result button")[0].click();
await settle();
seen.calibrationPosts = posts.splice(0);
globalThis.confirmAnswer = false; // every question is declined
if (!byId("full-analysis-btn").hidden) byId("full-analysis-btn").click(); // its question, for comparison
await settle();
seen.fullQuestion = confirms.splice(0)[0] || null;
const startAgain = $$("#job-panel button").find((b) => textOf(b) === "Start again");
if (startAgain) startAgain.click();
await settle();
seen.startAgain = { offered: Boolean(startAgain), confirms: confirms.splice(0), posts: posts.splice(0), retries: retries.splice(0) };
console.log(JSON.stringify(seen));
"""


@pytest.mark.parametrize(
    ("shape", "label"),
    [
        ("first-run-failed-on-the-gpu", "Analyze film"),
        ("re-run-failed", "Re-run analysis"),
        ("full-reanalysis-cancelled-while-queued", "Re-run analysis"),
        ("first-analysis-cancelled-while-queued", "Analyze film"),
        ("new-film-after-a-failure-past-the-gpu", "Analyze film"),
    ],
)
def test_every_game_shape_names_and_starts_the_same_job_in_the_header_and_the_calibration(
    tmp_path, scout, monkeypatch, shape, label  # noqa: F811
):
    """The seam, for the shapes the panels' own tests do not build with the real server. The calibration's
    button has the header's name and posts the header's kind (Analyze film was "Re-run analysis" on HEAD),
    and what it posts does on the real server what its name says: Analyze film sends the film to the GPU,
    Re-run analysis only redoes the stats here. Start again asks the Full re-analysis button's question for
    a cancelled Full re-analysis (declined: nothing is posted) and starts a cancelled first analysis at once."""
    client = scout.client
    game_id = _make_shape(scout, monkeypatch, shape)
    game = client.get(f"/api/games/{game_id}").json()
    bodies = _bodies(scout, game_id, game["latest_job_id"])

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + f"const phases = {{ during: {_for_page(bodies, game_id)} }};\n"
        + GAME_PAGE_JS
        + CALIBRATE_JS
        + SHAPE_PAGE_JS,
    )
    kind = "analyze" if label == "Analyze film" else "reanalyze"
    assert out["header"][0] == label
    assert out["calibration"] == [label]
    assert out["calibrationPosts"] == [{"kind": kind}]
    start_again = out["startAgain"]
    assert start_again["offered"] is shape.endswith("cancelled-while-queued")
    if shape == "full-reanalysis-cancelled-while-queued":
        assert out["fullQuestion"] and "GPU again" in out["fullQuestion"]
        assert start_again["confirms"] == [out["fullQuestion"]]  # the Full re-analysis button's question
        assert (start_again["posts"], start_again["retries"]) == ([], [])
    elif shape == "first-analysis-cancelled-while-queued":
        assert (out["fullQuestion"], start_again["confirms"]) == (None, [])
        # Round 6: Start again sends the server's retry of the cancelled job (its kind and params).
        assert (start_again["posts"], start_again["retries"]) == ([], [game["latest_job_id"]])

    # What the calibration's button posts, as the real server runs it.
    gpu_runs = list(scout.gpu_runs)
    started = client.post(f"/api/games/{game_id}/jobs", json=out["calibrationPosts"][0])
    assert started.status_code == 201, started.text
    assert _run(scout, started.json())["status"] == "succeeded"
    sent_to_the_gpu = scout.gpu_runs != gpu_runs
    assert sent_to_the_gpu is (label == "Analyze film")
    assert client.get(f"/api/games/{game_id}").json()["has_analysis"] is True
