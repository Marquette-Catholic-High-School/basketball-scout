"""Regression tests from the fourth frontend review round.

They reuse the node fake-DOM harness of ``tests/test_review_frontend.py`` (the real page
scripts against the real HTML, ``fetch`` answered by fake routes, timers shortened to 1 ms)
and the Roster page routes of ``tests/test_review3_frontend.py``.
"""

from __future__ import annotations

import re

import pytest

from tests.test_review3_frontend import ROSTER_TRACKS_JS, SMITH_SET_BY_COACH_JS, SMITH_TRACK_JS
from tests.test_review_frontend import STATIC, run_page

# Jones (#4, Lincoln) as the coach's assignment for a track.
JONES_OVERRIDE_JS = '{ track_id: 7, player_id: "p_2", side: "other", ignore: false }'

# The Roster page while a full analysis may run: ``analysisJob`` is the game's latest job
# (j_1), ``setJob`` changes what GET /api/jobs/j_1 answers, ``locked()`` reads the lock.
# The game's GPU results stay on the server until a new run's are in place (has_tracking).
ANALYSIS_JS = """
let analysisJob = null;
const setJob = (over) => { analysisJob = over && job({ id: "j_1", kind: "analyze", status: "running", stage: "gpu_processing", progress: 40, ...over }); };
route("GET", "/api/games/g_1", () => json(game({ has_tracking: true, ...(analysisJob ? { status: "processing", latest_job_id: "j_1" } : {}) })));
route("GET", "/api/jobs/j_1", () => (analysisJob ? json(analysisJob) : fail(404, "NOT_FOUND", "Not found")));
const wait = () => (byId("tracks-wait") && !byId("tracks-wait").hidden ? textOf(byId("tracks-wait")) : null);
const locked = () => ({
  selects: $$("#tracks-body select[data-track]").map((s) => s.disabled),
  save: byId("tracks-save").disabled,
  rerun: byId("rerun-btn").disabled,
});
const rows = () => $$("#tracks-body tr[data-track]").map((tr) => Number(tr.dataset.track));
const rosterButton = (text) => $$("#roster-columns section")[0].querySelectorAll("button").find((b) => textOf(b) === text);
"""

WAIT_NOTICE = "Film analysis in progress"


def _shows(notice: str | None, title: str) -> bool:
    """The notice by the tracks table is shown and starts with ``title``."""
    return notice is not None and notice.startswith(title)


# ---------------------------------------------------------------------------
# 8. "Unknown player (keep team)" keeps the team the table shows
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("track", "overrides", "side"),
    [
        # The tracker put track 7 on the scouted team; the coach then made it Lincoln's #4 Jones.
        (
            'assignment({ track_id: 7, team_id: 0, side: "other", player_id: "p_2", jersey: "4", best_read: "4", '
            'votes: { 4: 3 }, match_score: 1, method: "manual" })',
            f"[{JONES_OVERRIDE_JS}]",
            "other",
        ),
        # No team from the tracker; its reads matched #23 Smith, so the table shows Central.
        (SMITH_TRACK_JS.replace("track_id: 7,", "track_id: 7, team_id: null,"), "[]", "scouted"),
        # A referee: the table shows no team, so none is sent (guard).
        ('assignment({ track_id: 7, team_id: null, side: null, role: "referee" })', "[]", None),
    ],
    ids=["moved-to-the-other-team", "team-from-a-jersey-match", "no-team"],
)
def test_keep_team_sends_the_team_the_table_shows(tmp_path, track, overrides, side):
    """README (Rosters and jersey matching): "Unknown player (keep team) keeps the team the
    table shows." The page sent no side, so the server took the tracker's team
    (matcher._apply_override): a track an earlier choice had moved to the other team went
    back, and one whose team came from a jersey match lost it."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + f"""
