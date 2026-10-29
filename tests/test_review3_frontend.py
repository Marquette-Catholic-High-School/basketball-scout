"""Regression tests from the third frontend review round.

They reuse the node fake-DOM harness of ``tests/test_review_frontend.py``: the real page
scripts run against the real HTML, ``fetch`` is answered by fake routes, and timers are
shortened to 1 ms.
"""

from __future__ import annotations

from tests.test_review_frontend import run_page

# The Roster page of an analysed game: Central has #23 Smith, Lincoln #4 Jones. ``load()``
# answers GET /tracks with the given assignments and overrides, then boots the page.
ROSTER_TRACKS_JS = """
route("GET", "/api/games/g_1", json(game()));
const roster = (side, players) => ({ game_id: "g_1", side, team_name: side === "scouted" ? "Central" : "Lincoln", players });
const smith = { id: "p_1", jersey: "23", first_name: "Sam", last_name: "Smith" };
const jones = { id: "p_2", jersey: "4", first_name: "Jo", last_name: "Jones" };
route("GET", "/api/games/g_1/rosters", json({ scouted: roster("scouted", [smith]), other: roster("other", [jones]) }));
route("PUT", /^\\/api\\/games\\/g_1\\/rosters\\/\\w+$/, (req) => json(roster(req.path.split("/").pop(), req.body.players)));
const assignment = (over) => ({ team_id: 0, side: "scouted", role: "player", player_id: null, jersey: null,
  best_read: null, votes: {}, match_score: 0, method: "none", frames: 300, ignored: false, ...over });
const trackPuts = [];
route("PUT", /^\\/api\\/games\\/g_1\\/tracks\\/\\d+$/, (req) => {
  trackPuts.push(req.body);
  return json({ track_id: Number(req.path.split("/").pop()), player_id: null, side: null, ignore: false, ...req.body });
});
route("POST", "/api/games/g_1/jobs", json(job({ kind: "reanalyze" }), 201));
async function load(assignments, overrides = []) {
  route("GET", "/api/games/g_1/tracks", json({ assignments, overrides }));
  await import("./js/roster.js");
  await settle();
}
const selectFor = (id) => $(`#tracks-body select[data-track="${id}"]`);
const rowFor = (id) => $(`#tracks-body tr[data-track="${id}"]`);
/** The text of the choice a track's select shows. */
const shown = (id) => textOf(selectFor(id).options.find((o) => o.value === selectFor(id).value));
/** Choose the option with this text, as the coach would; false when there is none. */
const pickText = (id, text) => {
  const select = selectFor(id);
  const option = select.options.find((o) => textOf(o) === text);
  if (!option) return false;
  select.value = option.value;
  fire(select, "change");
  return true;
};
/** A track row's cells: Team, Seen, Best read, Jersey readings, Matched player, Match, How. */
const cells = (id) => rowFor(id).querySelectorAll("td").slice(0, 7).map(textOf);
const pending = () => ({ note: textOf(byId("tracks-unsaved")), saveDisabled: byId("tracks-save").disabled,
  changed: $$("#tracks-body tr.changed").map((tr) => Number(tr.dataset.track)) });
const showTracks = (filter) => {
  byId("tracks-filter").value = filter;
  fire(byId("tracks-filter"), "change");
  return $$("#tracks-body tr[data-track]").map((tr) => Number(tr.dataset.track));
};
"""

# Track 7, matched to #23 Smith by its reads, or by the coach.
SMITH_TRACK_JS = (
    'assignment({ track_id: 7, player_id: "p_1", jersey: "23", best_read: "23", votes: { 23: 3 }, match_score: 1, '
    'method: "exact" })'
)
SMITH_SET_BY_COACH_JS = SMITH_TRACK_JS.replace('"exact"', '"manual"')


# ---------------------------------------------------------------------------
# 7. Unknown player of a chosen team
# ---------------------------------------------------------------------------


def test_referee_track_can_be_made_an_unknown_player_of_the_scouted_team(tmp_path):
    """ARCHITECTURE (assign_tracks): any override but ignore makes a track a player, also a
    referee, with the side the override names. The only unknown choice was "Unknown player
    (keep team)", which sent the track's own side: a referee has none, so the coach could
    not say which team the track plays for."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + f"""
