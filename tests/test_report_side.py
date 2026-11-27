"""Game page, report tab: "Report on" writes the report on either team, from the same analysis.

A coach who filmed Central vs Lincoln to scout Central can also scout Lincoln: the analysis holds
both teams' stats and plays, so the report on Lincoln needs no new upload or analysis.
"""

from __future__ import annotations

import json

from tests.test_api_support import sample_report
from tests.test_review_frontend import run_page

REPORT = sample_report().model_dump(mode="json")


def _record(report_id: str, side: str | None, created_at: str, headline: str) -> dict:
    record = {"id": report_id, "game_id": "g_1", "created_at": created_at, "model": "claude-opus-5-5",
              "coach_focus": None, "report": {**REPORT, "headline": headline}, "markdown": "", "usage": {},
              "stop_reason": "end_turn"}  # fmt: skip
    if side is not None:  # reports from before "Report on" have no side: they are on the scouted team
        record["side"] = side
    return record


def _run(tmp_path, reports: list[dict], body: str) -> dict:
    return run_page(tmp_path, "game.html", "/games/g_1", f"""
gamePageRoutes(route, json, {{ gameBody: game(), analysisBody: analysis() }});
route("GET", "/api/games/g_1/reports", json({json.dumps(reports)}));
await import("./js/game.js");
await settle();
const state = () => ({{
  options: [...byId("report-side").options].map((o) => o.textContent),
  side: byId("report-side").value,
  generate: textOf(byId("report-generate")),
  title: textOf($("#report-body h2")),
  headline: textOf($("#report-body .report-headline")),
  empty: textOf($("#report-body p.muted")),
  history: [...byId("report-history").options].map((o) => o.textContent.split(" · ").slice(1).join(" · ")),
}});
""" + body)


def test_report_on_names_both_teams_and_shows_the_chosen_teams_latest_report(tmp_path):
    reports = [
        _record("r_2", "other", "2026-11-25T10:00:00Z", "Lincoln push the pace"),
        _record("r_1", None, "2026-11-24T10:00:00Z", "Central live in the paint"),
    ]
    out = _run(tmp_path, reports, """
const first = state();
byId("report-side").value = "other";
fire(byId("report-side"), "change");
console.log(JSON.stringify({ first, other: state() }));
""")
    first, other = out["first"], out["other"]
    assert first["options"] == ["Central", "Lincoln"]
    assert first["side"] == "scouted" and first["generate"] == "Regenerate report"
    assert first["title"] == "Scouting report: Central" and first["headline"] == "Central live in the paint"
    assert first["history"] == ["Lincoln · claude-opus-5-5", "Central · claude-opus-5-5"]
    assert other["title"] == "Scouting report: Lincoln" and other["headline"] == "Lincoln push the pace"


def test_generate_on_the_other_team_sends_its_side(tmp_path):
    out = _run(tmp_path, [_record("r_1", "scouted", "2026-11-24T10:00:00Z", "Central live in the paint")], """
let posted = null;
route("POST", "/api/games/g_1/reports", (request) => { posted = request.body; return json({}, 500); });
byId("report-side").value = "other";
fire(byId("report-side"), "change");
const before = state();
byId("report-generate").click();
await settle();
console.log(JSON.stringify({ before, posted }));
""")
    assert out["before"]["generate"] == "Generate report"
    assert out["before"]["empty"].startswith("No scouting report on Lincoln yet.")
    assert out["posted"] == {"coach_focus": None, "side": "other"}


def test_picking_an_older_report_on_the_other_team_moves_report_on_with_it(tmp_path):
    reports = [
        _record("r_2", "scouted", "2026-11-25T10:00:00Z", "Central again"),
        _record("r_1", "other", "2026-11-24T10:00:00Z", "Lincoln push the pace"),
    ]
    out = _run(tmp_path, reports, """
byId("report-history").value = "r_1";
fire(byId("report-history"), "change");
console.log(JSON.stringify(state()));
""")
    assert out["side"] == "other" and out["title"] == "Scouting report: Lincoln"
    assert out["generate"] == "Regenerate report"
