"""Regression tests from the verification of the fifth review round: the Roster page.

They run the real Roster page in the node fake-DOM harness of ``tests/test_review_frontend.py``
with the routes of ``tests/test_review3_frontend.py``, ``tests/test_review4_frontend.py`` and
``tests/test_review5_roster.py``. The seam tests take their answers from the real API and an
in-process worker (demo mode), so the page meets the server's own tracks, jobs and refusals for
what another tab may have done between page load and Save & re-run.

docs/ARCHITECTURE.md (Extra rules, Full re-analysis): "a Roster page opened before the Full
re-analysis started reads the tracks again before it saves, and shows the new table instead of
saving when they were numbered again".
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from scout import config
from scout.analysis import pipeline
from scout.errors import ErrorCode
from scout.main import create_app
from scout.processing import mock
from scout.worker import Worker
from tests.test_review3_frontend import ROSTER_TRACKS_JS, SMITH_TRACK_JS
from tests.test_review3_integration import _upload_film
from tests.test_review4_frontend import WAIT_NOTICE
from tests.test_review4_verify_frontend import _failing, _for_page
from tests.test_review5_roster import PAGE_JS, _says_tracks_were_numbered_again
from tests.test_review_frontend import run_page

AUTOMATIC = "Automatic (best jersey match)"
FINISHED = "Film analysis finished"

# Run A, the tracks the page loads; run B, another tab's Full re-analysis since (the same numbers are
# other tracks: other samples, teams and reads).
RUN_A_JS = (
    f'{{ assignments: [{SMITH_TRACK_JS}, assignment({{ track_id: 8, team_id: 1, side: "other" }})], overrides: [] }}'
)
RUN_B_JS = """{ assignments: [
  assignment({ track_id: 7, team_id: 1, side: "other", frames: 120, best_read: "4", votes: { 4: 2 },
    method: "unrostered" }),
  assignment({ track_id: 8, frames: 450 }),
  assignment({ track_id: 9, team_id: 1, side: "other", frames: 80 }),
], overrides: [] }"""


# ---------------------------------------------------------------------------
# A wait for another full analysis does not carry the choices over to tracks numbered again before it
# ---------------------------------------------------------------------------


def test_choices_found_stale_at_save_go_when_the_next_full_analysis_is_cancelled(tmp_path):
    """Save & re-run found the tracks numbered again (run B, another tab) while a second Full re-analysis
    (C) was queued, so it waited for C. C was cancelled before its install, so B stayed: the page loaded
    B's table and kept the choices made for run A on B's tracks with those numbers (other players), and
    the next Save & re-run, finding B's tracks the same as the table, sent them."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + f"""
await openPage({RUN_A_JS});
pickText(7, "Unknown player (Lincoln)");
tracks = {RUN_B_JS};
latest = job({{ id: "j_3", kind: "analyze", status: "queued", stage: "queued" }});
byId("tracks-save").click();
await settle();
const waiting = {{ writes: writes(), wait: textOf(byId("tracks-wait")), ...pending() }};
latest = job({{ id: "j_3", kind: "analyze", status: "cancelled", stage: "queued" }});
await settle();
const after = {{ rows: trackRows(), shown: trackRows().map((id) => shown(id)), ...pending(), notices: notices() }};
pickText(8, "Unknown player (Lincoln)"); // a choice made on the new table goes, and only it
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ waiting, after, trackPuts, writes: writes(),
  navigatedTo: page.window.navigatedTo || null }}));
