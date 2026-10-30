"""Regression tests from the sixth review round: the Roster page.

They run the real Roster page in the node fake-DOM harness of ``tests/test_review_frontend.py`` with the
routes of ``tests/test_review3_frontend.py`` and a fake server that keeps what it is sent, as the real one
does. The seam tests take their answers from the real API and an in-process worker (demo mode).

* A wait for a full analysis that ends while another tab has already started the next one keeps waiting,
  the table locked (README "Court calibration": the Roster page "locks them while it runs").
* The Re-run analysis banner after a roster save follows the server's ``Game.has_tracking``
  (docs/ARCHITECTURE.md, "Job lifecycle").
* A full analysis that numbered the tracks again, when the new tracks then cannot be read, says to reload
  the page and leaves no old track count.
* README "Rosters and jersey matching": "If you remove a player from a roster, the track choices for that
  player that you had not saved are dropped (the page says which tracks), and saving the roster removes
  that player's saved assignments."
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from scout import config
from scout.errors import ErrorCode
from scout.main import create_app
from scout.processing import mock
from scout.worker import Worker
from tests.test_review3_frontend import ROSTER_TRACKS_JS, SMITH_TRACK_JS
from tests.test_review3_integration import _upload_film
from tests.test_review4_frontend import WAIT_NOTICE
from tests.test_review4_integration import _failing_once
from tests.test_review4_verify_frontend import _for_page
from tests.test_review5_integration import KEEP_TEAM, _numbered_again, _replay, _roster_bodies, _roster_tab
from tests.test_review5_verify_roster import _analysed_game, _run
from tests.test_review_frontend import run_page

AUTOMATIC = "Automatic (best jersey match)"
NOT_A_PLAYER = "Not a player (referee, coach, fan…)"
FINISHED_DROPPED = (
    "Film analysis finished"
    "It numbered the players' tracks again, so your unsaved track choices were dropped. Make them again in the new table."
)
# Round-6 verification: "was removed", still true once the player is back (tests/test_review6_verify_roster.py).
DROPPED_T8 = "Track choices droppedYour unsaved choice for track T8 was dropped: its player was removed from the roster."

# A fake server that keeps what it is sent, as the real one does (scout/api/rosters.py, tracks.py, jobs.py):
# the rosters, whose save removes the saved assignments of the players who left them; the assignments
# (``saved``), refused while an ANALYZE is queued or running (409) or when they name a player on no roster
# (422); the jobs (``setJob``; ``latest`` is the game's latest job) and the tracks of the run on the server
# (``run``; GET /tracks answers ``tracksFail`` instead when set). ``gameOver`` changes the game.
SERVER_JS = """
const rosters = { scouted: [smith], other: [jones] };
const saved = new Map();
let run = [];
let tracksFail = null;
let gameOver = {};
let latest = null;
const jobs = {};
const setJob = (over) => {
  jobs[over.id] = job({ kind: "analyze", status: "queued", stage: "queued", progress: 0, ...jobs[over.id], ...over });
};
const busy = (kinds) => Object.values(jobs).some((j) => kinds.includes(j.kind) && ["queued", "running"].includes(j.status));
const onRoster = (playerId, side) => (side ? [side] : ["scouted", "other"]).some((s) => rosters[s].some((p) => p.id === playerId));
const prune = () => { for (const [id, o] of saved) if (o.player_id && !onRoster(o.player_id, o.side)) saved.delete(id); };
const analysing = () => fail(409, "CONFLICT", "Conflict", { message: "This game's film is being analysed on the GPU." });
route("GET", "/api/games/g_1", () => json(game({ has_tracking: true, latest_job_id: latest, ...gameOver })));
route("GET", "/api/games/g_1/rosters", () => json({ scouted: roster("scouted", rosters.scouted), other: roster("other", rosters.other) }));
let added = 0;
route("PUT", /^\\/api\\/games\\/g_1\\/rosters\\/\\w+$/, (req) => {
  const side = req.path.split("/").pop();
  rosters[side] = req.body.players.map((p) => ({ ...p, id: p.id || `p_new${(added += 1)}` }));
  prune();
  return json(roster(side, rosters[side]));
});
route("GET", "/api/games/g_1/tracks", () => tracksFail || json({ assignments: run, overrides: [...saved.values()] }));
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {
  trackPuts.push(req.body);
  if (busy(["analyze"])) return analysing();
  if (req.body.player_id && !onRoster(req.body.player_id, req.body.side)) {
    return fail(422, "VALIDATION_FAILED", "Check the details", { message: `Player ${req.body.player_id} is not on the ${req.body.side} roster.` });
  }
  const body = { track_id: Number(req.path.split("/").pop()), ...req.body };
  saved.set(body.track_id, body);
  return json(body);
});
route("DELETE", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {
  if (busy(["analyze"])) return analysing();
  return saved.delete(Number(req.path.split("/").pop())) ? { status: 204 } : fail(404, "NOT_FOUND", "Not found");
});
route("POST", "/api/games/g_1/jobs", (req) => {
  if (busy(["analyze", "reanalyze"])) return fail(409, "CONFLICT", "Conflict", { message: "This game's film is being analysed right now." });
  if (gameOver.has_tracking === false) return fail(409, "ANALYSIS_NOT_READY", "Analysis not ready");
  return json(job({ id: "j_rerun", kind: req.body.kind }), 201);
});
route("GET", /^\\/api\\/jobs\\/[\\w-]+$/, (req) => {
  const body = jobs[req.path.split("/").pop()];
  return body ? json(body) : fail(404, "NOT_FOUND", "Not found");
});
async function openPage(assignments, overrides = []) {
  run = assignments;
  for (const o of overrides) saved.set(o.track_id, o);
  await import("./js/roster.js");
  await settle();
}
const editor = (side) => $$("#roster-columns section")[side === "scouted" ? 0 : 1];
const removeRow = (side, row) => editor(side).querySelectorAll("button[data-remove]")[row].click();
const editorButton = (side, text) => editor(side).querySelectorAll("button").find((b) => textOf(b) === text);
const typeIn = (side, row, key, value) => {
  const input = editor(side).querySelector(`input[data-i="${row}"][data-key="${key}"]`);
  input.value = value;
  fire(input, "input");
};
const importFile = async (side, text) => {
  const input = editor(side).querySelector("input[type=file]");
  input.fileList = [new File([text], "roster.csv", { type: "text/csv" })];
  fire(input, "change");
  await settle();
};
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
/** The notice by the table that says which tracks lost their choice with their player; null when none is shown. */
const droppedNotice = () => (byId("tracks-dropped") && visible(byId("tracks-dropped")) ? textOf(byId("tracks-dropped")) : null);
const notices = () => $$(".notice").filter(visible).map(textOf);
const writes = () => server.log.filter((entry) => !entry.startsWith("GET"));
const rows = () => $$("#tracks-body tr[data-track]").map((tr) => Number(tr.dataset.track));
const look = () => ({
  rows: rows(),
  locked: $$("#tracks-body select[data-track]").map((s) => s.disabled),
  rerunLocked: byId("rerun-btn").disabled,
  ...pending(),
  notices: notices(),
});
"""

# The runs on the server: A when the page loads; B and C, Full re-analyses that number the tracks again.
RUNS = {
    "__RUN_A__": f'[{SMITH_TRACK_JS}, assignment({{ track_id: 8, team_id: 1, side: "other" }})]',
    "__RUN_A3__": (
        f'[{SMITH_TRACK_JS}, assignment({{ track_id: 8, team_id: 1, side: "other" }}), '
        'assignment({ track_id: 9, team_id: 1, side: "other", frames: 200 })]'
    ),
    "__RUN_B__": """[
  assignment({ track_id: 7, team_id: 1, side: "other", frames: 120, best_read: "4", votes: { 4: 2 }, method: "unrostered" }),
  assignment({ track_id: 8, frames: 450 }),
  assignment({ track_id: 9, team_id: 1, side: "other", frames: 80 }),
]""",
    "__RUN_C__": '[assignment({ track_id: 3, frames: 500 }), assignment({ track_id: 7, team_id: 1, side: "other", frames: 60 })]',
}


def _titles(notices: list[str]) -> list[str]:
    """Which notices these are: each one's title as the page writes it, or its text when it has none of these."""
    titles = ["Film analysis finished", WAIT_NOTICE, "Conflict", "Roster saved", "Track choices dropped"]
    return [next((t for t in titles if text.startswith(t)), text) for text in notices]


