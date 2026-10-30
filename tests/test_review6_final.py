"""Round 6, last fixes outside the three areas, found by the round's reviewers.

* The report tab's Version list no longer widens the game page on phones.
"""

from __future__ import annotations

import re

from tests.test_review_frontend import STATIC


def test_the_report_version_list_fits_a_phone_screen():
    """Once a game had a scouting report, the report tab's Version list (#report-history in
    label.inline-label in .card-head > .row) was as wide as its longest option, so the game
    page scrolled sideways on phones: 642 px wide at 320, 375 and 414 px with a real model
    name and a coach focus (headless Chrome, a file:// copy of the game page fed the real
    server's bodies). Each rule is needed: with the row rule alone the page stayed 642 px
    wide, and without the select rule it was still 35 px too wide."""
    css = (STATIC / "css" / "app.css").read_text(encoding="utf-8")
    row = re.search(r"\.card-head > \.row\s*\{([^}]*)\}", css)
    assert row and re.search(r"min-width:\s*0", row.group(1)), "the card head's row cannot shrink"
    label = re.search(r"(?:^|\n)\.inline-label\s*\{([^}]*)\}", css)
    assert label and re.search(r"max-width:\s*100%", label.group(1)), "an inline label can outgrow its row"
    select = re.search(r"\.inline-label select\s*\{([^}]*)\}", css)
    assert select and re.search(r"min-width:\s*0", select.group(1)), "a select in an inline label cannot shrink"