""",
    )
    waiting = out["waiting"]
    assert waiting.pop("wait").startswith(WAIT_NOTICE)
    assert waiting == {"writes": [], "note": "1 unsaved change", "saveDisabled": True, "changed": [7]}
    after = out["after"]
    assert after["rows"] == [8, 7, 9]  # run B's table
    assert after["shown"] == [AUTOMATIC] * 3
    assert (after["note"], after["saveDisabled"], after["changed"]) == ("", True, [])
    [shown] = after["notices"]
    assert _says_tracks_were_numbered_again(shown), shown
    assert shown.endswith("Make them again in the new table.")
    assert out["trackPuts"] == [{"track_id": 8, "player_id": None, "side": "other", "ignore": False}]
    assert out["writes"] == ["PUT /api/games/g_1/tracks/8", "POST /api/games/g_1/jobs"]
    assert out["navigatedTo"] == "/games/g_1"


def test_choices_kept_after_a_refused_rerun_go_when_the_tracks_reloaded_are_others(tmp_path):
    """The same through Re-run analysis: with choices not saved yet, the coach clicked Re-run analysis
    (after a roster save) while a second Full re-analysis was queued; it was refused (409) and the page
    waited. That analysis was cancelled, and the tracks it reloaded were another tab's run B: the choices
    made for run A stayed on B's tracks with those numbers, ready for Save & re-run."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + f"""
route("POST", "/api/games/g_1/jobs", () => (["queued", "running"].includes(latest.status)
  ? fail(409, "CONFLICT", "Conflict", {{ message: "This game's film is being analysed right now." }})
  : json(job({{ kind: "reanalyze" }}), 201)));
gameOver = {{ has_tracking: true }}; // its GPU results are on the server: the roster save offers Re-run analysis
await openPage({RUN_A_JS});
$$("#roster-columns section")[0].querySelectorAll("button").find((b) => textOf(b) === "Save roster").click();
await settle();
pickText(7, "Unknown player (Lincoln)");
tracks = {RUN_B_JS};
latest = job({{ id: "j_3", kind: "analyze", status: "queued", stage: "queued" }});
byId("rerun-btn").click();
await settle();
const refused = {{ error: textOf($("#page-error .notice-title")), wait: textOf(byId("tracks-wait")), ...pending() }};
latest = job({{ id: "j_3", kind: "analyze", status: "cancelled", stage: "queued" }});
await settle();
console.log(JSON.stringify({{ refused, rows: trackRows(), shown: shown(7), ...pending(), notices: notices(),
  writes: writes() }}));
""",
    )
    refused = out["refused"]
    assert refused.pop("wait").startswith(WAIT_NOTICE)
    assert refused == {"error": "Conflict", "note": "1 unsaved change", "saveDisabled": True, "changed": [7]}
    assert (out["rows"], out["shown"]) == ([8, 7, 9], AUTOMATIC)
    assert (out["note"], out["saveDisabled"], out["changed"]) == ("", True, [])
    banner, shown = out["notices"]
    assert banner.startswith("Roster saved")  # from the roster save before the Re-run analysis
    assert _says_tracks_were_numbered_again(shown), shown
    assert out["writes"] == ["PUT /api/games/g_1/rosters/scouted", "POST /api/games/g_1/jobs"]  # no track change


def test_comparison_ignores_what_a_reanalysis_or_an_override_changes(tmp_path):
    """Guard: between page load and save another tab changed every field the matching, the team colours,
    the rosters and the overrides set (player, jersey, team, role, how, ignored, match score) and the
    vote figures; the tracks themselves (ids, samples, team ids, best reads) are the same, so the save
    goes ahead."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + f"""
await openPage({{ assignments: [
  {SMITH_TRACK_JS},
  assignment({{ track_id: 8, team_id: 1, side: "other", best_read: "4", votes: {{ 4: 3 }}, player_id: "p_2",
    jersey: "4", match_score: 1, method: "exact" }}),
  assignment({{ track_id: 90, team_id: null, side: null, role: "referee", frames: 40 }}),
], overrides: [] }});
pickText(7, "Not a player (referee, coach, fan…)");
tracks = {{ assignments: [
  assignment({{ track_id: 7, side: "other", player_id: null, jersey: null, best_read: "23",
    votes: {{ 23: 2.9, 32: 0.1 }}, match_score: 0.4, method: "unrostered", ignored: false }}),
  assignment({{ track_id: 8, team_id: 1, side: "scouted", best_read: "4", votes: {{ 4: 3.2 }}, player_id: null,
    jersey: null, match_score: 1, method: "manual", ignored: true }}),
  assignment({{ track_id: 90, team_id: null, side: "other", role: "player", frames: 40, method: "manual" }}),
], overrides: [{{ track_id: 8, player_id: null, side: "scouted", ignore: true }},
  {{ track_id: 90, player_id: null, side: "other", ignore: false }}] }};
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ trackPuts, writes: writes(), notices: notices(),
  navigatedTo: page.window.navigatedTo || null }}));
