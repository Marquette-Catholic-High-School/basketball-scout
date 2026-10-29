"""Regression tests from the fifth review round: the Roster page.

They run the real Roster page in the node fake-DOM harness of ``tests/test_review_frontend.py``
with the routes of ``tests/test_review3_frontend.py`` and ``tests/test_review4_frontend.py``.
The seam test takes its answers from the real API and an in-process worker (demo mode).

docs/ARCHITECTURE.md (Extra rules, Full re-analysis): "a Roster page opened before the Full
re-analysis started reads the tracks again before it saves, and shows the new table instead of
saving when they were numbered again". README (Rosters and jersey matching): "If the film was
analysed again (a Full re-analysis, for example from another tab) since you opened the page,
Save & re-run analysis shows the new table instead of saving: make your choices again there."
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from scout import config
from scout.main import create_app
from scout.worker import Worker
from tests.test_review3_frontend import ROSTER_TRACKS_JS, SMITH_SET_BY_COACH_JS, SMITH_TRACK_JS
from tests.test_review3_integration import _upload_film
from tests.test_review4_frontend import ANALYSIS_JS, CONFLICT_JS, WAIT_NOTICE
from tests.test_review4_verify_frontend import _for_page
from tests.test_review_frontend import run_page

# GET /tracks answers ``tracks`` (a body, or a fake failure such as { network: true }): the page
# loads one run's tracks, then another tab may change them. The game's latest job is ``latest``.
# ``writes()`` lists what the page sent; ``notices()`` the notices a coach can see.
PAGE_JS = """
let tracks = null;
route("GET", "/api/games/g_1/tracks", () => (tracks.network || tracks.status ? tracks : json(tracks)));
let latest = job({ id: "j_0", kind: "analyze", status: "succeeded", stage: "done", progress: 100 });
let gameOver = {};
route("GET", "/api/games/g_1", () => json(game({ latest_job_id: latest.id, ...gameOver })));
route("GET", /^\\/api\\/jobs\\/j_\\d+$/, (req) => (req.path.endsWith(`/${latest.id}`) ? json(latest) : fail(404, "NOT_FOUND", "Not found")));
async function openPage(body) {
  tracks = body;
  await import("./js/roster.js");
  await settle();
}
const writes = () => server.log.filter((entry) => !entry.startsWith("GET"));
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const notices = () => $$(".notice").filter(visible).map(textOf);
const trackRows = () => $$("#tracks-body tr[data-track]").map((tr) => Number(tr.dataset.track));
const gameLink = () => $$("a").filter(visible).find((a) => textOf(a) === "Open the game page")?.getAttribute("href") ?? null;
"""

ANALYSED_AGAIN = "Film analysed again"
AUTOMATIC = "Automatic (best jersey match)"
NOTHING_PENDING = {"note": "", "saveDisabled": True, "changed": []}


def _says_tracks_were_numbered_again(text: str) -> bool:
    return (
        text.startswith(ANALYSED_AGAIN)
        and "numbered again since this page was opened" in text
        and "from another tab" in text
        and "your unsaved track choices were dropped" in text
    )


# ---------------------------------------------------------------------------
# 1. Save & re-run reads the tracks again before it sends the choices
# ---------------------------------------------------------------------------


def test_save_after_a_full_reanalysis_from_another_tab_shows_the_new_table_instead(tmp_path):
    """A tab left open across a whole Full re-analysis (started and finished in another tab) sent its
    choices keyed to the earlier run's track ids; no ANALYZE was active any more, so the server took
    them and the next run put them on the new run's tracks with those numbers: other players."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + f"""