def _page(tmp_path, script: str, **args) -> dict:
    """The Roster page on the fake server; ``args`` are ``ARGS`` in the script, ``__RUN_X__`` the runs above."""
    for name, run in RUNS.items():
        script = script.replace(name, run)
    return run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS + SERVER_JS + f"const ARGS = {json.dumps(args)};\n" + script,
    )


# The page waits for B, another tab's Full re-analysis: Save & re-run was refused (409) while B was queued.
WAIT_FOR_B_JS = """
await openPage(__RUN_A__);
pickText(7, "Unknown player (Lincoln)");
setJob({ id: "j_b" });
latest = "j_b";
byId("tracks-save").click();
await settle();
"""


# ---------------------------------------------------------------------------
# 1. A wait that ends while the next full analysis is queued keeps waiting
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("ends", ["succeeded", "cancelled"])
def test_a_wait_that_ends_while_the_next_full_analysis_is_queued_keeps_waiting(tmp_path, ends):
    """The page waits, locked, for another tab's Full re-analysis B. Within one poll that tab cancels B and
    starts the next one, C (Start again, or Full re-analysis). The wait ended on B's end and unlocked the
    table with the choices kept, though installing C clears the assignments (fails on HEAD); the next save
    got a 409 and waited after all. Now the page waits for C too, and C's end decides, as for any wait."""
    out = _page(
        tmp_path,
        WAIT_FOR_B_JS
        + """
const waitingForB = look();
setJob({ id: "j_b", status: "cancelled" });
setJob({ id: "j_c" });
latest = "j_c";
await settle();
const waitingForC = { ...look(), polled: server.log.includes("GET /api/jobs/j_c") };
if (ARGS.ends === "succeeded") {
  run = __RUN_C__;
  saved.clear(); // installing it cleared the assignments
  setJob({ id: "j_c", status: "succeeded", stage: "done", progress: 100 });
} else {
  setJob({ id: "j_c", status: "cancelled" });
}
await settle();
const ended = look();
const refused = trackPuts.length;
if (!ended.saveDisabled) {
  byId("tracks-save").click();
  await settle();
}
console.log(JSON.stringify({ waitingForB, waitingForC, ended, sent: trackPuts.slice(refused),
  navigatedTo: page.window.navigatedTo || null }));
""",
        ends=ends,
    )
    locked = {"rows": [7, 8], "locked": [True, True], "rerunLocked": True, "note": "1 unsaved change",
              "saveDisabled": True, "changed": [7]}
    waiting_for_b, waiting_for_c = out["waitingForB"], out["waitingForC"]
    notices = waiting_for_b.pop("notices")
    assert waiting_for_b == locked
    assert _titles(notices) == [WAIT_NOTICE, "Conflict"]
    notices = waiting_for_c.pop("notices")
    assert waiting_for_c == {**locked, "polled": True}
    assert _titles(notices) == [WAIT_NOTICE]  # the 409 was about B
    ended = out["ended"]
    if ends == "succeeded":
        assert ended == {"rows": [3, 7], "locked": [False, False], "rerunLocked": False, "note": "",
                         "saveDisabled": True, "changed": [], "notices": [FINISHED_DROPPED]}
        assert (out["sent"], out["navigatedTo"]) == ([], None)
    else:
        assert ended == {"rows": [7, 8], "locked": [False, False], "rerunLocked": False, "note": "1 unsaved change",
                         "saveDisabled": False, "changed": [7], "notices": []}
        assert out["sent"] == [{"track_id": 7, "player_id": None, "side": "other", "ignore": False}]
        assert out["navigatedTo"] == "/games/g_1"


