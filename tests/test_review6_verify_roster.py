"""Regression tests from the verification of the sixth review round: the Roster page.

They run the real Roster page in the node fake-DOM harness of ``tests/test_review_frontend.py`` on the fake
server of ``tests/test_review6_roster.py``. The seam tests feed the page the real server's bodies (the real
API and an in-process worker in demo mode) and replay what it sent on that server.

* A page that stops checking the film analysis says so where the coach can see it. With no table shown (the
  analysis after one that left no table, or a first analysis) the notice was put in the hidden tracks card.
* Save & re-run that stops after its own roster save dropped some choices (a row emptied) says what is left
  to do: the other choices are not saved yet. That hint goes once Save & re-run is clicked again.
* The notice of a choice dropped with its player said the player "is no longer on the roster", also once
  he was back (an undo path: a roster file that has him) and the table offered him again.
* Seams with the real server for the round's items: a wait chain (the analysis waited for is cancelled and
  started again) without choices, and with a choice when the next one is cancelled too; one player named by
  a choice and by a saved assignment, then removed; an analysis that failed after its install while the
  page waited, then a roster fix and Re-run analysis.
"""

from __future__ import annotations

import pytest

from scout.errors import ErrorCode
from tests.test_review4_frontend import WAIT_NOTICE
from tests.test_review4_integration import _failing_once
from tests.test_review5_integration import KEEP_TEAM, _numbered_again, _replay, _roster_bodies, _roster_tab
from tests.test_review5_verify_roster import _analysed_game, _run
from tests.test_review6_roster import (  # noqa: F401 - the scout fixture
    AUTOMATIC,
    DROPPED_T8,
    _page,
    _real_page,
    _roster_body,
    _titles,
    scout,
)

STOPPED = (
    "Stopped checking the film analysis"
    "The page could not find out whether the analysis has finished, so track assignments stay locked."
    "Reload the page to check again."
    "Reload the page"
)
WITHOUT_RESULTS = (
    "Film analysis finished without results"
    "A full analysis numbers the players' tracks again, so your unsaved track choices were dropped."
    "See the game page for what went wrong."
    "Open the game page"
)
CLICK_AGAIN = "Your other track choices are not saved yet: click Save & re-run analysis again."


# ---------------------------------------------------------------------------
# A page that stops checking the analysis says so, also with no table
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("before", ["one-that-left-no-table", "a-first-analysis"])
def test_a_page_that_stops_checking_the_analysis_says_so_where_the_table_was(tmp_path, before):
    """The page waits for C with no table shown: B before it failed after installing its run (round 6 now
    waits for the analysis another tab started meanwhile), or C is the game's first analysis. Then the page
    cannot find out how C is going. "Stopped checking the film analysis" went into the tracks card, which is
    hidden with no table, so nothing said the page had stopped: C's table would never come. It now shows
    where the table was, with its Reload the page button."""
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
const waiting = { notices: notices(), polled: server.log.includes("GET /api/jobs/j_c") };
route("GET", "/api/jobs/j_c", () => fail(500, "INTERNAL_ERROR", "Something went wrong")); // not retryable: it stops
await settle();
const stopped = { ...look(), table: !byId("tracks").hidden };
$$("button").filter(visible).find((b) => textOf(b) === "Reload the page")?.click();
console.log(JSON.stringify({ waiting, stopped, reloads }));
""",
        before=before,
    )
    first = before == "a-first-analysis"
    assert out["waiting"] == {"notices": [] if first else [WITHOUT_RESULTS], "polled": True}
    assert out["stopped"] == {
        "rows": [], "locked": [], "rerunLocked": True, "note": "", "saveDisabled": True, "changed": [],
        "notices": [STOPPED] if first else [WITHOUT_RESULTS, STOPPED], "table": False,
    }
    assert out["reloads"] == 1


# ---------------------------------------------------------------------------
# Save & re-run that stops after its roster save says what is left to do
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("others", [True, False], ids=["others-left", "none-left"])
def test_save_and_rerun_that_stops_after_its_roster_save_says_what_is_left_to_do(tmp_path, others):
    """The coach emptied Jones's row, chose Jones for track 8 and "Not a player" for track 9, and clicked Save
    & re-run. Its roster save left Jones out, so his choice went and the page stopped there, to show which
    track lost it: but nothing said that track 9's choice was not saved yet, while the banner at the top
    offered Re-run analysis, which runs without it. The notice now says to click Save & re-run analysis
    again (not when no choice is left: there is nothing more to save). Clicked again, the hint goes: here
    the choice is saved and the re-run refused (another one runs), so "not saved yet" would be wrong."""
    out = _page(
        tmp_path,
        """