await openPage({{
  assignments: [{SMITH_TRACK_JS}, assignment({{ track_id: 8, team_id: 1, side: "other", method: "manual" }})],
  overrides: [{{ track_id: 8, player_id: null, side: "other", ignore: false }}],
}});
pickText(7, "Unknown player (Lincoln)");
pickText(8, "{AUTOMATIC}");
const before = pending();
// Another tab's Full re-analysis: its run numbers the tracks from the start again (the same numbers are
// other players), and installing it cleared the assignments.
latest = job({{ id: "j_2", kind: "analyze", status: "succeeded", stage: "done", progress: 100 }});
tracks = {{ assignments: [
  assignment({{ track_id: 7, team_id: 1, side: "other", frames: 120, best_read: "4", votes: {{ 4: 2 }}, method: "unrostered" }}),
  assignment({{ track_id: 8, frames: 450 }}),
  assignment({{ track_id: 9, team_id: 1, side: "other", frames: 80 }}),
], overrides: [] }};
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{
  before,
  writes: writes(),
  rows: trackRows(),
  seen: [cells(7)[1], cells(8)[1]],
  shown: trackRows().map((id) => shown(id)),
  ...pending(),
  notices: notices(),
  byTable: textOf(byId("tracks-wait")),
  navigatedTo: page.window.navigatedTo || null,
}}));
""",
    )
    assert out["before"] == {"note": "2 unsaved changes", "saveDisabled": False, "changed": [7, 8]}
    assert out["writes"] == []  # no PUT, no DELETE, no re-run
    assert out["rows"] == [8, 7, 9]  # the new run's table
    assert out["seen"] == ["120", "450"]
    assert out["shown"] == [AUTOMATIC] * 3
    assert {k: out[k] for k in NOTHING_PENDING} == NOTHING_PENDING
    assert out["notices"] == [out["byTable"]]  # by the new table, and the only one
    assert _says_tracks_were_numbered_again(out["byTable"]), out["byTable"]
    assert out["byTable"].endswith("Make them again in the new table.")
    assert out["navigatedTo"] is None


@pytest.mark.parametrize(
    ("game_over", "latest_job"),
    [
        # The new run's analysis failed after its install: the earlier analysis is gone, and there is no new one.
        (
            '{ status: "failed", has_analysis: false }',
            'job({ id: "j_2", kind: "analyze", status: "failed", stage: "analyzing", progress: 80 })',
        ),
        # A new film since, not analysed yet: the old film's tracks and analysis are gone.
        ('{ status: "uploaded", has_analysis: false }', "latest"),
    ],
    ids=["new-runs-analysis-failed", "new-film"],
)
def test_save_after_the_tracks_went_shows_no_table_and_says_so_where_it_was(tmp_path, game_over, latest_job):
    """The same with no tracks at all now: nothing is sent, the table goes, and the notice is shown
    outside its hidden card."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + f"""
await openPage({{ assignments: [{SMITH_TRACK_JS}, assignment({{ track_id: 8, team_id: 1, side: "other" }})], overrides: [] }});
pickText(7, "Unknown player (Lincoln)");
latest = {latest_job};
gameOver = {game_over};
tracks = {{ assignments: [], overrides: [] }};
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{
  writes: writes(),
  tracksShown: !byId("tracks").hidden,
  rows: trackRows(),
  notices: notices(),
  link: gameLink(),
  ...pending(),
  navigatedTo: page.window.navigatedTo || null,
}}));
""",
    )
    assert out["writes"] == []
    assert (out["tracksShown"], out["rows"]) == (False, [])
    [shown] = out["notices"]
    assert _says_tracks_were_numbered_again(shown), shown
    assert "There are no tracks to assign now: see the game page." in shown
    assert "new table" not in shown
    assert out["link"] == "/games/g_1"
    assert {k: out[k] for k in NOTHING_PENDING} == NOTHING_PENDING
    assert out["navigatedTo"] is None


def test_save_with_the_same_tracks_goes_ahead_with_the_coachs_choices(tmp_path):
    """Guard: another tab saved an assignment and re-ran (a REANALYZE keeps the track numbers), so the
    matches and the saved assignments differ but the tracks are the same: the save goes ahead with this
    tab's choices, "keep team" with the team the table showed, and the other tab's choice stays."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + f"""
