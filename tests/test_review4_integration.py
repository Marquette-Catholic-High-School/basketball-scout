"""Fourth review round, integration: the seams between the areas.

Everything here goes through the real API with an in-process worker in demo mode (the mock processor,
the real analysis, Claude faked), and the game and Roster pages get the server's own bodies.

* A Full re-analysis cancelled at each stage: before its new results are installed the game keeps its
  earlier run; after that the analysis is finished and a job warning says so (docs/ARCHITECTURE.md,
  "Job lifecycle"). The game page's job panel, header and player follow.
* A Full re-analysis whose analysis fails leaves no earlier analysis for any reader, and its Re-run
  analysis rebuilds it from the installed tracking without a GPU call.
* The game page's header (and the calibration's Re-run analysis) sent the film to the GPU again, with
  no Full re-analysis warning, once such a failure had left the game without an analysis.
* The Roster page's Save & re-run during an ANALYZE: the rosters are saved, the track change is refused
  (409) and waits, and the new run's table comes when the analysis has finished.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from types import SimpleNamespace
from typing import Any

import pytest
from fastapi.testclient import TestClient

from scout import config, db, storage
from scout.analysis import pipeline
from scout.errors import ErrorCode, ScoutError
from scout.main import create_app
from scout.processing.base import PollResult, ProcessorOutput
from scout.processing import mock
from scout.processing.mock import seed_for_job
from scout.reporting import claude_report
from scout.worker import Worker
from tests.test_review2_frontend import CALIBRATION_JS, GAME_JS
from tests.test_review3_integration import _upload_film
from tests.test_review_frontend import run_page
from tests.test_worker import make_report

# docs/ARCHITECTURE.md ("Job lifecycle"): the job warnings for a cancel after the install.
LATE_CANCEL = "Cancelled after the new GPU results were in place: the analysis was finished."
LATE_CANCEL_REPORT_SKIPPED = (
    "Cancelled after the new GPU results were in place: the analysis was finished, the scouting report was skipped."
)
FIRST_OVERLAY = b"the first run's overlay"
NEW_OVERLAY = b"the new run's overlay"
ANNOTATED = "/api/games/g_1/video?variant=annotated"
STAGES = ["queued", "uploading", "gpu_processing", "downloading", "analyzing", "reporting"]
BEFORE_THE_INSTALL = {"queued", "uploading", "gpu_processing", "downloading"}


@pytest.fixture
def scout(monkeypatch, auth_headers):
    """The app and a worker; ``hooks[stage]()`` runs once when the job gets to that stage (the coach's click)."""
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    monkeypatch.setattr(mock, "DEFAULT_DURATION_S", 240.0)  # a shorter demo game: the same flow, a quicker analysis
    monkeypatch.setenv("SCOUT_AUTO_REPORT", "true")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key-not-real")
    config.reset_settings()
    hooks: dict[str, Callable[[], None]] = {}
    gpu_runs: list[str] = []  # job ids sent to the GPU

    def at(stage: str) -> None:
        if stage in hooks:
            hooks.pop(stage)()

    def generate_report(analysis, game, rosters, **_kwargs):
        at("reporting")
        return make_report(game.id)

    monkeypatch.setattr(claude_report, "generate_report", generate_report)
    analyze = pipeline.analyze_game

    def analyze_game(*args: Any, **kwargs: Any):
        at("analyzing")
        return analyze(*args, **kwargs)

    monkeypatch.setattr(pipeline, "analyze_game", analyze_game)
    worker = Worker(worker_id="w-integration")
    gpu = worker.processor
    submit, poll, fetch = gpu.submit, gpu.poll, gpu.fetch

    def submitted(**kwargs: Any) -> str:
        gpu_runs.append(kwargs["job_id"])
        at("uploading")
        return submit(**kwargs)

    def polled(handle: str) -> PollResult:
        if "gpu_processing" in hooks:
            at("gpu_processing")
            return PollResult(state="running", progress=10.0, message="On the GPU")
        return poll(handle)

    def fetched(handle: str, result: dict[str, Any], dest_dir) -> ProcessorOutput:
        output = fetch(handle, result, dest_dir)
        overlay = dest_dir / "annotated.mp4"  # the demo makes none; a real run does
        overlay.write_bytes(FIRST_OVERLAY if len(gpu_runs) == 1 else NEW_OVERLAY)
        at("downloading")
        return ProcessorOutput(tracking_path=output.tracking_path, annotated_video_path=overlay)

    monkeypatch.setattr(gpu, "submit", submitted)
    monkeypatch.setattr(gpu, "poll", polled)
    monkeypatch.setattr(gpu, "fetch", fetched)
    with TestClient(create_app()) as client:
        client.headers.update(auth_headers)
        yield SimpleNamespace(client=client, worker=worker, hooks=hooks, gpu_runs=gpu_runs)


def _run(scout, job: dict) -> dict:
    assert scout.worker.run_once(timeout=2)
    return scout.client.get(f"/api/jobs/{job['id']}").json()


def _new_game(scout) -> str:
    """A game with placeholder rosters (no demo names) and no film yet."""
    client = scout.client
    game_id = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North"}).json()["id"]
    players = [{"jersey": str(n), "first_name": "Test", "last_name": f"Player {n}"} for n in (3, 10, 23)]
    for side in ("scouted", "other"):
        assert client.put(f"/api/games/{game_id}/rosters/{side}", json={"players": players}).status_code == 200
    return game_id


def _analysed_game(scout) -> tuple[str, dict]:
    """A game analysed once (with its automatic report) and one track fix: "Not a player"."""
    client = scout.client
    game_id = _new_game(scout)
    assert _run(scout, _upload_film(client, game_id, auto_start=True)["job"])["status"] == "succeeded"
    tracks = client.get(f"/api/games/{game_id}/tracks").json()["assignments"]
    track = next(a for a in tracks if a["role"] == "player" and a["side"])
    fix = {"track_id": track["track_id"], "player_id": None, "side": track["side"], "ignore": True}
    assert client.put(f"/api/games/{game_id}/tracks/{track['track_id']}", json=fix).status_code == 200
    return game_id, fix


def _state(scout, game_id: str) -> dict[str, Any]:
    """What the pages are built from: whose tracking, analysis and overlay are in place, and the rest."""
    tracking, analysis = storage.tracking_path(game_id), storage.analysis_path(game_id)
    overlay = storage.annotated_video_path(game_id)
    game = scout.client.get(f"/api/games/{game_id}").json()
    return {
        "tracking_of": storage.read_json(tracking)["job_id"] if tracking.exists() else None,
        "analysis_seed": pipeline.load_analysis(analysis).pipeline.options.get("seed") if analysis.exists() else None,
        "overlay": overlay.read_bytes() if overlay.exists() else None,
        "download_folder": storage.incoming_dir(game_id).exists(),
        "overrides": scout.client.get(f"/api/games/{game_id}/tracks").json()["overrides"],
        "game": (game["status"], game["has_analysis"], game["has_annotated_video"], game["error"]),
        "reports": len(scout.client.get(f"/api/games/{game_id}/reports").json()),
    }


def _bodies(scout, game_id: str, job_id: str) -> dict[str, Any]:
    """The game page's requests, as the real server answers them now."""
    client = scout.client
    analysis = client.get(f"/api/games/{game_id}/analysis")
    return {
        "game": client.get(f"/api/games/{game_id}").json(),
        "jobs": client.get(f"/api/games/{game_id}/jobs").json(),
        "job": client.get(f"/api/jobs/{job_id}").json(),
        "analysis": analysis.json() if analysis.status_code == 200 else None,
        "reports": client.get(f"/api/games/{game_id}/reports").json(),
    }


def _for_page(body: object, game_id: str) -> str:
    """A real API body as JS, with the game's id as the pages' fixtures name it (g_1)."""
    return json.dumps(body).replace(game_id, "g_1")


GAME_PAGE_JS = """
let phase = "during";
const now = () => phases[phase];
gamePageRoutes(route, json, { gameBody: () => now().game });
route("GET", "/api/games/g_1/jobs", () => json(now().jobs));
route("GET", /^\\/api\\/jobs\\/j_[0-9a-f]+$/, () => json(now().job));
route("GET", "/api/games/g_1/analysis", () => (now().analysis
  ? json(now().analysis) : fail(409, "ANALYSIS_NOT_READY", "No analysis yet")));
route("GET", "/api/games/g_1/reports", () => json(now().reports));
route("POST", "/api/games/g_1/jobs", (req) => { posts.push(req.body); return fail(503, "QUEUE_UNAVAILABLE", "Not here"); });
const look = () => ({
  panel: textOf($("#job-panel .notice-title")) || textOf($("#job-panel h2")),
  panelText: textOf(byId("job-panel")),
  panelButtons: $$("#job-panel button").map(textOf),
  header: [textOf(byId("reanalyze-btn")), byId("reanalyze-btn").disabled, !byId("full-analysis-btn").hidden],
  results: !byId("analysis-tabs-wrap").hidden,
  srcs: [...srcs],
});
"""


# --- a Full re-analysis cancelled at each stage -------------------------------------------------


@pytest.mark.parametrize("stage", STAGES)
def test_a_full_reanalysis_cancelled_at_each_stage(tmp_path, scout, stage):
    """ARCHITECTURE (Job lifecycle): a cancel stops an ANALYZE only until its new results are installed,
    and then only skips the automatic report. The coach clicks Cancel on the game page at ``stage``.
    Before the install the game keeps its earlier tracking, overlay, analysis, track fixes and flags,
    and the panel offers Start again; after it the job succeeds with the new run in place and the
    warning, and the player loads the new overlay. (The downloading, analyzing and reporting cases
    failed on HEAD: the new run installed with the job cancelled, cancelled after its analysis, or
    succeeded without a warning.)"""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    earlier = _state(scout, game_id)
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    seen: dict[str, Any] = {}

    def cancel() -> None:
        seen["during"] = _bodies(scout, game_id, full["id"])  # the page the coach clicks Cancel on
        assert client.post(f"/api/jobs/{full['id']}/cancel").status_code == 200

    if stage == "queued":
        cancel()
    else:
        scout.hooks[stage] = cancel
    scout.worker.run_once(timeout=0.5)
    assert scout.hooks == {} and "during" in seen  # the job got to that stage

    done = client.get(f"/api/jobs/{full['id']}").json()
    after = _state(scout, game_id)
    if stage in BEFORE_THE_INSTALL:
        assert (done["status"], done["stage"], done["warnings"], done["error"]) == ("cancelled", "done", [], None)
        assert after == earlier
        assert after["download_folder"] is False
    else:
        assert (done["status"], done["stage"], done["error"]) == ("succeeded", "done", None)
        assert done["warnings"] == [LATE_CANCEL_REPORT_SKIPPED if stage == "analyzing" else LATE_CANCEL]
        assert after == {
            "tracking_of": full["id"],
            "analysis_seed": seed_for_job(full["id"]),
            "overlay": NEW_OVERLAY,
            "download_folder": False,
            "overrides": [],  # the new run numbered its tracks anew
            "game": ("ready", True, True, None),
            "reports": earlier["reports"] + (1 if stage == "reporting" else 0),  # kept once Claude was writing it
        }

    phases = {"during": seen["during"], "after": _bodies(scout, game_id, full["id"])}
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"const phases = {_for_page(phases, game_id)};\n"
        + GAME_PAGE_JS
        + """
await import("./js/game.js");
await settle();
const during = look();
phase = "after";
await settle();
await settle();
console.log(JSON.stringify({ during, after: look() }));
""",
    )
    assert out["during"]["panelButtons"] == ["Cancel"]
    seen_after = out["after"]
    assert seen_after["header"] == ["Re-run analysis", False, True]  # the game has an analysis either way
    assert seen_after["results"] is True
    if stage in BEFORE_THE_INSTALL:
        assert (seen_after["panel"], seen_after["panelButtons"]) == ("Film analysis was cancelled", ["Start again"])
        assert seen_after["srcs"] == [ANNOTATED]  # the earlier overlay: nothing to load again
    else:
        assert (seen_after["panel"], seen_after["panelButtons"]) == ("Film analysis finished with warnings", [])
        assert seen_after["panelText"].endswith(done["warnings"][0])
        assert seen_after["srcs"] == [ANNOTATED, ANNOTATED]  # the new overlay, same URL