await load([{SMITH_TRACK_JS}, assignment({{ track_id: 90, team_id: null, side: null, role: "referee" }})]);
const groups = selectFor(90).querySelectorAll("optgroup").map((g) => [g.getAttribute("label"), textOf(g.querySelector("option"))]);
const picked = pickText(90, "Unknown player (Central)");
const before = {{ shown: shown(90), ...pending() }};
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{ groups, picked, before, trackPuts, navigatedTo: page.window.navigatedTo || null }}));
""",
    )
    # Each team's group starts with its unknown player.
    assert out["groups"] == [["Central", "Unknown player (Central)"], ["Lincoln", "Unknown player (Lincoln)"]]
    assert out["picked"] is True
    assert out["before"] == {
        "shown": "Unknown player (Central)",
        "note": "1 unsaved change",
        "saveDisabled": False,
        "changed": [90],
    }
    assert out["trackPuts"] == [{"track_id": 90, "player_id": None, "side": "scouted", "ignore": False}]
    assert out["navigatedTo"] == "/games/g_1"


def test_saved_unknown_player_of_a_team_shows_as_that_choice(tmp_path):
    """A saved {player_id: null, side: "other"} came back as "Unknown player (keep team)"; a
    null-player override shows as that team's unknown player, and with no side as "keep
    team", and choosing the same again is no change."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + """
await load(
  [assignment({ track_id: 7, team_id: 1, side: "other", method: "manual" }), assignment({ track_id: 8, method: "manual" })],
  [{ track_id: 7, player_id: null, side: "other", ignore: false }, { track_id: 8, player_id: null, side: null, ignore: false }],
);
const loaded = { 7: shown(7), 8: shown(8), ...pending() };
for (const id of [7, 8]) fire(selectFor(id), "change"); // the same choice again
const again = pending();
pickText(7, "Unknown player (Central)");
const otherTeam = pending();
console.log(JSON.stringify({ loaded, again, otherTeam }));
""",
    )
    assert out["loaded"] == {
        "7": "Unknown player (Lincoln)",
        "8": "Unknown player (keep team)",
        "note": "",
        "saveDisabled": True,
        "changed": [],
    }
    assert out["again"] == {"note": "", "saveDisabled": True, "changed": []}
    assert out["otherTeam"] == {"note": "1 unsaved change", "saveDisabled": False, "changed": [7]}


def test_keep_team_names_no_side_and_shows_back_as_keep_team(tmp_path):
    """The "keep team" choice sent the side the analysis showed, so once saved it read back
    as that team's unknown player. It names no side now: the server takes the track's own
    team."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + f"""
route("POST", "/api/games/g_1/jobs", fail(409, "CONFLICT", "An analysis is already running"));
await load([{SMITH_TRACK_JS}]);
pickText(7, "Unknown player (keep team)");
byId("tracks-save").click();
await settle();
showTracks(""); // draw the table again from the saved override
console.log(JSON.stringify({{ trackPuts, shown: shown(7), ...pending(), navigatedTo: page.window.navigatedTo || null }}));
""",
    )
    assert out["trackPuts"] == [{"track_id": 7, "player_id": None, "side": None, "ignore": False}]
    assert out["shown"] == "Unknown player (keep team)"
    assert (out["note"], out["saveDisabled"], out["changed"]) == ("", True, [])
    assert out["navigatedTo"] is None  # the re-run did not start (409): the page stays


def test_referee_track_that_became_a_player_reads_well_in_the_table(tmp_path):
    """After the re-run the referee track is Central's unknown player: its row shows the
    team, no "0%" match for a choice that names no player, and it does not need attention."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + """
await load(
  [
    assignment({ track_id: 5, jersey: "5", best_read: "5", votes: { 5: 3 }, match_score: 1, method: "unrostered" }),
    assignment({ track_id: 90, team_id: null, method: "manual" }), // the pipeline called it a referee
  ],
  [{ track_id: 90, player_id: null, side: "scouted", ignore: false }],
);
console.log(JSON.stringify({
  track: textOf(rowFor(90).querySelector("th")),
  cells: cells(90),
  shown: shown(90),
  attention: showTracks("attention"),
  scouted: showTracks("scouted"),
}));
""",
    )
    assert out["track"] == "T90"
    assert out["cells"] == ["Central", "300", "–", "–", "–", "–", "Set by you"]
    assert out["shown"] == "Unknown player (Central)"
    assert out["attention"] == [5]
    assert out["scouted"] == [5, 90]


# ---------------------------------------------------------------------------
# 8. Method label for a number taken by another track
# ---------------------------------------------------------------------------


def test_track_whose_best_read_is_a_roster_number_is_an_unclear_match_not_off_roster(tmp_path):
    """ARCHITECTURE (assign_tracks): a track that is no roster player never shows a roster
    number. Its "How" said "Not on roster" although its best read, #23, is on the roster."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + f"""