const jonesRead = {{ team_id: 1, side: "other", best_read: "4", votes: {{ 4: 3 }}, frames: 200 }};
await openPage({{ assignments: [
  {SMITH_TRACK_JS},
  assignment({{ track_id: 8, ...jonesRead, player_id: "p_2", jersey: "4", match_score: 1, method: "exact" }}),
  assignment({{ track_id: 9, frames: 150 }}),
], overrides: [] }});
pickText(7, "Unknown player (keep team)");
pickText(8, "Not a player (referee, coach, fan…)");
// Another tab made track 9 Jones and re-ran: track 8 no longer matches him.
latest = job({{ id: "j_1", kind: "reanalyze", status: "succeeded", stage: "done", progress: 100 }});
tracks = {{ assignments: [
  {SMITH_TRACK_JS},
  assignment({{ track_id: 8, ...jonesRead, match_score: 1, method: "unrostered" }}),
  assignment({{ track_id: 9, frames: 150, side: "other", player_id: "p_2", jersey: "4", match_score: 1, method: "manual" }}),
], overrides: [{{ track_id: 9, player_id: "p_2", side: "other", ignore: false }}] }};
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ trackPuts, writes: writes(), navigatedTo: page.window.navigatedTo || null }}));
""",
    )
    assert out["trackPuts"] == [
        {"track_id": 7, "player_id": None, "side": "scouted", "ignore": False},
        {"track_id": 8, "player_id": None, "side": "other", "ignore": True},
    ]
    assert out["writes"] == [
        "PUT /api/games/g_1/tracks/7",
        "PUT /api/games/g_1/tracks/8",
        "POST /api/games/g_1/jobs",
    ]
    assert out["navigatedTo"] == "/games/g_1"


def test_save_works_out_the_changes_against_the_assignments_saved_now(tmp_path):
    """The changes go against the assignments the server holds when the coach saves, not those the page
    loaded: another tab had already set track 7 back to Automatic (the page sent a DELETE that could only
    answer 404) and made track 9 "Not a player", which a failed save then showed as Automatic."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + f"""
const others = [assignment({{ track_id: 8, team_id: 1, side: "other" }}), assignment({{ track_id: 9, frames: 150 }})];
await openPage({{ assignments: [{SMITH_SET_BY_COACH_JS}, ...others],
  overrides: [{{ track_id: 7, player_id: "p_1", side: "scouted", ignore: false }}] }});
pickText(7, "{AUTOMATIC}");
pickText(8, "Unknown player (keep team)");
tracks = {{ assignments: [{SMITH_TRACK_JS}, ...others], overrides: [{{ track_id: 9, player_id: null, side: "scouted", ignore: true }}] }};
route("DELETE", "/api/games/g_1/tracks/7", fail(404, "NOT_FOUND", "Track 7 has no manual assignment"));
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, () => fail(500, "INTERNAL_ERROR", "Something went wrong"));
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{
  writes: writes(),
  error: textOf($("#tracks-error .notice-title")),
  shown: [shown(7), shown(8), shown(9)],
  ...pending(),
}}));
""",
    )
    assert out["writes"] == ["PUT /api/games/g_1/tracks/8"]
    assert out["error"] == "Something went wrong"
    assert out["shown"] == [AUTOMATIC, "Unknown player (keep team)", "Not a player (referee, coach, fan…)"]
    assert (out["note"], out["saveDisabled"], out["changed"]) == ("1 unsaved change", False, [8])


@pytest.mark.parametrize(
    ("failure", "title"),
    [
        ("{ network: true }", "Can't reach the server"),
        ('fail(503, "SERVER_UNAVAILABLE", "Server unavailable", { retryable: true })', "Server unavailable"),
    ],
    ids=["network", "server-unavailable"],
)
def test_save_that_cannot_read_the_tracks_again_sends_nothing_and_keeps_the_choices(tmp_path, failure, title):
    """If the tracks cannot be read again, the page cannot tell whether they were numbered again: it
    sends nothing, says why, and keeps the choices for the next try."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + f"""