# --- a Full re-analysis whose analysis fails ----------------------------------------------------


def _failing_once(monkeypatch, code: ErrorCode, times: int = 1) -> None:
    """The next ``times`` analyses fail with ``code`` (CONFIG_INVALID: not retryable)."""
    analyze = pipeline.analyze_game  # the scout fixture's wrapper
    left = {"n": times}

    def analyze_game(*args: Any, **kwargs: Any):
        if left["n"]:
            left["n"] -= 1
            raise ScoutError(code, detail="config/play_rules.yaml: pick_and_roll.max_screen_ft: not a number")
        return analyze(*args, **kwargs)

    monkeypatch.setattr(pipeline, "analyze_game", analyze_game)


READERS = [
    "/analysis",
    "/export/fastscout.txt",
    "/export/fastscout-notes",
    "/export/fastscout.csv",
    "/export/timeline.csv",
    "/export/analysis.json",
]


def test_a_failed_full_reanalysis_leaves_no_earlier_analysis_and_reruns_without_the_gpu(scout, monkeypatch):
    """ARCHITECTURE (Full re-analysis): installing the new tracking deletes the earlier analysis.json, "so no
    page shows the earlier run's track ids over the new tracking, also when that analysis fails". Every
    reader of it answers ANALYSIS_NOT_READY, the Roster page gets no tracks, and the job panel's Re-run
    analysis (offered for CONFIG_INVALID, which is not retryable) rebuilds the analysis from the new
    run's tracking on this server. (On HEAD the earlier analysis stayed, over the new tracking.)"""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    _failing_once(monkeypatch, ErrorCode.CONFIG_INVALID)
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    failed = _run(scout, full)
    assert (failed["status"], failed["stage"], failed["error"]["code"]) == ("failed", "analyzing", "CONFIG_INVALID")
    assert failed["error"]["retryable"] is False
    state = _state(scout, game_id)
    assert (state["tracking_of"], state["analysis_seed"], state["overlay"]) == (full["id"], None, NEW_OVERLAY)
    assert state["overrides"] == []
    assert state["game"][:3] == ("failed", False, True)

    for path in READERS:
        r = client.get(f"/api/games/{game_id}{path}")
        assert (r.status_code, r.json()["error"]["code"]) == (409, "ANALYSIS_NOT_READY"), path
    assert client.get(f"/api/games/{game_id}/tracks").json() == {"assignments": [], "overrides": []}
    r = client.post(f"/api/games/{game_id}/reports", json={})
    assert (r.status_code, r.json()["error"]["code"]) == (409, "ANALYSIS_NOT_READY")

    retried = client.post(f"/api/jobs/{full['id']}/retry").json()  # the job panel's Re-run analysis
    assert retried["kind"] == "reanalyze"
    assert _run(scout, retried)["status"] == "succeeded"
    assert scout.gpu_runs == [scout.gpu_runs[0], full["id"]]  # nothing more went to the GPU
    state = _state(scout, game_id)
    assert (state["tracking_of"], state["analysis_seed"]) == (full["id"], seed_for_job(full["id"]))
    assert state["game"][:3] == ("ready", True, True)
    assert client.get(f"/api/games/{game_id}/export/fastscout.txt").status_code == 200
    assert state["reports"] == 2  # the re-run wrote the automatic report the failed run could not