await load([{track}], {overrides});
const team = cells(7)[0];
const picked = pickText(7, "Unknown player (keep team)");
const before = pending();
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ team, picked, before, trackPuts, navigatedTo: page.window.navigatedTo || null }}));
""",
    )
    assert out["team"] == {"other": "Lincoln", "scouted": "Central", None: "–"}[side]
    assert out["picked"] is True
    assert out["before"] == {"note": "1 unsaved change", "saveDisabled": False, "changed": [7]}
    assert out["trackPuts"] == [{"track_id": 7, "player_id": None, "side": side, "ignore": False}]
    assert out["navigatedTo"] == "/games/g_1"


def test_keep_team_for_a_track_saved_as_its_teams_unknown_player_is_no_change(tmp_path):
    """Keep team sends the side the table shows; for a track saved as that team's unknown
    player that is the saved override again, so it is no change, though the select's value
    differs (the page compared select values only)."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + """
await load(
  [assignment({ track_id: 7, team_id: 1, side: "other", method: "manual" }), assignment({ track_id: 8, method: "manual" })],
  [{ track_id: 7, player_id: null, side: "other", ignore: false }, { track_id: 8, player_id: null, side: "scouted", ignore: false }],
);
const loaded = [shown(7), shown(8)];
pickText(7, "Unknown player (keep team)");
pickText(8, "Unknown player (keep team)");
const keepTeam = pending();
pickText(8, "Unknown player (Lincoln)"); // the other team: a change
const otherTeam = pending();
pickText(8, "Unknown player (keep team)");
console.log(JSON.stringify({ loaded, keepTeam, otherTeam, back: pending() }));
""",
    )
    assert out["loaded"] == ["Unknown player (Lincoln)", "Unknown player (Central)"]
    nothing = {"note": "", "saveDisabled": True, "changed": []}
    assert out["keepTeam"] == nothing
    assert out["otherTeam"] == {"note": "1 unsaved change", "saveDisabled": False, "changed": [8]}
    assert out["back"] == nothing


# ---------------------------------------------------------------------------
# 9. The Roster page during a full analysis (ANALYZE)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(("status", "stage"), [("queued", "queued"), ("running", "gpu_processing")])
def test_track_assignments_wait_while_a_full_analysis_runs(tmp_path, status, stage):
    """ARCHITECTURE (Extra rules): the server refuses track changes (409) while an ANALYZE is
    queued or running, since installing its new run clears them. The page offered them
    anyway; now it says why they wait and locks them, and the rosters stay editable."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + f"""