await openPage(__RUN_A3__);
pickText(8, "#4 Jo Jones");
if (ARGS.others) pickText(9, "Not a player (referee, coach, fan…)");
for (const key of ["jersey", "first_name", "last_name"]) typeIn("other", 0, key, "");
byId("tracks-save").click();
await settle();
const stopped = { ...pending(), dropped: droppedNotice(), banner: !byId("rerun-banner").hidden, writes: writes() };
let again = null;
if (ARGS.others) {
  setJob({ id: "j_r", kind: "reanalyze", status: "running", stage: "analyzing", progress: 50 }); // another tab's re-run
  latest = "j_r";
  byId("tracks-save").click();
  await settle();
  again = { ...pending(), dropped: droppedNotice(), error: textOf($("#page-error .notice-title")), writes: writes() };
}
console.log(JSON.stringify({ stopped, again, trackPuts, navigatedTo: page.window.navigatedTo || null }));
""",
        others=others,
    )
    roster_put = ["PUT /api/games/g_1/rosters/other"]
    assert out["stopped"] == {
        "note": "1 unsaved change" if others else "",
        "saveDisabled": not others,
        "changed": [9] if others else [],
        "dropped": DROPPED_T8 + (CLICK_AGAIN if others else ""),
        "banner": True,
        "writes": roster_put,
    }
    if others:
        assert out["again"] == {
            "note": "", "saveDisabled": True, "changed": [], "dropped": DROPPED_T8, "error": "Conflict",
            "writes": [*roster_put, "PUT /api/games/g_1/tracks/9", "POST /api/games/g_1/jobs"],
        }
        assert out["trackPuts"] == [{"track_id": 9, "player_id": None, "side": "other", "ignore": True}]
    else:
        assert (out["again"], out["trackPuts"]) == (None, [])
    assert out["navigatedTo"] is None


# ---------------------------------------------------------------------------
# The notice of a choice dropped with its player stays true when he comes back
# ---------------------------------------------------------------------------


def test_the_notice_of_a_choice_dropped_with_its_player_stays_true_once_he_is_back(tmp_path):
    """Undo path: the coach removed Jones, so his choice for track 8 went, then imported a roster file that has
    him. The server, which still had him, keeps his id, and the table offers him again; beside it the notice
    said his choice went because he "is no longer on the roster". It now says he was removed from the
    roster, which stays true (the choice itself stays dropped, as tests/test_review6_roster.py checks)."""
    out = _page(
        tmp_path,
        """