await openPage({{ assignments: [{SMITH_TRACK_JS}], overrides: [] }});
pickText(7, "Unknown player (Lincoln)");
tracks = {failure};
byId("tracks-save").click();
await settle();
const failed = {{
  writes: writes(),
  error: textOf($("#tracks-error .notice-title")),
  shown: shown(7),
  ...pending(),
  navigatedTo: page.window.navigatedTo || null,
}};
tracks = {{ assignments: [{SMITH_TRACK_JS}], overrides: [] }}; // the server answers again
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ failed, trackPuts, writes: writes(), navigatedTo: page.window.navigatedTo || null }}));
""",
    )
    assert out["failed"] == {
        "writes": [],
        "error": title,
        "shown": "Unknown player (Lincoln)",
        "note": "1 unsaved change",
        "saveDisabled": False,
        "changed": [7],
        "navigatedTo": None,
    }
    assert out["trackPuts"] == [{"track_id": 7, "player_id": None, "side": "other", "ignore": False}]
    assert out["writes"] == ["PUT /api/games/g_1/tracks/7", "POST /api/games/g_1/jobs"]
    assert out["navigatedTo"] == "/games/g_1"


def test_save_while_the_full_analysis_is_still_analysing_its_new_run_waits_for_it(tmp_path):
    """The tracks changed because another tab's Full re-analysis has installed its run and is still
    analysing it (no tracks to read yet): the page sends nothing and waits for it, as after a refused
    save, rather than dropping the choices before the new table exists; when it ends the new table comes
    and the choices go."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + ANALYSIS_JS
        + CONFLICT_JS
        + f"""
let analysed = true;
route("GET", "/api/games/g_1", () => json(game(analysisJob ? {{ status: "processing", latest_job_id: "j_1", has_analysis: analysed }} : {{}})));
await openPage({{ assignments: [{SMITH_TRACK_JS}], overrides: [] }});
pickText(7, "Unknown player (Lincoln)");
setJob({{ stage: "analyzing", progress: 85 }});
analysed = false;
tracks = {{ assignments: [], overrides: [] }};
byId("tracks-save").click();
await settle();
const waiting = {{ writes: writes(), wait: wait(), error: textOf(byId("tracks-error")), rows: rows(), ...locked(), ...pending() }};
analysed = true;
tracks = {{ assignments: [assignment({{ track_id: 7, team_id: 1, side: "other", frames: 90 }}), assignment({{ track_id: 12 }})], overrides: [] }};
setJob({{ status: "succeeded", stage: "done", progress: 100 }});
await settle();
console.log(JSON.stringify({{ waiting, wait: wait(), rows: rows(), shown: shown(7), ...pending(), ...locked(), writes: writes() }}));
""",
    )
    waiting = out["waiting"]
    assert waiting.pop("wait").startswith(WAIT_NOTICE)
    assert waiting == {
        "writes": [],
        "error": "",
        "rows": [7],
        "selects": [True],
        "save": True,
        "rerun": True,
        "note": "1 unsaved change",
        "saveDisabled": True,
        "changed": [7],
    }
    assert out["wait"].startswith("Film analysis finished") and "your unsaved track choices were dropped" in out["wait"]
    assert (out["rows"], out["shown"]) == ([12, 7], AUTOMATIC)
    assert (out["note"], out["saveDisabled"], out["changed"]) == ("", True, [])
    assert (out["selects"], out["rerun"]) == ([False, False], False)
    assert out["writes"] == []


# ---------------------------------------------------------------------------
# 2. Choices dropped by a full analysis that left no table
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("stage", ["analyzing", "downloading_results"])
def test_choices_dropped_by_a_full_analysis_without_results_are_announced_where_they_can_be_seen(tmp_path, stage):
    """The choices kept after a 409 are dropped when the ANALYZE has installed its new run. When that run
    then has no analysis (it failed after the install), the tracks card stays hidden, so its notice inside
    the card was never seen, and it said to make them again "in the new table", which there is not."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + ANALYSIS_JS
        + CONFLICT_JS
        + f"""