@pytest.mark.parametrize(
    ("earlier_run", "failures"),
    [
        pytest.param(True, 1, id="full-reanalysis-failed-after-the-gpu"),
        pytest.param(True, 2, id="and-its-re-run-failed-too"),
        pytest.param(False, 1, id="first-analysis-failed-after-the-gpu"),
    ],
)
def test_the_game_page_reruns_a_failed_analysis_on_the_server_once_the_gpu_results_are_saved(
    tmp_path, scout, monkeypatch, earlier_run, failures
):
    """README (Court calibration): "Re-run analysis ... only redoes the stats on this server", and a Full
    re-analysis warns first that it costs another GPU run. Since installing a Full re-analysis deletes the
    earlier analysis, one that failed after the GPU left the game without an analysis, and the page's
    header (keyed on has_analysis) offered "Analyze film": a new 30-60 minute GPU run with no warning. The
    calibration's "Re-run analysis" button sent the film to the GPU too. After a second failure (the Re-run
    analysis itself, CONFIG_INVALID: no Retry in the panel) that was the only way out on the page. (A first
    analysis that failed after the GPU did the same already on HEAD.)"""
    client = scout.client
    game_id = _analysed_game(scout)[0] if earlier_run else _new_game(scout)
    _failing_once(monkeypatch, ErrorCode.CONFIG_INVALID, times=failures)
    if earlier_run:
        full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    else:
        full = _upload_film(client, game_id, auto_start=True)["job"]
    latest = _run(scout, full)
    if failures == 2:
        latest = _run(scout, client.post(f"/api/jobs/{full['id']}/retry").json())
        assert (latest["kind"], latest["status"], latest["error"]["retryable"]) == ("reanalyze", "failed", False)
    bodies = _bodies(scout, game_id, latest["id"])
    assert (bodies["game"]["status"], bodies["game"]["has_analysis"]) == ("failed", False)
    gpu_runs = list(scout.gpu_runs)

    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + CALIBRATION_JS
        + f"const phases = {{ during: {_for_page(bodies, game_id)} }};\n"
        + GAME_PAGE_JS
        + """
route("GET", "/api/court/landmarks", json({ court: {}, landmarks }));
route("PUT", "/api/games/g_1/calibration", (req) => json({ ...calibration, points: req.body.points }));
await import("./js/game.js");
await settle();
const seen = { ...look(), title: byId("reanalyze-btn").title };
byId("reanalyze-btn").click();
await settle();
await openCalibration();
for (const [x, y] of [[20, 300], [600, 300], [60, 40], [560, 40]]) clickFrame(x, y);
byId("cal-save").click();
await settle();
seen.calibrationButtons = $$("#cal-result button").map(textOf);
$$("#cal-result button").find((b) => textOf(b) === "Re-run analysis").click();
await settle();
globalThis.confirmAnswer = false; // Full re-analysis: the coach reads the warning and says no
byId("full-analysis-btn").click();
await settle();
console.log(JSON.stringify({ seen, posts, confirms }));
""",
    )
    seen = out["seen"]
    assert seen["header"] == ["Re-run analysis", False, True]
    assert seen["title"] == "Redo the stats on this server (about a minute, no GPU)"
    assert seen["panelButtons"] == (["Re-run analysis"] if failures == 1 else [])
    assert seen["calibrationButtons"] == ["Re-run analysis"]
    assert out["posts"] == [{"kind": "reanalyze"}, {"kind": "reanalyze"}]  # the header's, the calibration's
    [warning] = out["confirms"]
    assert "another GPU run" in warning and "current results stay" not in warning  # there are none on the page

    # What the page posts, as the real server runs it: the stats again, from the installed tracking.
    rerun = client.post(f"/api/games/{game_id}/jobs", json=out["posts"][0])
    assert rerun.status_code == 201, rerun.text
    assert _run(scout, rerun.json())["status"] == "succeeded"
    assert scout.gpu_runs == gpu_runs  # nothing more went to the GPU
    state = _state(scout, game_id)
    assert (state["analysis_seed"], state["game"][:2]) == (seed_for_job(full["id"]), ("ready", True))