route("POST", "/api/games/g_1/rosters/other/import", () => {
  rosters.other = [jones];
  return json({ roster: roster("other", rosters.other), imported: 1, skipped_rows: [], warnings: [],
    detected_columns: {} });
});
await openPage(__RUN_A3__);
pickText(8, "#4 Jo Jones");
removeRow("other", 0);
const removed = droppedNotice();
await importFile("other", "Jersey,First Name,Last Name\\n4,Jo,Jones\\n");
const offered = selectFor(8).options.map(textOf).includes("#4 Jo Jones");
console.log(JSON.stringify({ removed, back: droppedNotice(), offered, ...pending() }));
""",
    )
    said = "Track choices droppedYour unsaved choice for track T8 was dropped: its player was removed from the roster."
    assert out == {"removed": said, "back": said, "offered": True, "note": "", "saveDisabled": True, "changed": []}


# ---------------------------------------------------------------------------
# Seams: the real server's bodies
# ---------------------------------------------------------------------------


def test_the_real_servers_wait_chain_without_choices_keeps_the_table_locked_until_the_new_run(
    tmp_path, scout  # noqa: F811
):
    """The Roster page opens while another tab's Full re-analysis B waits in the queue; that tab cancels it
    and clicks Start again (C) before the next poll. The table stays locked while C runs (on HEAD it
    unlocked when B ended), then shows C's tracks, numbered again, with nothing sent and nothing to say:
    no choice was pending."""
    client = scout.client
    game_id = _analysed_game(scout)
    first = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()  # another tab
    loaded = _roster_bodies(scout, game_id)
    assert client.post(f"/api/jobs/{first['id']}/cancel").json()["status"] == "cancelled"
    again = client.post(f"/api/jobs/{first['id']}/retry")  # Start again
    assert again.status_code == 200, again.text
    second = again.json()
    switched = _roster_bodies(scout, game_id)
    assert _run(scout, second)["status"] == "succeeded"
    after = _roster_bodies(scout, game_id)
    assert _numbered_again(loaded, after)

    out = _roster_tab(
        tmp_path, game_id, {"loaded": loaded, "switched": switched, "after": after}, [],
        [["switched", "switched", None], ["ended", "after", None]],
    )
    looks = out["looks"]
    for name in ("loaded", "switched"):
        look = looks[name]
        assert (look["locked"], look["saveDisabled"], look["unsaved"]) == (True, True, ""), name
        assert _titles(look["notices"]) == [WAIT_NOTICE], name
    assert looks["switched"]["requests"] == [
        f"GET /api/jobs/{first['id']}", "GET /api/games/g_1", f"GET /api/jobs/{second['id']}",
        "GET /api/games/g_1/tracks", f"GET /api/jobs/{second['id']}",
    ]
    ended = looks["ended"]
    assert ended["requests"] == [f"GET /api/jobs/{second['id']}", "GET /api/games/g_1", "GET /api/games/g_1/tracks"]
    assert ended["rows"] == sorted(a["track_id"] for a in after["tracks"]["assignments"])
    assert (ended["locked"], ended["unsaved"], ended["chosen"], ended["notices"]) == (False, "", [], [])
    assert (out["sent"], out["navigatedTo"]) == ([], None)


def test_the_real_servers_wait_chain_whose_next_analysis_is_cancelled_saves_the_choice(tmp_path, scout):  # noqa: F811
    """The page waits, locked, for B (its save was refused); another tab cancels B, clicks Start again (C),
    and cancels C too before its install. B and C kept the tracks the coach saw, so the choice stays, the
    table unlocks only when C has ended (on HEAD when B had), and Save & re-run sends the choice and the
    re-run, which the server takes."""
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
    second = client.post(f"/api/jobs/{first['id']}/retry").json()  # Start again
    switched = _roster_bodies(scout, game_id, client.put(path, json=body).json())
    assert client.post(f"/api/jobs/{second['id']}/cancel").json()["status"] == "cancelled"
    after = _roster_bodies(scout, game_id)
    assert not _numbered_again(loaded, after)

    out = _roster_tab(
        tmp_path, game_id, {"loaded": loaded, "atSave": at_save, "switched": switched, "after": after},
        [[keep["track_id"], KEEP_TEAM]],
        [["saved", "atSave", "tracks-save"], ["switched", "switched", None], ["ended", "after", None],
         ["savedAgain", "after", "tracks-save"]],
    )
    looks = out["looks"]
    waiting = looks["switched"]
    assert (waiting["locked"], waiting["saveDisabled"], waiting["unsaved"], waiting["chosen"]) == (
        True, True, "1 unsaved change", [keep["track_id"]])
    assert _titles(waiting["notices"]) == [WAIT_NOTICE]
    ended = looks["ended"]
    assert (ended["locked"], ended["saveDisabled"], ended["unsaved"], ended["notices"]) == (
        False, False, "1 unsaved change", [])
    assert looks["savedAgain"]["requests"] == [
        "GET /api/games/g_1/tracks", f"PUT /api/games/g_1/tracks/{keep['track_id']}", "POST /api/games/g_1/jobs"]
    refused_put, *sent = out["sent"]
    assert refused_put == ["PUT", f"/api/games/g_1/tracks/{keep['track_id']}", body]  # refused (409) at the time
    assert sent == [refused_put, ["POST", "/api/games/g_1/jobs", {"kind": "reanalyze"}]]
    assert out["navigatedTo"] == "/games/g_1"
    assert _replay(client, game_id, sent) == [200, 201]


def test_the_real_servers_bodies_when_one_player_named_by_a_choice_and_an_assignment_is_removed(
    tmp_path, scout  # noqa: F811
):
    """Track HELD is saved as North's #10 (another tab); the coach chooses #10 for CHOSEN too, and "Not a
    player" for IGNORED, then removes #10 from North's roster and clicks Save & re-run. CHOSEN's choice goes
    at once, with the notice; HELD shows #10 as removed until the roster save, which removes that assignment
    on the server; then only IGNORED's choice and the re-run are sent, and the server takes them (on HEAD
    CHOSEN's choice was sent after the roster save: 422)."""
    client = scout.client
    game_id = _analysed_game(scout)
    held, chosen, ignored = [a for a in client.get(f"/api/games/{game_id}/tracks").json()["assignments"]
                             if a["role"] == "player" and a["side"]][:3]
    north = {p["jersey"]: p for p in client.get(f"/api/games/{game_id}/rosters").json()["other"]["players"]}
    fix = {"track_id": held["track_id"], "player_id": north["10"]["id"], "side": "other", "ignore": False}
    assert client.put(f"/api/games/{game_id}/tracks/{held['track_id']}", json=fix).status_code == 200
    loaded = _roster_bodies(scout, game_id)
    body = _roster_body(loaded, "other", without=("10",))
    put = client.put(f"/api/games/{game_id}/rosters/other", json=body)  # what the page's save sends
    assert put.status_code == 200, put.text
    saved = {**_roster_bodies(scout, game_id), "put": put.json()}
    assert held["track_id"] not in [o["track_id"] for o in saved["tracks"]["overrides"]]  # the server removed it

    out = _real_page(
        tmp_path,
        game_id,
        {"loaded": loaded, "saved": saved},
        """
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
choose(ARGS.chosen, `other:${ARGS.player}`);
choose(ARGS.ignored, "__ignore");
removeJersey("other", "10");
const removed = { held: shown(ARGS.held), chosen: shown(ARGS.chosen), unsaved: textOf(byId("tracks-unsaved")),
  notices: $$(".notice").filter(visible).map(textOf) };
const logged = server.log.length;
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({ removed, held: shown(ARGS.held), requests: server.log.slice(logged), sent,
  navigatedTo: page.window.navigatedTo || null }));
""",
        held=held["track_id"],
        chosen=chosen["track_id"],
        ignored=ignored["track_id"],
        player=north["10"]["id"],
    )
    assert out["removed"] == {
        "held": "#10 Test Player 10 (removed, not saved yet)",
        "chosen": AUTOMATIC,
        "unsaved": "1 unsaved change",
        "notices": [f"Track choices droppedYour unsaved choice for track T{chosen['track_id']} was dropped: "
                    "its player was removed from the roster."],
    }
    assert out["held"] == AUTOMATIC
    assert out["requests"] == [
        "PUT /api/games/g_1/rosters/other", "GET /api/games/g_1", "GET /api/games/g_1/tracks",  # the save, read again
        "GET /api/games/g_1/tracks", f"PUT /api/games/g_1/tracks/{ignored['track_id']}", "POST /api/games/g_1/jobs",
    ]
    not_a_player = {"track_id": ignored["track_id"], "player_id": None, "side": ignored["side"], "ignore": True}
    roster_put, *sent = out["sent"]
    assert roster_put == ["PUT", "/api/games/g_1/rosters/other", body]  # applied above
    assert sent == [["PUT", f"/api/games/g_1/tracks/{ignored['track_id']}", not_a_player],
                    ["POST", "/api/games/g_1/jobs", {"kind": "reanalyze"}]]
    assert out["navigatedTo"] == "/games/g_1"
    assert _replay(client, game_id, sent) == [200, 201]


