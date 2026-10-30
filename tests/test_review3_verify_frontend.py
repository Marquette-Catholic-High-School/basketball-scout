"""Regression tests from the verification of the third frontend review round.

They run the real Roster page in the node fake-DOM harness of ``tests/test_review_frontend.py``
with the routes of ``tests/test_review3_frontend.py``. Since round four the fake DOM's
``click()`` skips a disabled control, as a browser does; a test still asserts the button is
enabled before it clicks, so a failure says why.
"""

from __future__ import annotations

import re

from tests.test_review3_frontend import ROSTER_TRACKS_JS, SMITH_SET_BY_COACH_JS
from tests.test_review_frontend import STATIC, run_page


def test_a_removed_player_keeps_his_assignment_until_the_roster_is_saved(tmp_path):
    """Removing a player in the roster editor changes nothing on the server until the roster
    is saved (saving drops his track assignments), so the saved choice for his track still
    holds. The page compared choices with the unsaved roster instead: setting the track back
    to Automatic was "no change" and left Save & re-run disabled (the round-one flow of
    tests/test_review_frontend.py), and picking the player again counted as a change that
    PUT a removed player after the roster save."""
    out = run_page(
        tmp_path,
        "roster.html",
        "/games/g_1/roster",
        ROSTER_TRACKS_JS
        + f"""
route("DELETE", "/api/games/g_1/tracks/7", fail(404, "NOT_FOUND", "Not found")); // the roster save dropped it
await load(
  [{SMITH_SET_BY_COACH_JS}],
  [{{ track_id: 7, player_id: "p_1", side: "scouted", ignore: false }}],
);
const card = $$("#roster-columns section")[0];
card.querySelector("button[data-remove]").click(); // Smith was a wrong entry; the roster is not saved yet
const after = (text) => ({{ picked: pickText(7, text), ...pending() }});
const choices = {{
  keepTeam: after("Unknown player (keep team)"),
  smith: after("#23 Sam Smith (removed, not saved yet)"), // what the server still holds (marked since round six)
  automatic: after("Automatic (best jersey match)"),
}};
byId("tracks-save").click();
await settle();
console.log(JSON.stringify({{
  choices,
  writes: server.log.filter((entry) => !entry.startsWith("GET")),
  error: textOf(byId("tracks-error")),
  navigatedTo: page.window.navigatedTo || null,
}}));
""",
    )
    changed = {"picked": True, "note": "1 unsaved change", "saveDisabled": False, "changed": [7]}
    assert out["choices"] == {
        "keepTeam": changed,
        "smith": {"picked": True, "note": "", "saveDisabled": True, "changed": []},
        "automatic": changed,
    }
    # Save & re-run saves the roster first, which already dropped the assignment (DELETE 404).
    assert out["writes"] == [
        "PUT /api/games/g_1/rosters/scouted",
        "DELETE /api/games/g_1/tracks/7",
        "POST /api/games/g_1/jobs",
    ]
    assert (out["error"], out["navigatedTo"]) == ("", "/games/g_1")


def test_assignment_choices_stay_readable_on_phones():
    """Each team's "Unknown player (...)" differs from "Unknown player (keep team)" only at
    the end. Measured in headless Chrome: below about 900 px the tracks table scrolls inside
    its frame and the "Assign to" select shrank to its 4rem minimum (64 px at 320, 375 and
    768 px), so all three read "Unkn". At 14rem "Unknown player (keep team)" fits; the page
    itself still does not scroll sideways."""
    css = (STATIC / "css" / "app.css").read_text(encoding="utf-8")
    rule = re.search(r"\.track-table select\s*\{([^}]*)\}", css)
    assert rule, "no .track-table select rule"
    width = re.search(r"min-width:\s*([\d.]+)rem", rule.group(1))
    assert width and float(width.group(1)) >= 14