@pytest.mark.parametrize(
    ("game_over", "job_over", "header"),
    [
        pytest.param(
            {"status": "uploaded", "has_analysis": False}, None, ["Analyze film", False, False], id="never-analysed"
        ),
        pytest.param(
            {"status": "failed", "has_analysis": False},
            {"kind": "analyze", "status": "failed", "stage": "gpu_processing"},
            ["Analyze film", False, False],
            id="first-run-failed-on-the-gpu",
        ),
        pytest.param(
            {"status": "uploaded", "has_analysis": False},
            {"kind": "reanalyze", "status": "failed", "stage": "analyzing"},
            ["Analyze film", False, False],
            id="new-film-since-a-failed-re-run",
        ),
        pytest.param(
            {"status": "failed", "has_analysis": True},
            {"kind": "analyze", "status": "failed", "stage": "gpu_processing"},
            ["Re-run analysis", False, True],
            id="full-reanalysis-failed-on-the-gpu",
        ),
    ],
)
def test_guard_the_header_sends_the_film_to_the_gpu_only_without_tracking(tmp_path, game_over, job_over, header):
    """Guard: without saved GPU results (never analysed, a first run that failed on the GPU, a new film since
    the failure) the header still offers Analyze film; with an analysis it offers Re-run analysis and Full
    re-analysis, as before."""
    jobs = f"[job({json.dumps(job_over)})]" if job_over else "[]"
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        GAME_JS
        + f"""
gamePageRoutes(route, json, {{ gameBody: game({json.dumps(game_over)}), jobs: {jobs}, analysisBody: analysis() }});
route("GET", /^\\/api\\/jobs\\/j_[0-9a-f]+$/, json({jobs}[0] || null));
route("POST", "/api/games/g_1/jobs", (req) => {{ posts.push(req.body); return fail(503, "QUEUE_UNAVAILABLE", "Not here"); }});
await import("./js/game.js");
await settle();
const header = [textOf(byId("reanalyze-btn")), byId("reanalyze-btn").disabled, !byId("full-analysis-btn").hidden];
byId("reanalyze-btn").click();
await settle();
console.log(JSON.stringify({{ header, posts }}));
""",
    )
    assert out["header"] == header
    assert out["posts"] == [{"kind": "analyze" if header[0] == "Analyze film" else "reanalyze"}]