setJob({{ status: "{status}", stage: "{stage}" }});
await load([{SMITH_TRACK_JS}, assignment({{ track_id: 8, side: "other", team_id: 1 }})]);
const before = {{ wait: wait(), ...locked(), titles: [byId("tracks-save").title, byId("rerun-btn").title] }};
// The rosters stay editable: add a player and save.
rosterButton("+ Add player").click();
const jersey = $$("#roster-columns section")[0].querySelector('input[data-i="1"][data-key="jersey"]');
jersey.value = "11";
fire(jersey, "input");
const saveRoster = rosterButton("Save roster");
const rosterSaveDisabled = saveRoster.disabled;
saveRoster.click();
await settle();
console.log(JSON.stringify({{
  before,
  rosterSaveDisabled,
  rosterPuts: server.log.filter((entry) => entry.startsWith("PUT /api/games/g_1/rosters")).length,
  banner: !byId("rerun-banner").hidden,
  after: {{ wait: wait(), ...locked() }},
  polls: server.log.filter((entry) => entry === "GET /api/jobs/j_1").length,
}}));
""",
    )
    before = out["before"]
    notice = before.pop("wait")
    assert _shows(notice, WAIT_NOTICE), notice
    assert "Track assignments can be made once it has finished" in notice
    assert "numbers the players' tracks again and clears their assignments" in notice
    assert "keep editing the rosters" in notice
    assert before == {
        "selects": [True, True],
        "save": True,
        "rerun": True,
        "titles": ["Wait for the film analysis to finish"] * 2,
    }
    assert out["rosterSaveDisabled"] is False
    assert out["rosterPuts"] == 1
    assert out["banner"] is True  # "Roster saved", its Re-run analysis button locked
    after = out["after"]
    assert _shows(after.pop("wait"), WAIT_NOTICE)
    assert after == {"selects": [True, True], "save": True, "rerun": True}
    assert out["polls"] >= 2


def test_locked_assignment_selects_look_disabled():
    """A locked select should look like the locked buttons beside it. Measured in headless
    Chrome: with the page's own select style it kept the colour, background and cursor of
    an enabled one, only Chrome's 0.7 opacity set it apart; it now fades and shows the
    not-allowed cursor as a disabled button does."""
    css = (STATIC / "css" / "app.css").read_text(encoding="utf-8")
    rule = re.search(r"\.track-table select:disabled\s*\{([^}]*)\}", css)
    assert rule, "no .track-table select:disabled rule"
    assert re.search(r"opacity:\s*0\.55", rule.group(1)) and re.search(r"cursor:\s*not-allowed", rule.group(1))


def test_track_assignments_unlock_and_reload_when_the_full_analysis_finishes(tmp_path):
    """When the ANALYZE ends, the page loads the game and its new tracks again (the earlier
    run's track ids and assignments are gone) and unlocks them."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + f"""
setJob({{}});
let tracks = {{ assignments: [{SMITH_SET_BY_COACH_JS}], overrides: [{{ track_id: 7, player_id: "p_1", side: "scouted", ignore: false }}] }};
route("GET", "/api/games/g_1/tracks", () => json(tracks));
await import("./js/roster.js");
await settle();
const before = {{ wait: wait(), rows: rows(), shown: shown(7), ...locked() }};
tracks = {{ assignments: [assignment({{ track_id: 3 }}), assignment({{ track_id: 4, side: "other", team_id: 1 }})], overrides: [] }};
setJob({{ status: "succeeded", stage: "done", progress: 100 }});
await settle();
console.log(JSON.stringify({{
  before,
  after: {{ wait: wait(), rows: rows(), shown: [shown(3), shown(4)], ...locked(), titled: byId("rerun-btn").hasAttribute("title") }},
  pending: pending(),
  gameLoads: server.log.filter((entry) => entry === "GET /api/games/g_1").length,
}}));
""",
    )
    before = out["before"]
    assert _shows(before.pop("wait"), WAIT_NOTICE)
    assert before == {"rows": [7], "shown": "#23 Sam Smith", "selects": [True], "save": True, "rerun": True}
    # The new run's tracks, without the earlier run's assignment (installing it cleared them).
    assert out["after"] == {
        "wait": None,
        "rows": [3, 4],
        "shown": ["Automatic (best jersey match)"] * 2,
        "selects": [False, False],
        "save": True,
        "rerun": False,
        "titled": False,
    }
    assert out["pending"] == {"note": "", "saveDisabled": True, "changed": []}
    assert out["gameLoads"] == 2  # on load, and again when the analysis ended


def test_tracks_table_appears_when_the_first_analysis_finishes(tmp_path):
    """A game analysed for the first time has no tracks table yet; it appears when the
    analysis ends, without a reload."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + f"""
let finished = false;
setJob({{ status: "queued", stage: "queued" }});
route("GET", "/api/games/g_1", () => json(game({{ status: finished ? "ready" : "queued", has_analysis: finished, latest_job_id: "j_1" }})));
route("GET", "/api/games/g_1/tracks", () => json({{ assignments: finished ? [{SMITH_TRACK_JS}] : [], overrides: [] }}));
await import("./js/roster.js");
await settle();
const before = {{ shown: !byId("tracks").hidden, tracksLoads: server.log.filter((e) => e === "GET /api/games/g_1/tracks").length }};
finished = true;
setJob({{ status: "succeeded", stage: "done", progress: 100 }});
await settle();
console.log(JSON.stringify({{ before, shown: !byId("tracks").hidden, wait: wait(), rows: rows(), ...locked() }}));
""",
    )
    assert out["before"] == {"shown": False, "tracksLoads": 0}
    assert out["shown"] is True
    assert (out["wait"], out["rows"], out["selects"], out["rerun"]) == (None, [7], [False], False)


def test_a_reanalysis_running_leaves_track_assignments_open(tmp_path):
    """Guard: only a full analysis numbers the tracks again; a REANALYZE reads the overrides
    when it starts, and the server takes track changes meanwhile."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + f"""
setJob({{ kind: "reanalyze", stage: "analyzing" }});
await load([{SMITH_TRACK_JS}]);
const before = {{ wait: wait(), ...locked() }};
pickText(7, "Unknown player (keep team)");
console.log(JSON.stringify({{ before, ...pending(), polls: server.log.filter((e) => e === "GET /api/jobs/j_1").length }}));
""",
    )
    assert out["before"] == {"wait": None, "selects": [False], "save": True, "rerun": False}
    assert (out["note"], out["saveDisabled"], out["changed"]) == ("1 unsaved change", False, [7])
    assert out["polls"] <= 1  # looked at most once: no polling


# The server's answer to a track change while an ANALYZE is queued or running.
CONFLICT_JS = """
const conflict = () => fail(409, "CONFLICT", "Conflict", { message: "This game's film is being analysed right now.", hint: "Wait for it to finish." });
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {
  trackPuts.push(req.body);
  if (analysisJob && ["queued", "running"].includes(analysisJob.status)) return conflict();
  return json({ track_id: Number(req.path.split("/").pop()), ...req.body });
});
"""


def test_track_change_refused_by_a_full_analysis_keeps_the_choices_and_waits(tmp_path):
    """An ANALYZE started after the page loaded: the PUT answers 409. The page shows the
    server's message, keeps the unsaved choices and waits, locked, for the analysis; one
    cancelled before its results were in place leaves the tracks as they were, so the
    choices can then be saved."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + CONFLICT_JS
        + f"""
await load([{SMITH_TRACK_JS}, assignment({{ track_id: 8, side: "other", team_id: 1 }})]);
pickText(7, "Unknown player (Central)");
pickText(8, "#4 Jo Jones");
setJob({{ status: "queued", stage: "queued" }}); // the analysis starts
byId("tracks-save").click();
await settle();
const refused = {{
  error: $("#tracks-error .notice-error")?.children.map(textOf),
  wait: wait(),
  ...pending(),
  shown: [shown(7), shown(8)],
  ...locked(),
  navigatedTo: page.window.navigatedTo || null,
}};
setJob({{ status: "cancelled", stage: "gpu_processing", progress: 30 }}); // before its results were installed
await settle();
const cancelled = {{ error: textOf(byId("tracks-error")), wait: wait(), ...pending(), shown: [shown(7), shown(8)], ...locked() }};
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ refused, cancelled, trackPuts, navigatedTo: page.window.navigatedTo || null }}));
""",
    )
    refused = out["refused"]
    assert refused.pop("error") == ["Conflict", "This game's film is being analysed right now.", "Wait for it to finish."]
    assert _shows(refused.pop("wait"), WAIT_NOTICE)
    assert refused == {
        "note": "2 unsaved changes",
        "saveDisabled": True,
        "changed": [7, 8],
        "shown": ["Unknown player (Central)", "#4 Jo Jones"],
        "selects": [True, True],
        "save": True,
        "rerun": True,
        "navigatedTo": None,
    }
    assert out["cancelled"] == {
        "error": "",
        "wait": None,
        "note": "2 unsaved changes",
        "saveDisabled": False,
        "changed": [7, 8],
        "shown": ["Unknown player (Central)", "#4 Jo Jones"],
        "selects": [False, False],
        "save": False,
        "rerun": False,
    }
    refused_put = {"track_id": 7, "player_id": None, "side": "scouted", "ignore": False}
    assert out["trackPuts"] == [
        refused_put,
        refused_put,
        {"track_id": 8, "player_id": "p_2", "side": "other", "ignore": False},
    ]
    assert out["navigatedTo"] == "/games/g_1"