""",
    )
    assert out["trackPuts"] == [{"track_id": 7, "player_id": None, "side": "scouted", "ignore": True}]
    assert out["writes"] == ["PUT /api/games/g_1/tracks/7", "POST /api/games/g_1/jobs"]
    assert out["notices"] == []
    assert out["navigatedTo"] == "/games/g_1"


def test_tracks_numbered_again_but_the_game_cannot_be_read_keeps_the_choices(tmp_path):
    """Guard: Save & re-run found other tracks, but the game (and so whether a full analysis still runs)
    could not be read: nothing is sent, the error shows, the choices stay and Save & re-run stays open;
    the next try, with the server answering, shows the new table instead."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + PAGE_JS
        + f"""
await openPage({RUN_A_JS});
pickText(7, "Unknown player (Lincoln)");
tracks = {RUN_B_JS};
route("GET", "/api/games/g_1", {{ network: true }});
byId("tracks-save").click();
await settle();
const failed = {{ writes: writes(), error: textOf($("#tracks-error .notice-title")), rows: trackRows(), shown: shown(7),
  ...pending(), notices: notices().length }};
route("GET", "/api/games/g_1", () => json(game({{ latest_job_id: latest.id }})));
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ failed, rows: trackRows(), ...pending(), notices: notices(), writes: writes() }}));
""",
    )
    assert out["failed"] == {
        "writes": [],
        "error": "Can't reach the server",
        "rows": [7, 8],
        "shown": "Unknown player (Lincoln)",
        "note": "1 unsaved change",
        "saveDisabled": False,
        "changed": [7],
        "notices": 1,  # the error
    }
    assert (out["rows"], out["note"], out["saveDisabled"], out["changed"]) == ([8, 7, 9], "", True, [])
    [shown] = out["notices"]
    assert _says_tracks_were_numbered_again(shown), shown
    assert out["writes"] == []


# ---------------------------------------------------------------------------
# Seams: what another tab did between page load and Save & re-run, as the real server answers
# ---------------------------------------------------------------------------


@pytest.fixture
def scout(monkeypatch, auth_headers):
    monkeypatch.setenv("SCOUT_MOCK_SECONDS", "0")
    monkeypatch.setattr(mock, "DEFAULT_DURATION_S", 240.0)  # a shorter demo game: the same flow, a quicker analysis
    config.reset_settings()
    with TestClient(create_app()) as client:
        client.headers.update(auth_headers)
        yield SimpleNamespace(client=client, worker=Worker(worker_id="w-review5-verify-roster"))


def _run(scout, job: dict) -> dict:
    assert scout.worker.run_once(timeout=2)
    return scout.client.get(f"/api/jobs/{job['id']}").json()


def _analysed_game(scout) -> str:
    """A game with placeholder rosters (no demo names), analysed once: run A."""
    client = scout.client
    game_id = client.post("/api/games", json={"scouted_team": "Central", "other_team": "North"}).json()["id"]
    players = [{"jersey": str(n), "first_name": "Test", "last_name": f"Player {n}"} for n in (3, 10, 23)]
    for side in ("scouted", "other"):
        assert client.put(f"/api/games/{game_id}/rosters/{side}", json={"players": players}).status_code == 200
    assert _run(scout, _upload_film(client, game_id, auto_start=True)["job"])["status"] == "succeeded"
    return game_id


def _bodies(scout, game_id: str, refusal: dict | None = None) -> dict:
    """What the Roster page reads now: the game, its tracks and any of its jobs (and the server's
    answer to a track change, when it refuses one)."""
    client = scout.client
    return {
        "game": client.get(f"/api/games/{game_id}").json(),
        "tracks": client.get(f"/api/games/{game_id}/tracks").json(),
        "jobs": {job["id"]: job for job in client.get(f"/api/games/{game_id}/jobs").json()},
        "refusal": refusal,
    }