@pytest.mark.parametrize("latest_job", ["the-same", "a-reanalysis"])
def test_a_wait_that_ends_with_no_full_analysis_after_it_unlocks_the_table(tmp_path, latest_job):
    """Guard: the game's latest job is still the analysis waited for (cancelled before its install), or a
    re-run started after it (a REANALYZE keeps the track numbers): the table unlocks with the choices kept,
    and the page does not poll the re-run."""
    out = _page(
        tmp_path,
        WAIT_FOR_B_JS
        + """
setJob({ id: "j_b", status: "cancelled" });
if (ARGS.latest === "a-reanalysis") {
  setJob({ id: "j_r", kind: "reanalyze", status: "running", stage: "analyzing", progress: 50 });
  latest = "j_r";
}
await settle();
console.log(JSON.stringify({ ...look(), reads: server.log.filter((entry) => entry === "GET /api/jobs/j_r").length }));
""",
        latest=latest_job,
    )
    assert out.pop("reads") <= 1  # looked at the re-run at most once: no polling
    assert out == {"rows": [7, 8], "locked": [False, False], "rerunLocked": False, "note": "1 unsaved change",
                   "saveDisabled": False, "changed": [7], "notices": []}


@pytest.mark.parametrize("first_ends", ["renumbered", "without-results"])
def test_choices_dropped_when_one_analysis_ends_are_announced_while_the_next_one_runs(tmp_path, first_ends):
    """B ends having put its new run in place, so the choices go, while another tab has already started the
    next Full re-analysis C. The notice that says the choices were dropped stays in view while the page waits
    for C, the table locked: by B's new table, or where the table was when B left none. On HEAD the table
    unlocked, and after a B without results nothing waited for C, so its new table never came."""
    out = _page(
        tmp_path,
        WAIT_FOR_B_JS
        + """
saved.clear();
if (ARGS.first === "renumbered") {
  run = __RUN_B__;
  setJob({ id: "j_b", status: "succeeded", stage: "done", progress: 100 });
} else {
  run = [];
  gameOver = { has_analysis: false };
  setJob({ id: "j_b", status: "failed", stage: "analyzing", progress: 80 });
}
setJob({ id: "j_c" });
latest = "j_c";
await settle();
const waitingForC = { ...look(), table: !byId("tracks").hidden };
run = __RUN_C__;
gameOver = {};
setJob({ id: "j_c", status: "succeeded", stage: "done", progress: 100 });
await settle();
console.log(JSON.stringify({ waitingForC, ended: { ...look(), table: !byId("tracks").hidden }, puts: trackPuts.length }));
""",
        first=first_ends,
    )
    waiting = out["waitingForC"]
    notices = waiting.pop("notices")
    nothing_pending = {"note": "", "saveDisabled": True, "changed": []}
    if first_ends == "renumbered":
        assert waiting == {"rows": [8, 7, 9], "locked": [True] * 3, "rerunLocked": True, "table": True, **nothing_pending}
        assert _titles(notices) == ["Film analysis finished", WAIT_NOTICE]
        assert notices[0] == FINISHED_DROPPED
    else:
        assert waiting == {"rows": [], "locked": [], "rerunLocked": True, "table": False, **nothing_pending}
        assert notices == [  # where the table was; the wait notice is in the hidden card
            "Film analysis finished without results"
            "A full analysis numbers the players' tracks again, so your unsaved track choices were dropped."
            "See the game page for what went wrong."
            "Open the game page"
        ]
    assert out["ended"] == {"rows": [3, 7], "locked": [False, False], "rerunLocked": False, "table": True,
                            **nothing_pending, "notices": [FINISHED_DROPPED]}
    assert out["puts"] == 1  # the refused one


# ---------------------------------------------------------------------------
# 2. The Re-run analysis banner after a roster save follows the server
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("loaded", "at_save", "banner"),
    [
        # Another tab added a new film since the page loaded: its GPU results and analysis are gone.
        ({}, {"status": "uploaded", "has_analysis": False, "has_tracking": False}, False),
        # The analysis failed after its GPU results were saved: a roster fix and a re-run is the cheap recovery.
        ({"status": "failed", "has_analysis": False}, {"status": "failed", "has_analysis": False}, True),
        ({}, {}, True),  # guard: an analysed game
    ],
    ids=["new-film-since", "failed-after-install", "analysed"],
)
def test_rerun_banner_after_a_roster_save_follows_the_game_the_server_has_now(tmp_path, loaded, at_save, banner):
    """The banner offered Re-run analysis when the game read at page load had an analysis: after a new film
    from another tab its click got 409 ANALYSIS_NOT_READY, and a game whose analysis failed after its GPU
    results were saved got no banner, though that is exactly when a re-run helps (both fail on HEAD). It now
    follows ``has_tracking`` in the game read after the save."""
    out = _page(
        tmp_path,
        """
gameOver = ARGS.loaded;
await openPage(__RUN_A__);
typeIn("scouted", 0, "fastscout_name", "Smith, Sam");
gameOver = ARGS.atSave;
editorButton("scouted", "Save roster").click();
await settle();
const banner = !byId("rerun-banner").hidden;
if (banner) {
  byId("rerun-btn").click();
  await settle();
}
console.log(JSON.stringify({ banner, writes: writes(), error: textOf(byId("page-error")),
  navigatedTo: page.window.navigatedTo || null }));
""",
        loaded=loaded,
        atSave=at_save,
    )
    assert out["banner"] is banner
    rerun = ["POST /api/games/g_1/jobs"] if banner else []
    assert out["writes"] == ["PUT /api/games/g_1/rosters/scouted", *rerun]
    assert out["error"] == ""
    assert out["navigatedTo"] == ("/games/g_1" if banner else None)