await load([
  {SMITH_TRACK_JS},
  assignment({{ track_id: 2, best_read: "23", votes: {{ 23: 2, 28: 1 }}, match_score: 0.6667, method: "unrostered" }}),
  assignment({{ track_id: 6, jersey: "14", best_read: "14", votes: {{ 14: 3 }}, match_score: 1, method: "unrostered" }}),
]);
const how = (id) => rowFor(id).querySelectorAll("td")[6];
const describe = (id) => ({{ text: textOf(how(id)), title: how(id).getAttribute("title"), matched: cells(id)[4] }});
console.log(JSON.stringify({{ unclear: describe(2), offRoster: describe(6), matched: describe(7) }}));
""",
    )
    unclear = out["unclear"]
    assert (unclear["text"], unclear["matched"]) == ("Unclear match", "–")
    title = unclear["title"]
    assert title.startswith("Its best read is a roster number")
    assert "another track was matched to that player" in title and "too split" in title
    assert "Assign it yourself if you know who it is" in title
    assert out["offRoster"] == {"text": "Not on roster", "title": None, "matched": "#14 (not on roster)"}
    assert out["matched"] == {"text": "Exact read", "title": None, "matched": "#23 Sam Smith"}


# ---------------------------------------------------------------------------
# 9. Full re-analysis confirm text
# ---------------------------------------------------------------------------


def test_full_reanalysis_confirm_says_it_clears_the_track_assignments(tmp_path):
    """README (Court calibration): a Full re-analysis numbers the tracks again, so it clears
    the Roster page's track assignments. The confirm did not say so."""
    out = run_page(
        tmp_path,
        "game.html",
        "/games/g_1",
        """
const confirms = [];
page.window.confirm = (message) => { confirms.push(message); return false; };
gamePageRoutes(route, json, { gameBody: game(), analysisBody: analysis() });
await import("./js/game.js");
await settle();
byId("full-analysis-btn").click();
await settle();
console.log(JSON.stringify({ confirms, posts: server.log.filter((entry) => entry.startsWith("POST")) }));
""",
    )
    [message] = out["confirms"]
    assert "clears the track assignments you made on the Roster page; redo them afterwards" in message
    for fact in ("GPU again", "about as long as the first run", "another GPU run", "current results stay"):
        assert fact in message, fact
    assert out["posts"] == []  # declined: nothing started


# ---------------------------------------------------------------------------
# Extra: an assignment to a player who left the roster
# ---------------------------------------------------------------------------


def test_assignment_to_a_player_removed_from_the_roster_shows_as_automatic(tmp_path):
    """Saving the roster drops the manual assignments to a player who left it
    (``prune_track_overrides``), so the next run matches the track automatically, but the
    page showed it as "Unknown player (keep team)", a choice that sends its stats to the
    team line."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + f"""
await load(
  [{SMITH_SET_BY_COACH_JS}],
  [{{ track_id: 7, player_id: "p_1", side: "scouted", ignore: false }}],
);
const before = shown(7);
const card = $$("#roster-columns section")[0];
card.querySelector("button[data-remove]").click(); // Smith was a wrong entry
card.querySelectorAll("button").find((b) => textOf(b) === "Save roster").click();
await settle();
console.log(JSON.stringify({{ before, after: shown(7), ...pending(), puts: trackPuts.length }}));
""",
    )
    assert out == {
        "before": "#23 Sam Smith",
        "after": "Automatic (best jersey match)",
        "note": "",
        "saveDisabled": True,
        "changed": [],
        "puts": 0,
    }


def test_track_set_to_automatic_before_its_player_is_removed_still_reruns(tmp_path):
    """The other order of the round-one case (tests/test_review_frontend.py): the track is
    set back to Automatic first, then its player is removed. Saving the roster already
    dropped the override, so the DELETE answers 404 and the re-run must still start."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + f"""
route("DELETE", "/api/games/g_1/tracks/7", fail(404, "NOT_FOUND", "Not found"));
await load(
  [{SMITH_SET_BY_COACH_JS}],
  [{{ track_id: 7, player_id: "p_1", side: "scouted", ignore: false }}],
);
pickText(7, "Automatic (best jersey match)");
const card = $$("#roster-columns section")[0];
card.querySelector("button[data-remove]").click();
const before = pending();
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{
  before,
  deleted: server.log.includes("DELETE /api/games/g_1/tracks/7"),
  error: textOf(byId("tracks-error")),
  navigatedTo: page.window.navigatedTo || null,
}}));
""",
    )
    assert out == {
        "before": {"note": "1 unsaved change", "saveDisabled": False, "changed": [7]},
        "deleted": True,
        "error": "",
        "navigatedTo": "/games/g_1",
    }