def _tracking(assignment: dict) -> tuple:
    """What a track has from the GPU run alone."""
    return (assignment["track_id"], assignment["frames"], assignment["team_id"], assignment["best_read"])


def _two_players(tracks: dict) -> tuple[dict, dict]:
    """Two player tracks with a team: the coach's "keep team" and "Not a player"."""
    keep, ignored = [a for a in tracks["assignments"] if a["role"] == "player" and a["side"]][:2]
    return keep, ignored


# phases: the bodies at page load ("before"), when Save & re-run is clicked ("atSave") and, for a wait,
# once the analysis has ended ("after"). The coach picks "keep team" for KEEP and "Not a player" for
# IGNORED, saves, and with SAVE_AGAIN saves once more after the wait.
SEAM_JS = """
let phase = "before";
const now = () => phases[phase];
const sent = [];
const scrolled = [];
Element.prototype.scrollIntoView = function () { scrolled.push(this.id); };
route("GET", "/api/games/g_1", () => json(now().game));
route("GET", "/api/games/g_1/rosters", json(rosters));
route("GET", "/api/games/g_1/tracks", () => json(now().tracks));
route("GET", /^\\/api\\/jobs\\/[\\w-]+$/, (req) => {
  const body = now().jobs[req.path.split("/").pop()];
  return body ? json(body) : fail(404, "NOT_FOUND", "Not found");
});
// As the real server answers at that moment: its own 409 while an ANALYZE is queued or running.
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {
  sent.push(["PUT", req.body]);
  return now().refusal ? json(now().refusal, 409) : json(req.body);
});
route("DELETE", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {
  sent.push(["DELETE", req.path]);
  return { status: 204 };
});
route("POST", "/api/games/g_1/jobs", (req) => {
  sent.push(["POST", req.body]);
  return json(job({ kind: "reanalyze" }), 201);
});
await import("./js/roster.js");
await settle();
const choose = (id, value) => {
  const select = $(`#tracks-body select[data-track="${id}"]`);
  select.value = value;
  fire(select, "change");
};
choose(KEEP, "__none"); // Unknown player (keep team)
choose(IGNORED, "__ignore"); // Not a player (referee, coach, fan…)
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const look = () => ({
  rows: $$("#tracks-body tr[data-track]").map((tr) => Number(tr.dataset.track)).sort((a, b) => a - b),
  chosen: $$("#tracks-body select[data-track]").filter((s) => s.value !== "").map((s) => Number(s.dataset.track))
    .sort((a, b) => a - b),
  unsaved: textOf(byId("tracks-unsaved")),
  saveDisabled: byId("tracks-save").disabled,
  notices: $$(".notice").filter(visible).map(textOf),
  link: $$("a").filter(visible).find((a) => textOf(a) === "Open the game page")?.getAttribute("href") ?? null,
});
const loaded = look();
phase = "atSave";
const logged = server.log.length;
byId("tracks-save").click();
await settle();
const saved = { ...look(), requests: server.log.slice(logged).filter((entry, i, all) => entry !== all[i - 1]) };
let ended = null;
if (phases.after) {
  phase = "after";
  await settle();
  ended = look();
  if (SAVE_AGAIN) {
    byId("tracks-save").click();
    await settle();
  }
}
console.log(JSON.stringify({ loaded, saved, ended, sent, scrolled, navigatedTo: page.window.navigatedTo || null }));
"""


def _page_saves(tmp_path, game_id: str, phases: dict, rosters: dict, keep: int, ignored: int, *, save_again=False):
    return run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        f"""
const phases = {_for_page(phases, game_id)};
const rosters = {_for_page(rosters, game_id)};
const [KEEP, IGNORED, SAVE_AGAIN] = [{keep}, {ignored}, {str(save_again).lower()}];
"""
        + SEAM_JS,
    )