# ---------------------------------------------------------------------------
# 3. A renumbering whose new tracks cannot be read says to reload the page
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("choice", [True, False], ids=["with-a-choice", "no-choices"])
def test_new_tracks_that_cannot_be_read_after_a_renumbering_say_to_reload_the_page(tmp_path, choice):
    """The analysis waited for numbered the tracks again (the choices went), then reading its tracks failed:
    the card showed the read error and no rows beside "Make them again in the new table.", or with no choices
    pending the error alone, and the count still said "2 of 2 tracks" (fails on HEAD). Now the notice says to
    reload the page, with a button, and the old count goes."""
    out = _page(
        tmp_path,
        """
let reloads = 0;
page.window.location.reload = () => { reloads += 1; };
if (!ARGS.choice) { setJob({ id: "j_b" }); latest = "j_b"; } // the page opens while it waits in the queue
await openPage(__RUN_A__);
const count = textOf(byId("tracks-count"));
if (ARGS.choice) {
  pickText(7, "Unknown player (Lincoln)");
  setJob({ id: "j_b" });
  latest = "j_b";
  byId("tracks-save").click();
}
await settle();
const waiting = look();
run = __RUN_B__;
saved.clear();
tracksFail = { network: true };
setJob({ id: "j_b", status: "succeeded", stage: "done", progress: 100 });
await settle();
const ended = { ...look(), table: !byId("tracks").hidden, count: textOf(byId("tracks-count")) };
$$("#tracks-wait button").find((b) => textOf(b) === "Reload the page")?.click();
console.log(JSON.stringify({ count, waiting, ended, reloads }));
""",
        choice=choice,
    )
    assert out["count"] == "2 of 2 tracks"
    assert out["waiting"]["locked"] == [True, True]
    assert out["waiting"]["notices"][0].startswith(WAIT_NOTICE)
    ended = out["ended"]
    notices = ended.pop("notices")
    assert ended == {"rows": [], "locked": [], "rerunLocked": False, "note": "", "saveDisabled": True, "changed": [],
                     "table": True, "count": ""}
    went = ", so your unsaved track choices were dropped." if choice else "."
    said = f"Film analysis finishedIt numbered the players' tracks again{went}Reload the page to see the new table.Reload the page"
    assert notices[:1] == [said]
    assert [text.startswith("Can't reach the server") for text in notices[1:]] == [True]  # the read error
    assert out["reloads"] == 1


@pytest.mark.parametrize("before", ["a-first-analysis", "one-that-left-no-table"])
def test_new_tracks_that_cannot_be_read_where_no_table_was_say_to_reload_the_page(tmp_path, before):
    """The same when no table was shown as the analysis ended. A first analysis (the page opened before the
    game had one): the card came with the read error alone, and nothing said to reload (fails on HEAD). The
    analysis after one that left no table, waited for with that one's notice in view (the choices went): the
    card must not say "Make them again in the new table." beside the error and no rows (on HEAD the page did
    not wait for it at all)."""
    out = _page(
        tmp_path,
        """
let reloads = 0;
page.window.location.reload = () => { reloads += 1; };
if (ARGS.before === "a-first-analysis") {
  gameOver = { status: "processing", has_analysis: false, has_tracking: false };
  setJob({ id: "j_c" });
  latest = "j_c";
  await openPage([]);
} else {
  await openPage(__RUN_A__);
  pickText(7, "Unknown player (Lincoln)");
  setJob({ id: "j_b" });
  latest = "j_b";
  byId("tracks-save").click(); // refused: the page waits for B
  await settle();
  run = []; // B failed after installing its run: no analysis, no tracks
  saved.clear();
  gameOver = { has_analysis: false };
  setJob({ id: "j_b", status: "failed", stage: "analyzing", progress: 80 });
  setJob({ id: "j_c" });
  latest = "j_c";
  await settle();
}
const waiting = { ...look(), table: !byId("tracks").hidden };
run = __RUN_C__;
gameOver = {};
tracksFail = { network: true };
setJob({ id: "j_c", status: "succeeded", stage: "done", progress: 100 });
await settle();
const ended = { ...look(), table: !byId("tracks").hidden, count: textOf(byId("tracks-count")) };
$$("#tracks-wait button").find((b) => textOf(b) === "Reload the page")?.click();
console.log(JSON.stringify({ waiting, ended, reloads }));
""",
        before=before,
    )
    first = before == "a-first-analysis"
    nothing_pending = {"note": "", "saveDisabled": True, "changed": []}
    waiting = out["waiting"]
    notices = waiting.pop("notices")
    assert waiting == {"rows": [], "locked": [], "rerunLocked": True, "table": False, **nothing_pending}
    assert notices == ([] if first else [  # the wait for C is in the hidden card
        "Film analysis finished without results"
        "A full analysis numbers the players' tracks again, so your unsaved track choices were dropped."
        "See the game page for what went wrong."
        "Open the game page"
    ])
    ended = out["ended"]
    notices = ended.pop("notices")
    assert ended == {"rows": [], "locked": [], "rerunLocked": False, "table": True, "count": "", **nothing_pending}
    went = "" if first else "It numbered the players' tracks again, so your unsaved track choices were dropped."
    assert notices[:1] == [f"Film analysis finished{went}Reload the page to see the new table.Reload the page"]
    assert [text.startswith("Can't reach the server") for text in notices[1:]] == [True]  # the read error
    assert out["reloads"] == 1


# ---------------------------------------------------------------------------
# 4. Removing a player drops the unsaved track choices for that player
# ---------------------------------------------------------------------------


def test_save_and_rerun_after_removing_a_chosen_player_sends_no_choice_for_them(tmp_path):
    """The coach chose #4 Jones for track 8, then removed Jones from the roster. The choice stayed pending
    with a blank select, and Save & re-run saved the roster and then sent it: the server refused it (422,
    Jones is no longer on the roster) and the re-run did not start (fails on HEAD). Now it goes when Jones
    is removed, the page says which track lost its choice, and the save goes ahead with the others."""
    out = _page(
        tmp_path,
        """
await openPage(__RUN_A3__);
pickText(8, "#4 Jo Jones");
pickText(9, "Not a player (referee, coach, fan…)");
const before = pending();
removeRow("other", 0); // Jones was a wrong entry
const removed = { ...look(), shown: shown(8) };
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({ before, removed, trackPuts, writes: writes(),
  errors: [textOf(byId("tracks-error")), textOf(byId("page-error"))], navigatedTo: page.window.navigatedTo || null }));
""",
    )
    assert out["trackPuts"] == [{"track_id": 9, "player_id": None, "side": "other", "ignore": True}]
    assert out["writes"] == ["PUT /api/games/g_1/rosters/other", "PUT /api/games/g_1/tracks/9", "POST /api/games/g_1/jobs"]
    assert out["errors"] == ["", ""]
    assert out["navigatedTo"] == "/games/g_1"
    assert out["before"] == {"note": "2 unsaved changes", "saveDisabled": False, "changed": [8, 9]}
    assert out["removed"] == {"rows": [7, 8, 9], "locked": [False] * 3, "rerunLocked": False, "note": "1 unsaved change",
                              "saveDisabled": False, "changed": [9], "notices": [DROPPED_T8], "shown": AUTOMATIC}