def test_unsaved_choices_are_dropped_when_the_full_analysis_numbers_the_tracks_again(tmp_path):
    """The choices kept after a 409 were made for the earlier run's tracks. Once the ANALYZE
    has installed its new run they would land on whatever tracks now have those numbers, so
    the page drops them and says so."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + CONFLICT_JS
        + f"""
let tracks = {{ assignments: [{SMITH_TRACK_JS}], overrides: [] }};
route("GET", "/api/games/g_1/tracks", () => json(tracks));
await import("./js/roster.js");
await settle();
pickText(7, "Unknown player (Lincoln)");
setJob({{}});
byId("tracks-save").click();
await settle();
const refused = {{ wait: wait(), ...pending() }};
tracks = {{ assignments: [assignment({{ track_id: 7, side: "other", team_id: 1 }}), assignment({{ track_id: 9 }})], overrides: [] }};
setJob({{ status: "succeeded", stage: "done", progress: 100 }});
await settle();
console.log(JSON.stringify({{ refused, wait: wait(), rows: rows(), shown: shown(7), ...pending(), ...locked(), puts: trackPuts.length }}));
""",
    )
    assert out["refused"]["note"] == "1 unsaved change"
    assert _shows(out["refused"]["wait"], WAIT_NOTICE)
    assert _shows(out["wait"], "Film analysis finished"), out["wait"]
    assert "your unsaved track choices were dropped" in out["wait"]
    assert out["rows"] == [9, 7]
    assert out["shown"] == "Automatic (best jersey match)"  # the new track 7 is another player
    assert (out["note"], out["saveDisabled"], out["changed"]) == ("", True, [])
    assert (out["selects"], out["rerun"]) == ([False, False], False)
    assert out["puts"] == 1


def test_rerun_refused_by_a_full_analysis_locks_the_track_assignments(tmp_path):
    """Re-run analysis after a roster save answered 409 because an ANALYZE had started: it
    will clear the assignments, so the page waits for it as after a refused track change,
    and the Re-run button stays locked after its busy state ends."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + f"""