def _choices(keep: dict, ignored: dict) -> list[dict]:
    """The bodies the page sends for the coach's two choices: "keep team" keeps the team the table showed."""
    return [
        {"track_id": keep["track_id"], "player_id": None, "side": keep["side"], "ignore": False},
        {"track_id": ignored["track_id"], "player_id": None, "side": ignored["side"], "ignore": True},
    ]


@pytest.mark.parametrize("other_tab", ["full-reanalysis", "full-reanalysis-failed-after-install", "new-film"])
def test_tracks_numbered_again_or_gone_since_load_send_nothing(tmp_path, scout, monkeypatch, other_tab):
    """The real server's tracks after another tab's Full re-analysis (also one whose analysis failed after
    its install: no tracks at all), or after a new film: Save & re-run sends no track change and no re-run,
    reads only the tracks, the game and its latest job, and shows the new table (or none) with one notice."""
    client = scout.client
    game_id = _analysed_game(scout)
    before = _bodies(scout, game_id)
    rosters = client.get(f"/api/games/{game_id}/rosters").json()
    keep, ignored = _two_players(before["tracks"])
    if other_tab == "new-film":
        _upload_film(client, game_id, auto_start=False)
    else:
        if other_tab == "full-reanalysis-failed-after-install":
            _failing(monkeypatch, scout.worker, "analyze", ErrorCode.ANALYSIS_FAILED)
        full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
        status = "succeeded" if other_tab == "full-reanalysis" else "failed"
        assert _run(scout, full)["status"] == status
    at_save = _bodies(scout, game_id)
    new_tracks = sorted(a["track_id"] for a in at_save["tracks"]["assignments"])
    assert (at_save["game"]["has_analysis"], bool(new_tracks)) == ((other_tab == "full-reanalysis"),) * 2

    out = _page_saves(tmp_path, game_id, {"before": before, "atSave": at_save, "after": None}, rosters,
                      keep["track_id"], ignored["track_id"])
    chosen = sorted([keep["track_id"], ignored["track_id"]])
    assert (out["loaded"]["unsaved"], out["loaded"]["chosen"]) == ("2 unsaved changes", chosen)
    assert out["sent"] == []
    latest = at_save["game"]["latest_job_id"]
    assert out["saved"]["requests"] == ["GET /api/games/g_1/tracks", "GET /api/games/g_1", f"GET /api/jobs/{latest}"]
    saved = out["saved"]
    assert (saved["rows"], saved["chosen"], saved["unsaved"], saved["saveDisabled"]) == (new_tracks, [], "", True)
    [shown] = saved["notices"]
    assert _says_tracks_were_numbered_again(shown), shown
    if new_tracks:
        assert shown.endswith("Make them again in the new table.")
        assert out["scrolled"] == []
    else:
        assert "There are no tracks to assign now: see the game page." in shown
        assert saved["link"] == "/games/g_1"
        assert out["scrolled"] == ["tracks-gone"]  # the table, and the button clicked, went
    assert out["navigatedTo"] is None