@pytest.mark.parametrize("how", ["removed", "left-out-of-an-import"])
def test_the_page_says_which_tracks_lost_their_unsaved_choice_with_their_player(tmp_path, how):
    """The notice lists every track whose choice went: two tracks chosen as Jones, when Jones is removed or a
    roster file imported over the roster leaves him out (an import is saved at once, so the server dropped him
    too). The other choices stay (fails on HEAD: no notice, and the choices stayed pending, blank)."""
    out = _page(
        tmp_path,
        """
route("POST", "/api/games/g_1/rosters/other/import", () => {
  rosters.other = [{ id: "p_5", jersey: "5", first_name: "Test", last_name: "Player 5" }];
  prune();
  return json({ roster: roster("other", rosters.other), imported: 1, skipped_rows: [], warnings: [], detected_columns: {} });
});
await openPage([...__RUN_A3__, assignment({ track_id: 12, team_id: 1, side: "other", frames: 100 })]);
pickText(8, "#4 Jo Jones");
pickText(12, "#4 Jo Jones");
pickText(9, "Unknown player (Central)");
if (ARGS.how === "removed") removeRow("other", 0);
else await importFile("other", "Jersey,First Name,Last Name\\n5,Test,Player 5\\n");
console.log(JSON.stringify({ ...pending(), dropped: droppedNotice(),
  shown: [shown(8), shown(12), shown(9)] }));
""",
        how=how,
    )
    assert out == {
        "note": "1 unsaved change",
        "saveDisabled": False,
        "changed": [9],
        "dropped": "Track choices dropped"
        "Your unsaved choices for tracks T8 and T12 were dropped: their players were removed from the roster.",
        "shown": [AUTOMATIC, AUTOMATIC, "Unknown player (Central)"],
    }


def test_removing_a_player_no_choice_names_keeps_every_choice(tmp_path):
    """Guard: removing Jones, whom no choice names, drops nothing and says nothing."""
    out = _page(
        tmp_path,
        """
await openPage(__RUN_A3__);
pickText(8, "#23 Sam Smith");
pickText(9, "Unknown player (Lincoln)");
removeRow("other", 0);
const removed = { ...look(), shown: [shown(8), shown(9)], dropped: droppedNotice() };
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({ removed, trackPuts, writes: writes(), navigatedTo: page.window.navigatedTo || null }));
""",
    )
    assert out["removed"] == {"rows": [7, 8, 9], "locked": [False] * 3, "rerunLocked": False, "note": "2 unsaved changes",
                              "saveDisabled": False, "changed": [8, 9], "notices": [],
                              "shown": ["#23 Sam Smith", "Unknown player (Lincoln)"], "dropped": None}
    assert out["trackPuts"] == [
        {"track_id": 8, "player_id": "p_1", "side": "scouted", "ignore": False},
        {"track_id": 9, "player_id": None, "side": "other", "ignore": False},
    ]
    assert out["writes"] == ["PUT /api/games/g_1/rosters/other", "PUT /api/games/g_1/tracks/8",
                             "PUT /api/games/g_1/tracks/9", "POST /api/games/g_1/jobs"]
    assert out["navigatedTo"] == "/games/g_1"


def test_a_player_row_emptied_before_save_and_rerun_loses_its_choice_and_nothing_is_sent(tmp_path):
    """A row whose fields the coach cleared is left out of the roster saved, so Save & re-run removed Jones
    and then sent the choice naming him: 422 (fails on HEAD). Now the roster save drops that choice and says
    so, and Save & re-run stops there, so the coach sees it before the page moves on; the next click sends
    the rest."""
    out = _page(
        tmp_path,
        """
await openPage(__RUN_A3__);
pickText(8, "#4 Jo Jones");
pickText(9, "Not a player (referee, coach, fan…)");
for (const key of ["jersey", "first_name", "last_name"]) typeIn("other", 0, key, "");
byId("tracks-save").click();
await settle();
const first = { ...pending(), writes: writes(), dropped: droppedNotice(), navigatedTo: page.window.navigatedTo || null };
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({ first, trackPuts, writes: writes(), navigatedTo: page.window.navigatedTo || null }));
""",
    )
    assert out["first"] == {
        "note": "1 unsaved change",
        "saveDisabled": False,
        "changed": [9],
        "writes": ["PUT /api/games/g_1/rosters/other"],
        # Round-6 verification: it says what is left to do (tests/test_review6_verify_roster.py).
        "dropped": DROPPED_T8 + "Your other track choices are not saved yet: click Save & re-run analysis again.",
        "navigatedTo": None,
    }
    assert out["trackPuts"] == [{"track_id": 9, "player_id": None, "side": "other", "ignore": True}]
    assert out["writes"] == ["PUT /api/games/g_1/rosters/other", "PUT /api/games/g_1/tracks/9", "POST /api/games/g_1/jobs"]
    assert out["navigatedTo"] == "/games/g_1"


@pytest.mark.parametrize("back", ["typed-in-again", "imported-again"])
def test_a_removed_player_who_comes_back_brings_no_dropped_choice_back(tmp_path, back):
    """Undo paths: the editor has no undo, but the coach can type the player in again (a new player once
    saved) or import a file that has him (the server, which still has him, keeps his id). The choice that
    went with him stays gone, as the notice said; nothing is sent for a player the saved roster lacks (on
    HEAD the choice typed in again was sent for his old id: 422), and he can be chosen again once he is
    on the roster."""
    out = _page(
        tmp_path,
        """
route("POST", "/api/games/g_1/rosters/other/import", () => {
  rosters.other = [jones];
  return json({ roster: roster("other", rosters.other), imported: 1, skipped_rows: [], warnings: [], detected_columns: {} });
});
await openPage(__RUN_A3__);
pickText(8, "#4 Jo Jones");
pickText(9, "Not a player (referee, coach, fan…)");
removeRow("other", 0);
if (ARGS.back === "typed-in-again") {
  editorButton("other", "+ Add player").click();
  for (const [key, value] of [["jersey", "4"], ["first_name", "Jo"], ["last_name", "Jones"]]) typeIn("other", 0, key, value);
} else {
  await importFile("other", "Jersey,First Name,Last Name\\n4,Jo,Jones\\n");
}
const back = { ...pending(), shown: shown(8), offered: selectFor(8).options.map(textOf).includes("#4 Jo Jones"),
  dropped: droppedNotice() };
if (back.offered) pickText(8, "#4 Jo Jones");
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({ back, trackPuts, writes: writes(), navigatedTo: page.window.navigatedTo || null }));
""",
        back=back,
    )
    imported = back == "imported-again"
    assert out["back"] == {"note": "1 unsaved change", "saveDisabled": False, "changed": [9], "shown": AUTOMATIC,
                           "offered": imported, "dropped": DROPPED_T8}
    ignored = {"track_id": 9, "player_id": None, "side": "other", "ignore": True}
    if imported:  # chosen again, on the roster: saved
        assert out["trackPuts"] == [ignored, {"track_id": 8, "player_id": "p_2", "side": "other", "ignore": False}]
        assert out["writes"] == ["POST /api/games/g_1/rosters/other/import?mode=replace", "PUT /api/games/g_1/tracks/9",
                                 "PUT /api/games/g_1/tracks/8", "POST /api/games/g_1/jobs"]
    else:
        assert out["trackPuts"] == [ignored]
        assert out["writes"] == ["PUT /api/games/g_1/rosters/other", "PUT /api/games/g_1/tracks/9", "POST /api/games/g_1/jobs"]
    assert out["navigatedTo"] == "/games/g_1"