route("POST", "/api/games/g_1/jobs", () => (analysisJob
  ? fail(409, "CONFLICT", "Conflict", {{ message: "This game's film is being analysed right now." }})
  : json(job({{ kind: "reanalyze" }}), 201)));
await load([{SMITH_TRACK_JS}]);
rosterButton("Save roster").click();
await settle();
setJob({{ status: "queued", stage: "queued" }});
byId("rerun-btn").click();
await settle();
console.log(JSON.stringify({{
  error: textOf($("#page-error .notice-title")),
  wait: wait(),
  ...locked(),
  navigatedTo: page.window.navigatedTo || null,
}}));
""",
    )
    assert out["error"] == "Conflict"
    assert _shows(out["wait"], WAIT_NOTICE), out["wait"]
    assert (out["selects"], out["save"], out["rerun"]) == ([True], True, True)
    assert out["navigatedTo"] is None


def test_page_that_stops_checking_the_analysis_says_so_and_offers_a_reload(tmp_path):
    """If polling gives up, the assignments stay locked (the analysis may still run) and the
    notice says so, with a reload."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + ANALYSIS_JS
        + f"""
let reloads = 0;
page.window.location.reload = () => {{ reloads += 1; }};
setJob({{}});
await load([{SMITH_TRACK_JS}]);
route("GET", "/api/jobs/j_1", fail(401, "AUTH_REQUIRED", "Please sign in"));
await settle();
const reload = $$("#tracks-wait button").find((b) => textOf(b) === "Reload the page");
if (reload) reload.click();
console.log(JSON.stringify({{ wait: wait(), reloads, ...locked() }}));
""",
    )
    assert _shows(out["wait"], "Stopped checking the film analysis"), out["wait"]
    assert "track assignments stay locked" in out["wait"]
    assert out["reloads"] == 1
    assert (out["selects"], out["save"], out["rerun"]) == ([True], True, True)


# ---------------------------------------------------------------------------
# Extra: a double click on Save & re-run
# ---------------------------------------------------------------------------


def test_save_and_rerun_stays_busy_while_it_saves_the_roster_first(tmp_path):
    """Extra: Save & re-run saves an edited roster first, and that save redrew the tracks
    table, which enabled the busy button again. A second click then saved the tracks and
    started the re-run twice, and the button kept the label "Saving…" for good."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + f"""