@pytest.mark.parametrize("other_tab", ["full-reanalysis-cancelled-before-install", "reanalysis-with-other-fixes"])
def test_same_tracks_since_load_are_saved_onto_the_tracks_the_coach_saw(tmp_path, scout, other_tab):
    """A Full re-analysis cancelled before its install keeps the earlier run; a REANALYZE from another tab
    (with its own track fixes, the team colours swapped and a roster player added) keeps the track
    numbers while it changes the matches, teams, roles, how and ignored on many tracks. Either way the
    save goes ahead, and the real server puts the coach's choices on the tracks the table showed."""
    client = scout.client
    game_id = _analysed_game(scout)
    before = _bodies(scout, game_id)
    rosters = client.get(f"/api/games/{game_id}/rosters").json()
    keep, ignored = _two_players(before["tracks"])
    others = {}
    if other_tab == "full-reanalysis-cancelled-before-install":
        full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
        assert client.post(f"/api/jobs/{full['id']}/cancel").json()["status"] == "cancelled"
    else:
        tracks = before["tracks"]["assignments"]
        referee = next(a for a in tracks if a["role"] == "referee")
        free = [a for a in tracks if a["role"] == "player" and a["side"] and a not in (keep, ignored)]
        moved = free[0]
        assigned = min(free[1:], key=lambda a: a["match_score"])
        assert assigned["match_score"] < 1  # a track no roster player matched for sure
        north = next(
            p for p in rosters["other"]["players"]
            if p["id"] != assigned["player_id"] and p["jersey"] != assigned["jersey"]
        )
        fixes = [
            (ignored, north["id"], "other", False),
            (assigned, north["id"], "other", False),
            (moved, None, moved["side"], True),
            (referee, None, "scouted", False),
        ]
        others = {
            a["track_id"]: {"track_id": a["track_id"], "player_id": player_id, "side": side, "ignore": ignore}
            for a, player_id, side, ignore in fixes
        }
        for track_id, body in others.items():
            assert client.put(f"/api/games/{game_id}/tracks/{track_id}", json=body).status_code == 200
        game = client.get(f"/api/games/{game_id}").json()
        swapped = {team: "other" if side == "scouted" else "scouted" for team, side in game["team_id_map"].items()}
        team_map = swapped or {"0": "other", "1": "scouted"}
        assert client.patch(f"/api/games/{game_id}", json={"team_id_map": team_map}).status_code == 200
        added = [{"jersey": n, "first_name": "Test", "last_name": f"Player {n}"} for n in ("1", "2", "4", "5")]
        added = rosters["scouted"]["players"] + added
        assert client.put(f"/api/games/{game_id}/rosters/scouted", json={"players": added}).status_code == 200
        rerun = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json()
        assert _run(scout, rerun)["status"] == "succeeded"
    at_save = _bodies(scout, game_id)
    old = {a["track_id"]: a for a in before["tracks"]["assignments"]}
    new = {a["track_id"]: a for a in at_save["tracks"]["assignments"]}
    assert {i: _tracking(a) for i, a in new.items()} == {i: _tracking(a) for i, a in old.items()}
    assert {i: a["votes"] for i, a in new.items()} == {i: a["votes"] for i, a in old.items()}
    if others:  # the other tab's run changed what the table shows: matches, teams, roles, how, ignored
        changed = {field: [i for i in old if new[i][field] != old[i][field]]
                   for field in ("player_id", "jersey", "side", "role", "method", "ignored", "match_score")}
        assert all(changed.values()), changed
        assert assigned["track_id"] in set(changed["player_id"]) & set(changed["jersey"]) & set(changed["match_score"])

    out = _page_saves(tmp_path, game_id, {"before": before, "atSave": at_save, "after": None}, rosters,
                      keep["track_id"], ignored["track_id"])
    choices = _choices(keep, ignored)
    assert out["sent"] == [["PUT", choices[0]], ["PUT", choices[1]], ["POST", {"kind": "reanalyze"}]]
    assert out["saved"]["requests"] == [
        "GET /api/games/g_1/tracks",
        f"PUT /api/games/g_1/tracks/{keep['track_id']}",
        f"PUT /api/games/g_1/tracks/{ignored['track_id']}",
        "POST /api/games/g_1/jobs",
    ]
    assert out["saved"]["notices"] == []
    assert out["navigatedTo"] == "/games/g_1"

    for body in choices:  # what the page sent, to the real server, and the re-run it asked for
        assert client.put(f"/api/games/{game_id}/tracks/{body['track_id']}", json=body).status_code == 200
    rerun = client.post(f"/api/games/{game_id}/jobs", json={"kind": "reanalyze"}).json()
    assert _run(scout, rerun)["status"] == "succeeded"
    final = {a["track_id"]: a for a in client.get(f"/api/games/{game_id}/tracks").json()["assignments"]}
    for chosen, body in zip((keep, ignored), choices, strict=True):
        landed = final[chosen["track_id"]]
        assert _tracking(landed) == _tracking(chosen)  # the track the coach saw
        expected = (body["side"], None, body["ignore"], "manual")
        assert (landed["side"], landed["player_id"], landed["ignored"], landed["method"]) == expected
    overrides = {o["track_id"]: o for o in client.get(f"/api/games/{game_id}/tracks").json()["overrides"]}
    for track_id, body in others.items():  # the other tab's fixes stay, but where the coach chose again
        assert overrides[track_id] == (choices[1] if track_id == ignored["track_id"] else body)