# --- the Roster page's Save & re-run while an ANALYZE runs --------------------------------------


def test_save_and_rerun_during_a_full_analysis_saves_the_roster_and_waits_with_the_track_change(tmp_path, scout):
    """README (Court calibration): "the Roster page takes new ones once it has finished"; ARCHITECTURE:
    PUT /tracks answers 409 while an ANALYZE is queued or running. The coach edited a roster and picked
    a track choice on a page opened before a Full re-analysis was started in another tab, then clicked
    Save & re-run: the roster save goes first and the real server takes it, the track change is refused
    and the page waits, and the new run's table (with nothing pending) comes once the analysis is done."""
    client = scout.client
    game_id, _fix = _analysed_game(scout)
    before = {
        "game": client.get(f"/api/games/{game_id}").json(),
        "rosters": client.get(f"/api/games/{game_id}/rosters").json(),
        "tracks": client.get(f"/api/games/{game_id}/tracks").json(),
        "job": client.get(f"/api/jobs/{client.get(f'/api/games/{game_id}').json()['latest_job_id']}").json(),
    }
    track = next(a for a in before["tracks"]["assignments"] if a["role"] == "player" and a["side"] == "scouted")
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()  # another tab
    # The requests Save & re-run sends, as the real server answers them while the ANALYZE is queued.
    scouted = before["rosters"]["scouted"]
    renamed = [{**p, "first_name": "Renamed"} if i == 0 else p for i, p in enumerate(scouted["players"])]
    fields = ("id", "jersey", "first_name", "last_name", "fastscout_name", "position", "grade", "height", "notes")
    roster_body = {"team_name": scouted["team_name"], "players": [{k: p.get(k) for k in fields} for p in renamed]}
    roster_saved = client.put(f"/api/games/{game_id}/rosters/scouted", json=roster_body)
    assert roster_saved.status_code == 200, roster_saved.text
    track_body = {"track_id": track["track_id"], "player_id": None, "side": "other", "ignore": False}
    refused = client.put(f"/api/games/{game_id}/tracks/{track['track_id']}", json=track_body)
    assert refused.status_code == 409, refused.text
    during = {"game": client.get(f"/api/games/{game_id}").json(), "job": client.get(f"/api/jobs/{full['id']}").json()}
    assert _run(scout, full)["status"] == "succeeded"
    after = {
        "game": client.get(f"/api/games/{game_id}").json(),
        "job": client.get(f"/api/jobs/{full['id']}").json(),
        "tracks": client.get(f"/api/games/{game_id}/tracks").json(),
        "rosters": client.get(f"/api/games/{game_id}/rosters").json(),
    }
    assert db.list_track_overrides(game_id) == []  # the refused change was not saved, and the fix went

    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        f"""
const before = {_for_page(before, game_id)};
const during = {_for_page(during, game_id)};
const after = {_for_page(after, game_id)};
const rosterSaved = {_for_page(roster_saved.json(), game_id)};
const refused = {_for_page(refused.json(), game_id)};
let phase = "before";
const sent = [];
route("GET", "/api/games/g_1", () => json(({{ before, during, after }})[phase].game));
route("GET", "/api/games/g_1/rosters", () => json(phase === "after" ? after.rosters : before.rosters));
route("GET", "/api/games/g_1/tracks", () => json(phase === "after" ? after.tracks : before.tracks));
route("GET", "/api/jobs/" + before.job.id, json(before.job));
route("GET", "/api/jobs/" + during.job.id, () => json(phase === "after" ? after.job : during.job));
route("PUT", "/api/games/g_1/rosters/scouted", (req) => {{ sent.push(["roster", req.body]); return json(rosterSaved); }});
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {{ sent.push(["track", req.body]); return json(refused, 409); }});
route("POST", "/api/games/g_1/jobs", (req) => {{ sent.push(["job", req.body]); return json({{}}, 201); }});
await import("./js/roster.js");
await settle();
const first = $("#roster-columns section input[data-key='first_name']");
first.value = "Renamed";
fire(first, "input");
const select = $(`#tracks-body select[data-track="{track["track_id"]}"]`);
select.value = "other:";
fire(select, "change");
phase = "during";
byId("tracks-save").click();
await settle();
const wait = () => (byId("tracks-wait").hidden ? null : textOf(byId("tracks-wait")));
const waiting = {{
  wait: wait(),
  error: textOf($("#tracks-error .notice-title")),
  unsaved: textOf(byId("tracks-unsaved")),
  rosterUnsaved: textOf($("#roster-columns section .unsaved")),
  locked: $$("#tracks-body select[data-track]").every((s) => s.disabled),
}};
phase = "after";
await settle();
console.log(JSON.stringify({{
  sent,
  waiting,
  wait: wait(),
  rows: $$("#tracks-body tr[data-track]").map((tr) => Number(tr.dataset.track)).sort((a, b) => a - b),
  unsaved: textOf(byId("tracks-unsaved")),
  locked: $$("#tracks-body select[data-track]").some((s) => s.disabled),
  navigatedTo: page.window.navigatedTo || null,
}}));
""",
    )
    assert out["sent"] == [["roster", roster_body], ["track", track_body]]  # the roster first; no re-run
    waiting = out["waiting"]
    assert waiting["wait"].startswith("Film analysis in progress")
    assert (waiting["error"], waiting["unsaved"], waiting["rosterUnsaved"], waiting["locked"]) == (
        refused.json()["error"]["title"],
        "1 unsaved change",
        "",  # the roster was saved
        True,
    )
    assert out["wait"].startswith("Film analysis finished")  # the choice made for the earlier run's track went
    assert out["rows"] == sorted(a["track_id"] for a in after["tracks"]["assignments"])
    assert (out["unsaved"], out["locked"], out["navigatedTo"]) == ("", False, None)
    assert after["rosters"]["scouted"]["players"][0]["first_name"] == "Renamed"