route("PUT", /^\\/api\\/games\\/g_1\\/rosters\\/\\w+$/, async (req) => {{
  await pause(5);
  return json(roster(req.path.split("/").pop(), req.body.players));
}});
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, async (req) => {{
  trackPuts.push(req.body);
  await pause(60);
  return json({{ track_id: Number(req.path.split("/").pop()), ...req.body }});
}});
await load([{SMITH_TRACK_JS}]);
pickText(7, "Unknown player (keep team)");
const name = $$("#roster-columns section")[0].querySelector('input[data-i="0"][data-key="first_name"]');
name.value = "Samuel";
fire(name, "input");
byId("tracks-save").click();
await pause(30); // the roster is saved, the track change is on its way
const midway = {{ disabled: byId("tracks-save").disabled, label: textOf(byId("tracks-save")) }};
byId("tracks-save").click(); // the second click of a double click
for (let i = 0; i < 200 && !page.window.navigatedTo; i += 1) await pause(5);
await settle();
console.log(JSON.stringify({{
  midway,
  label: textOf(byId("tracks-save")),
  trackPuts: trackPuts.length,
  reruns: server.log.filter((entry) => entry === "POST /api/games/g_1/jobs").length,
}}));
""",
    )
    assert out == {
        "midway": {"disabled": True, "label": "Saving…"},
        "label": "Save & re-run analysis",
        "trackPuts": 1,
        "reruns": 1,
    }


# ---------------------------------------------------------------------------
# 10. Re-run analysis for an ANALYZE whose GPU results were saved
# ---------------------------------------------------------------------------

# The game page with its latest job failed: __KIND__ at __STAGE__, error retryable __RETRYABLE__.
FAILED_JOB_JS = """
const error = { code: "CONFIG_INVALID", title: "Configuration problem", message: "A setting in .env is invalid.",
  hint: "Fix the setting, then restart the worker.", retryable: __RETRYABLE__, detail: null };
const failed = job({ kind: "__KIND__", status: "failed", stage: "__STAGE__", progress: 80, error });
gamePageRoutes(route, json, {
  gameBody: game({ status: "failed", has_analysis: false, latest_job_id: "j_1", error }),
  jobs: [failed],
});
route("GET", "/api/jobs/j_1", json(failed));
await import("./js/game.js");
await settle();
"""


def _failed_job_js(kind: str, stage: str, retryable: bool) -> str:
    return (
        FAILED_JOB_JS.replace("__KIND__", kind).replace("__STAGE__", stage).replace("__RETRYABLE__", str(retryable).lower())
    )


@pytest.mark.parametrize(
    ("kind", "stage", "retryable", "buttons"),
    [
        ("analyze", "analyzing", False, ["Re-run analysis"]),
        ("analyze", "reporting", False, ["Re-run analysis"]),
        ("analyze", "analyzing", True, ["Re-run analysis"]),
        ("analyze", "gpu_processing", False, []),
        ("analyze", "gpu_processing", True, ["Retry"]),
        ("reanalyze", "analyzing", False, []),
    ],
    ids=[
        "gpu-results-saved-not-retryable",
        "failed-writing-the-report",
        "gpu-results-saved-retryable",
        "failed-on-the-gpu-not-retryable",
        "failed-on-the-gpu-retryable",
        "reanalysis-not-retryable",
    ],
)
def test_failed_analysis_offers_rerun_once_the_gpu_results_are_saved(tmp_path, kind, stage, retryable, buttons):
    """ARCHITECTURE (Job lifecycle, Retry): an ANALYZE that failed after its GPU results were
    saved (stage analyzing or reporting) is retried as a REANALYZE; the page offers that
    retry as "Re-run analysis" even for an error that is not retryable (CONFIG_INVALID).
    Other failed jobs keep "Retry", and only when retryable."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        _failed_job_js(kind, stage, retryable)
        + """
console.log(JSON.stringify({ title: textOf($("#job-panel .notice-title")), buttons: $$("#job-panel button").map(textOf) }));
""",
    )
    assert out == {"title": "Configuration problem", "buttons": buttons}


def test_rerun_analysis_after_a_config_error_posts_the_retry(tmp_path):
    """The button posts /api/jobs/{id}/retry, which the server turns into a REANALYZE, and
    the panel follows the new job."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        _failed_job_js("analyze", "analyzing", False)
        + """