@pytest.mark.parametrize("ends", ["succeeded", "cancelled"])
def test_full_analysis_queued_at_save_refuses_the_change_and_waits(tmp_path, scout, ends):
    """The existing wait path with the real server: a Full re-analysis queued since load leaves the tracks
    as they were, so the page sends the change, the server refuses it (409) and the page waits. When the
    analysis numbered the tracks again the choices go with a notice by the new table; when it was
    cancelled before its install the tracks stay, the choices too, and the next save sends them."""
    client = scout.client
    game_id = _analysed_game(scout)
    before = _bodies(scout, game_id)
    rosters = client.get(f"/api/games/{game_id}/rosters").json()
    keep, ignored = _two_players(before["tracks"])
    choices = _choices(keep, ignored)
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    refused = client.put(f"/api/games/{game_id}/tracks/{keep['track_id']}", json=choices[0])
    assert refused.status_code == 409, refused.text
    at_save = _bodies(scout, game_id, refused.json())
    if ends == "succeeded":
        assert _run(scout, full)["status"] == "succeeded"
    else:
        assert client.post(f"/api/jobs/{full['id']}/cancel").json()["status"] == "cancelled"
    after = _bodies(scout, game_id)

    out = _page_saves(tmp_path, game_id, {"before": before, "atSave": at_save, "after": after}, rosters,
                      keep["track_id"], ignored["track_id"], save_again=True)
    saved = out["saved"]
    assert saved["requests"][:2] == ["GET /api/games/g_1/tracks", f"PUT /api/games/g_1/tracks/{keep['track_id']}"]
    waiting, error = saved["notices"]
    assert waiting.startswith(WAIT_NOTICE)
    assert error == "".join(refused.json()["error"][k] for k in ("title", "message", "hint"))  # the server's 409
    assert (saved["unsaved"], saved["saveDisabled"]) == ("2 unsaved changes", True)
    ended = out["ended"]
    if ends == "succeeded":
        assert ended["rows"] == sorted(a["track_id"] for a in after["tracks"]["assignments"])
        assert (ended["chosen"], ended["unsaved"], ended["saveDisabled"]) == ([], "", True)
        [shown] = ended["notices"]
        assert shown.startswith(FINISHED) and "your unsaved track choices were dropped" in shown, shown
        assert out["sent"] == [["PUT", choices[0]]]  # refused; nothing after the wait
        assert out["navigatedTo"] is None
    else:
        assert ended["rows"] == sorted(a["track_id"] for a in before["tracks"]["assignments"])
        assert (ended["chosen"], ended["unsaved"], ended["saveDisabled"]) == (
            sorted([keep["track_id"], ignored["track_id"]]), "2 unsaved changes", False)
        assert ended["notices"] == []
        refused_put = ["PUT", choices[0]]
        assert out["sent"] == [refused_put, refused_put, ["PUT", choices[1]], ["POST", {"kind": "reanalyze"}]]
        assert out["navigatedTo"] == "/games/g_1"