def test_the_notice_of_choices_dropped_with_their_player_goes_with_the_tracks_it_names(tmp_path):
    """The notice names tracks of the table shown. Its only choice went with Jones and the roster was saved;
    meanwhile another tab's Full re-analysis B numbered the tracks again and the next one, C, is queued, so
    Re-run analysis is refused (409) and the page waits. C is cancelled: the page shows B's table, where T8
    is another track. The notice that T8's choice was dropped stayed beside it when no other choice was
    pending; now it goes with the table it was about (on HEAD the choice stayed until the wait ended)."""
    out = _page(
        tmp_path,
        """
await openPage(__RUN_A3__);
pickText(8, "#4 Jo Jones");
removeRow("other", 0);
editorButton("other", "Save roster").click();
await settle();
const removed = { ...pending(), dropped: droppedNotice(), banner: !byId("rerun-banner").hidden };
run = __RUN_B__; // another tab's Full re-analysis B, finished
setJob({ id: "j_c" }); // and the next one, queued
latest = "j_c";
byId("rerun-btn").click();
await settle();
const waiting = { ...look(), dropped: droppedNotice() };
setJob({ id: "j_c", status: "cancelled" });
await settle();
console.log(JSON.stringify({ removed, waiting, ended: { ...look(), dropped: droppedNotice() }, writes: writes() }));
""",
    )
    assert out["removed"] == {"note": "", "saveDisabled": True, "changed": [], "dropped": DROPPED_T8, "banner": True}
    waiting = out["waiting"]
    assert _titles(waiting.pop("notices")) == ["Conflict", "Roster saved", WAIT_NOTICE, "Track choices dropped"]
    assert waiting == {"rows": [7, 8, 9], "locked": [True] * 3, "rerunLocked": True, "note": "", "saveDisabled": True,
                       "changed": [], "dropped": DROPPED_T8}
    ended = out["ended"]
    assert _titles(ended.pop("notices")) == ["Roster saved"]
    assert ended == {"rows": [8, 7, 9], "locked": [False] * 3, "rerunLocked": False, "note": "", "saveDisabled": True,
                     "changed": [], "dropped": None}
    assert out["writes"] == ["PUT /api/games/g_1/rosters/other", "POST /api/games/g_1/jobs"]


# ---------------------------------------------------------------------------
# 5. A saved assignment to a removed player does not show blank
# ---------------------------------------------------------------------------


def test_a_saved_assignment_to_a_removed_player_shows_them_as_removed_until_the_roster_is_saved(tmp_path):
    """Track 8 is saved as Jones. The coach removed Jones but has not saved the roster yet, so the assignment
    still holds; after any redraw (the filter here) its select was blank, as Jones was no longer an option
    (fails on HEAD). Now that select shows him, marked as removed; no other track is offered him."""
    out = _page(
        tmp_path,
        """
await openPage(__RUN_A3__, [{ track_id: 8, player_id: "p_2", side: "other", ignore: false }]);
const loaded = shown(8);
removeRow("other", 0);
const removed = { shown: shown(8), value: selectFor(8).value, ...pending() };
const filtered = { rows: showTracks("other"), shown: shown(8), value: selectFor(8).value };
showTracks("");
const elsewhere = [7, 9].map((id) => selectFor(id).options.map(textOf).filter((text) => text.includes("Jones")));
console.log(JSON.stringify({ loaded, removed, filtered, all: [shown(8), selectFor(8).value], elsewhere }));
""",
    )
    marked = "#4 Jo Jones (removed, not saved yet)"
    assert out["loaded"] == "#4 Jo Jones"
    assert out["removed"] == {"shown": marked, "value": "other:p_2", "note": "", "saveDisabled": True, "changed": []}
    assert out["filtered"] == {"rows": [8, 9], "shown": marked, "value": "other:p_2"}
    assert out["all"] == [marked, "other:p_2"]
    assert out["elsewhere"] == [[], []]


def test_after_the_roster_save_the_table_shows_the_assignments_the_server_kept(tmp_path):
    """Saving the roster removes the saved assignments of the players who left it (scout/api/rosters.py
    prune_track_overrides): the page reads the tracks again, so track 8 shows the automatic choice with no
    removed player left in any select, and track 9 (Smith, still on the roster) keeps its assignment."""
    out = _page(
        tmp_path,
        """
await openPage(__RUN_A3__, [{ track_id: 8, player_id: "p_2", side: "other", ignore: false },
  { track_id: 9, player_id: "p_1", side: "scouted", ignore: false }]);
removeRow("other", 0);
const logged = server.log.length;
editorButton("other", "Save roster").click();
await settle();
console.log(JSON.stringify({
  requests: server.log.slice(logged),
  shown: [shown(8), shown(9)],
  marked: $$("#tracks-body option").map(textOf).filter((text) => text.includes("removed")),
  ...pending(),
  banner: !byId("rerun-banner").hidden,
  kept: [...saved.keys()],
}));
""",
    )
    assert out["requests"] == ["PUT /api/games/g_1/rosters/other", "GET /api/games/g_1", "GET /api/games/g_1/tracks"]
    assert out["kept"] == [9]
    assert out["shown"] == [AUTOMATIC, "#23 Sam Smith"]
    assert out["marked"] == []
    assert (out["note"], out["saveDisabled"], out["changed"]) == ("", True, [])
    assert out["banner"] is True


