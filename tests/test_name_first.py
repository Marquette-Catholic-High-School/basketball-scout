"""Roster page: "Name these first" lists the longest unnamed tracks, and the match rate says how many reach 75%.

On the first real film 40% of team time stayed unnamed, mostly half-seen numbers ("3" for 13, 23 or 31) that no
rule can settle without guessing. A few long tracks carry most of it (7 tracks reached 75%), so the page leads
the coach to those, with a forecast that follows the choices made.
"""

from __future__ import annotations

from tests.test_review3_frontend import ROSTER_TRACKS_JS
from tests.test_review_frontend import run_page

# Rated: 1 (named) 600 + 2: 300 + 3: 200 + 4: 100 = 1200 frames. 5 has no team and 6 is a referee: not rated.
TRACKS_JS = """
await load([
  assignment({ track_id: 1, player_id: "p_1", jersey: "23", best_read: "23", votes: { 23: 9 }, match_score: 1, method: "exact", frames: 600 }),
  assignment({ track_id: 2, best_read: "2", votes: { 2: 8 }, match_score: 1, method: "unrostered", frames: 300 }),
  assignment({ track_id: 3, side: "other", team_id: 1, best_read: "34", jersey: "34", votes: { 34: 5 }, match_score: 1, method: "unrostered", frames: 200 }),
  assignment({ track_id: 4, side: "other", team_id: 1, frames: 100 }),
  assignment({ track_id: 5, side: null, team_id: null, frames: 500 }),
  assignment({ track_id: 6, side: null, team_id: null, role: "referee", frames: 400 }),
]);
const goal = () => textOf(byId("tracks-goal"));
"""


def _run(tmp_path, body: str) -> dict:
    return run_page(tmp_path, "roster.html", "/games/g_1/roster", ROSTER_TRACKS_JS + TRACKS_JS + body)


def test_the_goal_line_says_how_many_of_the_longest_tracks_reach_75_and_80(tmp_path):
    out = _run(tmp_path, """
console.log(JSON.stringify({ goal: goal(), hidden: byId("tracks-goal").hidden }));
""")
    assert not out["hidden"]
    assert out["goal"] == (
        "Jersey match rate: 50%. Naming the longest unnamed track brings it to 75% (2 for 80%). Show them"
    )


def test_name_these_first_lists_unnamed_team_tracks_longest_first_with_their_share(tmp_path):
    out = _run(tmp_path, """
$("#tracks-goal button").click();
await settle();
const rows = $$("#tracks-body tr[data-track]").map((tr) => Number(tr.dataset.track));
console.log(JSON.stringify({ filter: byId("tracks-filter").value, rows, seen: cells(2)[1], goal: goal() }));
""")
    assert out["filter"] == "first"
    assert out["rows"] == [2, 3, 4]  # named, team-less and referee tracks are not in it
    assert out["seen"] == "300 (25.0%)"
    assert "Show them" not in out["goal"]  # already showing them


def test_the_forecast_follows_the_choices_and_chosen_rows_stay_in_the_list(tmp_path):
    out = _run(tmp_path, """
showTracks("first");
pickText(3, "#4 Jo Jones");
const afterPick = goal();
const rows = showTracks("first");
pickText(4, "Not a player (referee, coach, fan…)");
console.log(JSON.stringify({ afterPick, rows, afterIgnore: goal(), seenOther: (showTracks(""), cells(2)[1]) }));
""")
    # 800 of 1200 named; then track 4 leaves the count: 800 of 1100.
    assert out["afterPick"].startswith("Jersey match rate: 50%. With your unsaved choices: about 67%.")
    assert out["rows"] == [2, 3, 4]
    assert "about 73%" in out["afterIgnore"]
    assert out["seenOther"] == "300"  # the other views keep the plain frame count


def test_at_the_goal_the_line_only_gives_the_rate(tmp_path):
    out = run_page(tmp_path, "roster.html", "/games/g_1/roster", ROSTER_TRACKS_JS + """
await load([
  assignment({ track_id: 1, player_id: "p_1", jersey: "23", best_read: "23", votes: { 23: 9 }, match_score: 1, method: "exact", frames: 900 }),
  assignment({ track_id: 2, frames: 100 }),
]);
console.log(JSON.stringify({ goal: textOf(byId("tracks-goal")) }));
""")
    assert out["goal"] == "Jersey match rate: 90%."