let analysed = true;
route("GET", "/api/games/g_1", () => json(game(analysisJob ? {{ status: "processing", latest_job_id: "j_1", has_analysis: analysed }} : {{}})));
await openPage({{ assignments: [{SMITH_TRACK_JS}, assignment({{ track_id: 8, side: "other", team_id: 1 }})], overrides: [] }});
pickText(7, "Unknown player (Lincoln)");
setJob({{}});
byId("tracks-save").click();
await settle();
const refused = {{ wait: wait(), ...pending() }};
analysed = false;
tracks = {{ assignments: [], overrides: [] }};
setJob({{ status: "failed", stage: "{stage}", progress: 80, error: {{ code: "ANALYSIS_FAILED", title: "Analysis failed",
  message: "x", hint: null, retryable: true, detail: null }} }});
await settle();
console.log(JSON.stringify({{ refused, tracksShown: !byId("tracks").hidden, notices: notices(), link: gameLink(), ...pending() }}));
""",
    )
    assert out["refused"]["wait"].startswith(WAIT_NOTICE)
    assert out["refused"]["note"] == "1 unsaved change"
    assert out["tracksShown"] is False
    [shown] = out["notices"]
    assert shown.startswith("Film analysis finished without results"), shown
    assert "your unsaved track choices were dropped" in shown
    assert "See the game page" in shown
    assert "new table" not in shown
    assert out["link"] == "/games/g_1"
    assert (out["note"], out["saveDisabled"]) == ("", True)


# ---------------------------------------------------------------------------
# Extra: the table stays when reading it again fails; Save & re-run with nothing left
# ---------------------------------------------------------------------------


def test_tracks_that_cannot_be_reloaded_after_a_cancelled_analysis_keep_their_table(tmp_path):
    """Extra: a full analysis cancelled before its results were in place keeps the earlier run, and the
    page reads its tracks again. When that read failed, the page forgot the tracks while their rows (with
    the kept choices) stayed: the filter no longer redrew them, "keep team" was saved with no team, and
    the check before saving would have taken them for tracks numbered again."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + ANALYSIS_JS
        + CONFLICT_JS
        + f"""
const runA = {{ assignments: [{SMITH_TRACK_JS}, assignment({{ track_id: 8, side: "other", team_id: 1 }})], overrides: [] }};
await openPage(runA);
pickText(7, "Unknown player (keep team)");
setJob({{ status: "queued", stage: "queued" }});
byId("tracks-save").click();
await settle();
tracks = {{ network: true }};
setJob({{ status: "cancelled", stage: "gpu_processing", progress: 30 }});
await settle();
const reloadFailed = {{ error: textOf($("#tracks-error .notice-title")), rows: rows(), ...pending() }};
reloadFailed.opponent = showTracks("other");
showTracks("");
tracks = runA;
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ reloadFailed, saved: trackPuts[trackPuts.length - 1], notices: notices(), navigatedTo: page.window.navigatedTo || null }}));
""",
    )
    assert out["reloadFailed"] == {
        "error": "Can't reach the server",
        "rows": [7, 8],
        "opponent": [8],
        "note": "1 unsaved change",
        "saveDisabled": False,
        "changed": [7],
    }
    assert out["saved"] == {"track_id": 7, "player_id": None, "side": "scouted", "ignore": False}
    assert not any(text.startswith(ANALYSED_AGAIN) for text in out["notices"])
    assert out["navigatedTo"] == "/games/g_1"


def test_save_and_rerun_with_nothing_left_to_save_stays_disabled_after_a_failed_rerun(tmp_path):
    """Extra: once the choices were saved and the re-run did not start, the rows still showed them as
    unsaved changes and the end of the busy state enabled Save & re-run again with nothing to save, until
    something redrew the table (the new table that replaces dropped choices had the same button)."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + f"""