# ---------------------------------------------------------------------------
# Seams: the real server's bodies
# ---------------------------------------------------------------------------

# The Roster page on the real server's bodies: ``phases.loaded`` until the page saves a roster,
# ``phases.saved`` after it (``put``: the server's answer to that save). What the page sends is recorded
# in ``sent``, to be replayed on the server; track changes and jobs are answered as it answers them.
REAL_JS = """
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
route("PUT", /^\\/api\\/games\\/g_1\\/rosters\\/\\w+$/, (req) => {
  sent.push(["PUT", req.path, req.body]);
  phase = "saved";
  return json(phases.saved.put);
});
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => { sent.push(["PUT", req.path, req.body]); return json(req.body); });
route("DELETE", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => { sent.push(["DELETE", req.path, null]); return { status: 204 }; });
route("POST", "/api/games/g_1/jobs", (req) => { sent.push(["POST", req.path, req.body]); return json(job({ kind: req.body.kind }), 201); });
await import("./js/roster.js");
await settle();
const editor = (side) => $$("#roster-columns section")[side === "scouted" ? 0 : 1];
const rowOf = (side, jersey) => editor(side).querySelectorAll('input[data-key="jersey"]').find((i) => i.value === jersey).dataset.i;
const removeJersey = (side, jersey) => editor(side).querySelector(`button[data-remove="${rowOf(side, jersey)}"]`).click();
const selectFor = (id) => $(`#tracks-body select[data-track="${id}"]`);
const choose = (id, value) => {
  selectFor(id).value = value;
  fire(selectFor(id), "change");
};
const shown = (id) => textOf(selectFor(id).options.find((o) => o.value === selectFor(id).value));
"""


@pytest.fixture
def scout(monkeypatch, auth_headers):
    """The app and an in-process worker in demo mode, as in ``tests/test_review5_verify_roster.py``."""
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    monkeypatch.setattr(mock, "DEFAULT_DURATION_S", 240.0)  # a shorter demo game: the same flow, a quicker analysis
    config.reset_settings()
    with TestClient(create_app()) as client:
        client.headers.update(auth_headers)
        yield SimpleNamespace(client=client, worker=Worker(worker_id="w-review6-roster"))


def _real_page(tmp_path, game_id: str, phases: dict, script: str, **args) -> dict:
    return run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        f"const phases = {_for_page(phases, game_id)};\nconst ARGS = {_for_page(args, game_id)};\n" + REAL_JS + script,
    )


def _roster_body(bodies: dict, side: str, *, without: tuple[str, ...] = (), fastscout: dict | None = None) -> dict:
    """What the Roster page's save sends for this roster as loaded (RosterEditor.collect), without the players
    whose jersey is in ``without`` and with the FastScout names in ``fastscout`` (jersey -> name)."""
    roster = bodies["rosters"][side]
    team = roster["team_name"] or bodies["game"]["scouted_team" if side == "scouted" else "other_team"]
    players = [
        {
            "id": p["id"],
            "jersey": p["jersey"],
            "first_name": p["first_name"],
            "last_name": p["last_name"],
            "fastscout_name": (fastscout or {}).get(p["jersey"], p["fastscout_name"]),
            **{key: p[key] for key in ("position", "grade", "height", "notes")},
        }
        for p in roster["players"]
        if p["jersey"] not in without
    ]
    return {"team_name": team, "players": players}


def test_the_real_servers_bodies_when_the_analysis_waited_for_is_cancelled_and_started_again(tmp_path, scout):
    """Item 1 with the real server, the round-5 integration probe: the page waits for a Full re-analysis
    (its save was refused); another tab cancels it and clicks Start again before the next poll. The page
    keeps waiting for the new one, locked, with the choice kept (on HEAD it unlocked), and when that one has
    numbered the tracks again the choice goes, with the notice by the new table."""
    client = scout.client
    game_id = _analysed_game(scout)
    loaded = _roster_bodies(scout, game_id)
    keep = next(a for a in loaded["tracks"]["assignments"] if a["role"] == "player" and a["side"])
    body = {"track_id": keep["track_id"], "player_id": None, "side": keep["side"], "ignore": False}
    path = f"/api/games/{game_id}/tracks/{keep['track_id']}"
    first = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()  # another tab
    refused = client.put(path, json=body)
    assert refused.status_code == 409, refused.text
    at_save = _roster_bodies(scout, game_id, refused.json())
    assert client.post(f"/api/jobs/{first['id']}/cancel").json()["status"] == "cancelled"
    again = client.post(f"/api/jobs/{first['id']}/retry")  # Start again
    assert again.status_code == 200, again.text
    second = again.json()
    assert (second["kind"], second["status"]) == ("analyze", "queued")
    still = client.put(path, json=body)
    assert still.status_code == 409, still.text  # the choice would be refused now too
    switched = _roster_bodies(scout, game_id, still.json())
    assert switched["game"]["latest_job_id"] == second["id"]
    assert _run(scout, second)["status"] == "succeeded"
    after = _roster_bodies(scout, game_id)
    assert _numbered_again(loaded, after)

    out = _roster_tab(
        tmp_path,
        game_id,
        {"loaded": loaded, "atSave": at_save, "switched": switched, "after": after},
        [[keep["track_id"], KEEP_TEAM]],
        [["saved", "atSave", "tracks-save"], ["switched", "switched", None], ["ended", "after", None]],
    )
    looks = out["looks"]
    assert (looks["saved"]["locked"], looks["saved"]["unsaved"]) == (True, "1 unsaved change")
    waiting = looks["switched"]
    assert (waiting["locked"], waiting["saveDisabled"], waiting["unsaved"], waiting["chosen"]) == (
        True, True, "1 unsaved change", [keep["track_id"]])
    assert _titles(waiting["notices"]) == [WAIT_NOTICE]
    assert f"GET /api/jobs/{second['id']}" in waiting["requests"]
    ended = looks["ended"]
    assert ended["rows"] == sorted(a["track_id"] for a in after["tracks"]["assignments"])
    assert (ended["locked"], ended["unsaved"], ended["chosen"], ended["notices"]) == (False, "", [], [FINISHED_DROPPED])
    assert out["sent"] == [["PUT", f"/api/games/g_1/tracks/{keep['track_id']}", body]]  # the refused one only