def test_full_analysis_analysing_its_new_run_at_save_waits_and_drops_the_choices(tmp_path, scout, monkeypatch):
    """Another tab's Full re-analysis has installed its run and is analysing it when the coach saves: the
    real server shows no tracks (the earlier analysis is gone) and no ANALYZE has ended, so the page sends
    nothing and waits; when the analysis is saved the new table comes and the choices are gone."""
    client = scout.client
    game_id = _analysed_game(scout)
    before = _bodies(scout, game_id)
    rosters = client.get(f"/api/games/{game_id}/rosters").json()
    keep, ignored = _two_players(before["tracks"])
    analyze = pipeline.analyze_game
    seen = {}

    def analyze_game(*args, **kwargs):
        seen["atSave"] = _bodies(scout, game_id)  # the coach clicks Save & re-run now
        return analyze(*args, **kwargs)

    monkeypatch.setattr(pipeline, "analyze_game", analyze_game)
    full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    assert _run(scout, full)["status"] == "succeeded"
    at_save, after = seen["atSave"], _bodies(scout, game_id)
    assert (at_save["jobs"][full["id"]]["stage"], at_save["tracks"]["assignments"]) == ("analyzing", [])

    out = _page_saves(tmp_path, game_id, {"before": before, "atSave": at_save, "after": after}, rosters,
                      keep["track_id"], ignored["track_id"])
    saved = out["saved"]
    assert saved["requests"][:3] == ["GET /api/games/g_1/tracks", "GET /api/games/g_1", f"GET /api/jobs/{full['id']}"]
    run_a = sorted(a["track_id"] for a in before["tracks"]["assignments"])
    assert (saved["rows"], saved["unsaved"], saved["saveDisabled"]) == (run_a, "2 unsaved changes", True)
    [waiting] = saved["notices"]
    assert waiting.startswith(WAIT_NOTICE)
    ended = out["ended"]
    assert ended["rows"] == sorted(a["track_id"] for a in after["tracks"]["assignments"])
    assert (ended["chosen"], ended["unsaved"], ended["saveDisabled"]) == ([], "", True)
    [shown] = ended["notices"]
    assert shown.startswith(FINISHED) and "your unsaved track choices were dropped" in shown, shown
    assert out["sent"] == []


@pytest.mark.parametrize("ends", ["cancelled", "gpu-failed"])
def test_second_full_analysis_that_keeps_the_first_ones_tracks_drops_the_choices(tmp_path, scout, monkeypatch, ends):
    """The real server's bodies for the case above: another tab's Full re-analysis (B) numbered the tracks
    again, then a second one (C) was queued when the coach saved, so the page waited. C ended without
    installing (cancelled, or failed on the GPU), so B's tracks stay, and the choices made for the
    earlier run must not land on them."""
    client = scout.client
    game_id = _analysed_game(scout)
    before = _bodies(scout, game_id)
    rosters = client.get(f"/api/games/{game_id}/rosters").json()
    first_full = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    assert _run(scout, first_full)["status"] == "succeeded"
    run_b = {a["track_id"]: a for a in client.get(f"/api/games/{game_id}/tracks").json()["assignments"]}
    in_both = [a for a in before["tracks"]["assignments"] if a["track_id"] in run_b]
    # Tracks B numbered again first: two demo seeds can give a starter's track the same samples, team and read.
    in_both.sort(key=lambda a: _tracking(a) == _tracking(run_b[a["track_id"]]))
    keep, ignored = _two_players({"assignments": in_both})
    assert [_tracking(keep), _tracking(ignored)] != [_tracking(run_b[a["track_id"]]) for a in (keep, ignored)]
    second = client.post(f"/api/games/{game_id}/jobs", json={"kind": "analyze"}).json()
    at_save = _bodies(scout, game_id)
    if ends == "cancelled":
        assert client.post(f"/api/jobs/{second['id']}/cancel").json()["status"] == "cancelled"
    else:
        _failing(monkeypatch, scout.worker, "poll", ErrorCode.PIPELINE_FAILED)
        assert _run(scout, second)["status"] == "failed"
    after = _bodies(scout, game_id)
    assert after["tracks"] == at_save["tracks"] and after["game"]["has_analysis"]  # B's tracks stay

    out = _page_saves(tmp_path, game_id, {"before": before, "atSave": at_save, "after": after}, rosters,
                      keep["track_id"], ignored["track_id"], save_again=True)
    assert out["saved"]["notices"][0].startswith(WAIT_NOTICE)
    ended = out["ended"]
    assert (ended["rows"], ended["chosen"], ended["unsaved"], ended["saveDisabled"]) == (sorted(run_b), [], "", True)
    [shown] = ended["notices"]
    assert _says_tracks_were_numbered_again(shown), shown
    assert out["sent"] == []
    assert out["navigatedTo"] is None