const retry = job({ id: "j_2", kind: "reanalyze", status: "running", stage: "analyzing", progress: 50 });
let retried = false;
route("POST", "/api/jobs/j_1/retry", () => { retried = true; return json({ ...retry, status: "queued", stage: "queued" }); });
route("GET", "/api/jobs/j_2", json(retry));
route("GET", "/api/games/g_1/jobs", () => json(retried ? [retry, failed] : [failed]));
route("GET", "/api/games/g_1", () => json(game(retried ? { status: "processing", latest_job_id: "j_2" }
  : { status: "failed", has_analysis: false, latest_job_id: "j_1", error })));
const button = $$("#job-panel button").find((b) => textOf(b) === "Re-run analysis");
if (button) button.click();
await settle();
console.log(JSON.stringify({ posts: server.log.filter((e) => e.startsWith("POST")), panel: textOf($("#job-panel h2")) }));
""",
    )
    assert out == {"posts": ["POST /api/jobs/j_1/retry"], "panel": "Re-analysis in progress"}


@pytest.mark.parametrize(
    ("stage", "retryable"), [("analyzing", False), ("gpu_processing", False)], ids=["rerun", "no-button"]
)
def test_failed_analysis_hint_names_no_retry_button(tmp_path, stage, retryable):
    """Extra: under a failed first analysis the page said "use Retry once the problem is
    fixed", but the panel's button reads "Re-run analysis" once the GPU results are saved,
    and there is none for an error that is not retryable."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        _failed_job_js("analyze", stage, retryable)
        + """
console.log(JSON.stringify({ pending: $("#analysis-pending .notice").children.map(textOf), buttons: $$("#job-panel button").map(textOf) }));
""",
    )
    assert out["pending"] == [
        "There are no results because the analysis failed.",
        "See the error above and run the analysis again once the problem is fixed.",
    ]
    assert "Retry" not in out["buttons"]


# ---------------------------------------------------------------------------
# 11. "Unclear match" for a track with no team
# ---------------------------------------------------------------------------


def test_unclear_match_title_covers_a_track_with_no_team_whose_number_is_on_both_rosters(tmp_path):
    """matcher._acceptable_candidates: a track with no team whose best read is a number both
    rosters have stays unmatched (it does not guess the team), and shows no jersey. The
    tooltip only named another track or split readings."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + """
const lee = { id: "p_3", jersey: "23", first_name: "Al", last_name: "Lee" };
route("GET", "/api/games/g_1/rosters", json({ scouted: roster("scouted", [smith]), other: roster("other", [jones, lee]) }));
await load([assignment({ track_id: 2, team_id: null, side: null, best_read: "23", votes: { 23: 4 }, match_score: 1,
  method: "unrostered" })]);
const how = rowFor(2).querySelectorAll("td")[6];
console.log(JSON.stringify({ text: textOf(how), title: how.getAttribute("title"), team: cells(2)[0] }));
""",
    )
    assert (out["text"], out["team"]) == ("Unclear match", "–")
    title = out["title"]
    assert "both rosters have that number and the track has no team" in title
    assert "another track was matched to that player" in title and "too split" in title
    assert title.endswith("Assign it yourself if you know who it is.")
    assert len(title) <= 240  # still a tooltip


# ---------------------------------------------------------------------------
# 12. The fake DOM ignores a click on a disabled control
# ---------------------------------------------------------------------------


def test_fake_dom_ignores_a_click_on_a_disabled_control(tmp_path):
    """A browser ignores click() on a disabled button; the fake DOM ran its listeners, which
    let a round-three regression pass (Save & re-run was disabled, the test clicked it)."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        """
const button = document.createElement("button");
document.body.append(button);
let clicks = 0;
button.addEventListener("click", () => { clicks += 1; });
button.disabled = true;
button.click();
const whileDisabled = clicks;
button.disabled = false;
button.click();
console.log(JSON.stringify({ whileDisabled, enabled: clicks }));
""",
    )
    assert out == {"whileDisabled": 0, "enabled": 1}