@pytest.mark.parametrize("other_tab", ["full-reanalysis-failed-after-install", "new-film"])
def test_the_real_servers_game_decides_the_rerun_banner_after_a_roster_save(tmp_path, scout, monkeypatch, other_tab):
    """Item 2 with the real server: after a Full re-analysis that failed after installing its run the game has
    its GPU results but no analysis, so the banner offers Re-run analysis and the server takes it (HEAD showed
    no banner); after a new film from another tab it has neither, so no banner (HEAD offered one, whose click
    the server refuses)."""
    client = scout.client
    game_id = _analysed_game(scout)
    if other_tab == "full-reanalysis-failed-after-install":
        _failing_once(monkeypatch, ErrorCode.ANALYSIS_FAILED)
        full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
        done = _run(scout, full)
        assert (done["status"], done["stage"]) == ("failed", "analyzing")
    loaded = _roster_bodies(scout, game_id)
    if other_tab == "new-film":
        _upload_film(client, game_id, auto_start=False)  # another tab, after the page loaded
    body = _roster_body(loaded, "scouted", fastscout={"3": "Test Player 3"})
    put = client.put(f"/api/games/{game_id}/rosters/scouted", json=body)  # what the page's save sends
    assert put.status_code == 200, put.text
    saved = {**_roster_bodies(scout, game_id), "put": put.json()}
    can_rerun = other_tab != "new-film"
    assert (saved["game"]["has_tracking"], saved["game"]["has_analysis"]) == (can_rerun, False)

    out = _real_page(
        tmp_path,
        game_id,
        {"loaded": loaded, "saved": saved},
        """
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
console.log(JSON.stringify({ banner, sent, navigatedTo: page.window.navigatedTo || null }));
""",
    )
    assert out["sent"][0] == ["PUT", "/api/games/g_1/rosters/scouted", body]
    assert out["banner"] is can_rerun
    rerun = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"})  # the banner's click, on the server
    if can_rerun:
        assert out["sent"][1:] == [["POST", "/api/games/g_1/jobs", {"kind": "reanalyze"}]]
        assert out["navigatedTo"] == "/games/g_1"
        assert rerun.status_code == 201, rerun.text
        assert _run(scout, rerun.json())["status"] == "succeeded"
        assert client.get(f"/api/games/{game_id}").json()["has_analysis"] is True
    else:
        assert (out["sent"][1:], out["navigatedTo"]) == ([], None)
        assert (rerun.status_code, rerun.json()["error"]["code"]) == (409, "ANALYSIS_NOT_READY")


def test_removing_players_on_the_real_server_sends_nothing_it_refuses(tmp_path, scout):
    """Items 4 and 5 with the real server. Another tab saved track HELD as North's #10; the coach chooses North's
    #3 for track CHOSEN and "Not a player" for IGNORED, then removes #3 and #10 from North's roster. CHOSEN's
    choice goes, with a notice (on HEAD it was sent after the roster save and the server refused it: 422);
    HELD shows #10 as removed until the save, then what the server kept: no assignment (the save removed it)."""
    client = scout.client
    game_id = _analysed_game(scout)
    held, chosen, ignored = [a for a in client.get(f"/api/games/{game_id}/tracks").json()["assignments"]
                             if a["role"] == "player" and a["side"]][:3]
    north = {p["jersey"]: p for p in client.get(f"/api/games/{game_id}/rosters").json()["other"]["players"]}
    fix = {"track_id": held["track_id"], "player_id": north["10"]["id"], "side": "other", "ignore": False}
    assert client.put(f"/api/games/{game_id}/tracks/{held['track_id']}", json=fix).status_code == 200
    loaded = _roster_bodies(scout, game_id)
    body = _roster_body(loaded, "other", without=("3", "10"))
    put = client.put(f"/api/games/{game_id}/rosters/other", json=body)  # what the page's save sends
    assert put.status_code == 200, put.text
    saved = {**_roster_bodies(scout, game_id), "put": put.json()}
    assert held["track_id"] not in [o["track_id"] for o in saved["tracks"]["overrides"]]  # the server removed it

    out = _real_page(
        tmp_path,
        game_id,
        {"loaded": loaded, "saved": saved},
        """
const loadedHeld = shown(ARGS.held);
choose(ARGS.chosen, `other:${ARGS.player}`);
choose(ARGS.ignored, "__ignore");
removeJersey("other", "3");
removeJersey("other", "10");
const removed = { held: shown(ARGS.held), chosen: shown(ARGS.chosen), unsaved: textOf(byId("tracks-unsaved")),
  dropped: textOf(byId("tracks-dropped")) };
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({ loadedHeld, removed, held: shown(ARGS.held), sent, navigatedTo: page.window.navigatedTo || null }));
""",
        held=held["track_id"],
        chosen=chosen["track_id"],
        ignored=ignored["track_id"],
        player=north["3"]["id"],
    )
    assert out["loadedHeld"] == "#10 Test Player 10"
    assert out["removed"] == {
        "held": "#10 Test Player 10 (removed, not saved yet)",
        "chosen": AUTOMATIC,
        "unsaved": "1 unsaved change",
        "dropped": f"Track choices droppedYour unsaved choice for track T{chosen['track_id']} was dropped: "
        "its player was removed from the roster.",
    }
    assert out["held"] == AUTOMATIC
    not_a_player = {"track_id": ignored["track_id"], "player_id": None, "side": ignored["side"], "ignore": True}
    assert out["sent"] == [
        ["PUT", "/api/games/g_1/rosters/other", body],
        ["PUT", f"/api/games/g_1/tracks/{ignored['track_id']}", not_a_player],
        ["POST", "/api/games/g_1/jobs", {"kind": "reanalyze"}],
    ]
    assert out["navigatedTo"] == "/games/g_1"
    assert _replay(client, game_id, out["sent"]) == [200, 200, 201]  # the real server takes all of it