route("POST", "/api/games/g_1/jobs", fail(503, "QUEUE_UNAVAILABLE", "The job queue is not available"));
await load([{SMITH_TRACK_JS}]);
pickText(7, "Unknown player (Lincoln)");
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ error: textOf($("#page-error .notice-title")), puts: trackPuts.length, ...pending(),
  label: textOf(byId("tracks-save")), rerun: byId("rerun-btn").disabled }}));
""",
    )
    assert out == {
        "error": "The job queue is not available",
        "puts": 1,
        "note": "",
        "saveDisabled": True,
        "changed": [],
        "label": "Save & re-run analysis",
        "rerun": False,
    }


# ---------------------------------------------------------------------------
# Seam: the real server's tracks before and after a Full re-analysis
# ---------------------------------------------------------------------------


@pytest.fixture
def client(monkeypatch, auth_headers):
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    config.reset_settings()
    with TestClient(create_app()) as c:
        c.headers.update(auth_headers)
        yield c


def _tracking(assignment: dict) -> tuple:
    return (assignment["track_id"], assignment["frames"], assignment["team_id"], assignment["best_read"])


def test_a_page_opened_before_a_full_reanalysis_saves_nothing_onto_the_new_runs_tracks(tmp_path, client):
    """The Roster page against the real API: loaded on the first run, then a Full re-analysis ran to the
    end (another tab) and numbered the tracks again. Its new run uses the same track numbers for other
    tracks, and with no ANALYZE active the server takes a change for them, so only the page can tell."""
    worker = Worker(worker_id="w-review5-roster")
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
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()  # another tab
    assert worker.run_once(timeout=2)
    after = {
        "game": client.get(f"/api/games/{game_id}").json(),
        "tracks": client.get(f"/api/games/{game_id}/tracks").json(),
        "job": client.get(f"/api/jobs/{full['id']}").json(),
    }
    assert (after["job"]["status"], after["game"]["latest_job_id"]) == ("succeeded", full["id"])
    old = {a["track_id"]: a for a in before["tracks"]["assignments"]}
    new = {a["track_id"]: a for a in after["tracks"]["assignments"]}
    shared = sorted(old.keys() & new.keys())
    assert any(_tracking(old[i]) != _tracking(new[i]) for i in shared)  # the same numbers, other tracks
    track_id = next(i for i in shared if old[i]["role"] == "player" and old[i]["side"])

    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        f"""
const before = {_for_page(before, game_id)};
const after = {_for_page(after, game_id)};
let phase = "before";
const now = () => (phase === "after" ? after : before);
route("GET", "/api/games/g_1", () => json(now().game));
route("GET", "/api/games/g_1/rosters", json(before.rosters));
route("GET", "/api/games/g_1/tracks", () => json(now().tracks));
route("GET", "/api/jobs/" + before.job.id, json(before.job));
route("GET", "/api/jobs/" + after.job.id, json(after.job));
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => json(req.body)); // as the server would
route("POST", "/api/games/g_1/jobs", json(job({{ kind: "reanalyze" }}), 201));
await import("./js/roster.js");
await settle();
const select = $(`#tracks-body select[data-track="{track_id}"]`);
select.value = "__none"; // Unknown player (keep team)
fire(select, "change");
const unsaved = textOf(byId("tracks-unsaved"));
phase = "after";
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{
  unsaved,
  writes: server.log.filter((entry) => !entry.startsWith("GET")),
  rows: $$("#tracks-body tr[data-track]").map((tr) => Number(tr.dataset.track)).sort((a, b) => a - b),
  seen: textOf($(`#tracks-body tr[data-track="{track_id}"] td.num`)),
  notice: byId("tracks-wait").hidden ? null : textOf(byId("tracks-wait")),
  after: textOf(byId("tracks-unsaved")),
  navigatedTo: page.window.navigatedTo || null,
}}));
""",
    )
    assert out["unsaved"] == "1 unsaved change"
    assert out["writes"] == []
    assert out["rows"] == sorted(new)
    assert out["seen"] == str(new[track_id]["frames"])
    assert _says_tracks_were_numbered_again(out["notice"]), out["notice"]
    assert (out["after"], out["navigatedTo"]) == ("", None)