def test_the_real_servers_bodies_when_the_analysis_waited_for_fails_after_its_install_then_a_roster_fix(
    tmp_path, scout, monkeypatch  # noqa: F811
):
    """The page waits for another tab's Full re-analysis (its save was refused), which fails after installing
    its new run: no table, the choice dropped, a notice where the table was. The coach then fixes the roster:
    the game has its GPU results, so the banner offers Re-run analysis (on HEAD it followed has_analysis,
    false here, and offered nothing), and the server takes the re-run."""
    client = scout.client
    game_id = _analysed_game(scout)
    loaded = _roster_bodies(scout, game_id)
    keep = next(a for a in loaded["tracks"]["assignments"] if a["role"] == "player" and a["side"])
    body = {"track_id": keep["track_id"], "player_id": None, "side": keep["side"], "ignore": False}
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()  # another tab
    refused = client.put(f"/api/games/{game_id}/tracks/{keep['track_id']}", json=body)
    assert refused.status_code == 409, refused.text
    at_save = _roster_bodies(scout, game_id, refused.json())
    _failing_once(monkeypatch, ErrorCode.ANALYSIS_FAILED)
    done = _run(scout, full)
    assert (done["status"], done["stage"]) == ("failed", "analyzing")
    after = _roster_bodies(scout, game_id)
    assert (after["game"]["has_analysis"], after["game"]["has_tracking"], after["tracks"]["assignments"]) == (
        False, True, [])
    roster = _roster_body(after, "scouted", fastscout={"3": "Test Player 3"})
    put = client.put(f"/api/games/{game_id}/rosters/scouted", json=roster)  # what the page's save sends
    assert put.status_code == 200, put.text
    fixed = {**_roster_bodies(scout, game_id), "put": put.json()}

    out = _real_page(
        tmp_path,
        game_id,
        {"loaded": loaded, "atSave": at_save, "after": after, "saved": fixed},
        """
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const look = () => ({ table: !byId("tracks").hidden,
  locked: $$("#tracks-body select[data-track]").some((s) => s.disabled),
  rerun: [!byId("rerun-banner").hidden, byId("rerun-btn").disabled], unsaved: textOf(byId("tracks-unsaved")),
  notices: $$(".notice").filter(visible).map(textOf) });
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {
  sent.push(["PUT", req.path, req.body]);
  return now().refusal ? json(now().refusal, 409) : json(req.body);
});
choose(ARGS.keep, "__none");
phase = "atSave";
byId("tracks-save").click();
await settle();
const waiting = look();
phase = "after";
await settle();
const ended = look();
const name = editor("scouted").querySelector(`input[data-i="${rowOf("scouted", "3")}"][data-key="fastscout_name"]`);
name.value = "Test Player 3";
fire(name, "input");
editor("scouted").querySelectorAll("button").find((b) => textOf(b) === "Save roster").click();
await settle();
const fixedLook = look();
byId("rerun-btn").click();
await settle();
console.log(JSON.stringify({ waiting, ended, fixed: fixedLook, sent, navigatedTo: page.window.navigatedTo || null }));
""",
        keep=keep["track_id"],
    )
    assert out["waiting"]["locked"] is True
    assert out["waiting"]["rerun"] == [False, True]
    assert _titles(out["waiting"]["notices"]) == [WAIT_NOTICE, "Conflict"]
    assert out["ended"] == {"table": False, "locked": False, "rerun": [False, False], "unsaved": "",
                            "notices": [WITHOUT_RESULTS]}
    assert out["fixed"] == {"table": False, "locked": False, "rerun": [True, False], "unsaved": "",
                            "notices": [out["fixed"]["notices"][0], WITHOUT_RESULTS]}
    assert out["fixed"]["notices"][0].startswith("Roster saved")
    refused_put, *sent = out["sent"]
    assert refused_put == ["PUT", f"/api/games/g_1/tracks/{keep['track_id']}", body]  # refused (409) at the time
    assert sent == [
        ["PUT", "/api/games/g_1/rosters/scouted", roster], ["POST", "/api/games/g_1/jobs", {"kind": "reanalyze"}]]
    assert out["navigatedTo"] == "/games/g_1"
    rerun = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"})  # the banner's click, on the server
    assert rerun.status_code == 201, rerun.text
    assert _run(scout, rerun.json())["status"] == "succeeded"
    assert client.get(f"/api/games/{game_id}").json()["has_analysis"] is True
