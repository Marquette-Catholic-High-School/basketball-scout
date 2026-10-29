"""Rosters: read, replace, import (importer faked), player edits, CSV template."""

from __future__ import annotations

import csv
import io

import pytest
from fastapi.testclient import TestClient

from scout import db
from scout.errors import ErrorCode, ScoutError
from scout.main import create_app
from scout.roster import importer
from scout.schemas import Roster, RosterPlayer, TeamSide, TrackOverride


@pytest.fixture
def client(auth_headers):
    with TestClient(create_app(), headers=auth_headers) as c:
        yield c


def roster_url(game_id: str, side: str = "scouted") -> str:
    return f"/api/games/{game_id}/rosters/{side}"


def seed_roster(game_id: str, side: TeamSide = TeamSide.SCOUTED) -> Roster:
    players = [
        RosterPlayer(id="p_a1", jersey="3", first_name="Jordan", last_name="Smith"),
        RosterPlayer(id="p_b2", jersey="00", first_name="Chris", last_name="Lee"),
    ]
    return db.save_roster(Roster(game_id=game_id, side=side, team_name="Opponent HS", players=players))


def test_get_rosters_defaults_to_game_team_names(client, game):
    body = client.get(f"/api/games/{game.id}/rosters").json()
    assert body["scouted"]["team_name"] == "Opponent HS" and body["other"]["team_name"] == "Rival HS"
    assert body["scouted"]["players"] == [] and body["other"]["side"] == "other"
    assert client.get(roster_url(game.id, "other")).json()["team_name"] == "Rival HS"
    r = client.get(roster_url(game.id, "home"))
    assert r.status_code == 422 and r.json()["error"]["detail"].startswith("side:")
    assert client.get("/api/games/g_999999/rosters").status_code == 404


def test_put_replaces_roster_and_keeps_ids(client, game):
    players = [{"id": "p_keep", "jersey": "23", "first_name": "Sam", "last_name": "Hill"}, {"jersey": "5"}]
    r = client.put(roster_url(game.id), json={"team_name": "Opponent Varsity", "players": players})
    assert r.status_code == 200
    body = r.json()
    assert body["team_name"] == "Opponent Varsity"
    assert body["players"][0]["id"] == "p_keep" and body["players"][0]["name"] == "Sam Hill"
    assert body["players"][1]["id"].startswith("p_")
    # team_name left out: keep the current one.
    assert client.put(roster_url(game.id), json={"players": []}).json()["team_name"] == "Opponent Varsity"


def test_put_validates_players(client, game):
    r = client.put(roster_url(game.id), json={"players": [{"jersey": ""}, {"jersey": "1234"}]})
    assert r.status_code == 422
    assert r.json()["error"]["detail"].startswith("players[0].jersey: ")
    r = client.put(roster_url(game.id), json={"players": [{"id": "p_x", "jersey": "1"}, {"id": "p_x", "jersey": "2"}]})
    assert r.status_code == 422 and "same id" in r.json()["error"]["detail"]


def test_add_patch_delete_player(client, game):
    seed_roster(game.id)
    r = client.post(f"{roster_url(game.id)}/players", json={"jersey": "11", "first_name": "Ty"})
    assert r.status_code == 200
    added = r.json()["players"][-1]
    assert added["jersey"] == "11" and added["id"].startswith("p_")
    r = client.post(f"{roster_url(game.id)}/players", json={"id": "p_a1", "jersey": "4"})
    assert r.status_code == 409

    r = client.patch(f"{roster_url(game.id)}/players/p_a1", json={"jersey": "33", "position": "G"})
    smith = next(p for p in r.json()["players"] if p["id"] == "p_a1")
    assert (smith["jersey"], smith["position"], smith["last_name"]) == ("33", "G", "Smith")
    r = client.patch(f"{roster_url(game.id)}/players/p_a1", json={"first_name": None})
    assert r.status_code == 422 and r.json()["error"]["detail"].startswith("first_name")
    assert client.patch(f"{roster_url(game.id)}/players/p_nobody", json={"jersey": "1"}).status_code == 404

    r = client.delete(f"{roster_url(game.id)}/players/p_b2")
    assert [p["id"] for p in r.json()["players"]] == ["p_a1", added["id"]]
    assert client.delete(f"{roster_url(game.id)}/players/p_b2").status_code == 404


def test_removing_a_player_drops_their_track_overrides(client, game):
    seed_roster(game.id)
    db.set_track_override(game.id, TrackOverride(track_id=4, player_id="p_b2", side=TeamSide.SCOUTED))
    db.set_track_override(game.id, TrackOverride(track_id=5, player_id="p_a1"))
    db.set_track_override(game.id, TrackOverride(track_id=6, ignore=True))
    client.delete(f"{roster_url(game.id)}/players/p_b2")
    assert [o.track_id for o in db.list_track_overrides(game.id)] == [5, 6]


def test_import_roster_passes_results_through(client, game, monkeypatch):
    seed_roster(game.id)
    calls = {}

    def fake_parse(filename, content):
        calls["parse"] = (filename, content)
        return importer.RosterParseResult(
            players=[RosterPlayer(jersey="12", first_name="Alex", last_name="Kim")],
            skipped_rows=[{"row": 4, "reason": "missing jersey"}],
            warnings=["Jersey 12 appears twice"],
            detected_columns={"jersey": "#", "name": "Player"},
        )

    def fake_merge(existing, incoming, mode="replace"):
        calls["merge"] = (existing.side, mode)
        return existing.model_copy(update={"players": [*existing.players, *incoming]})

    monkeypatch.setattr(importer, "parse_roster_file", fake_parse)
    monkeypatch.setattr(importer, "merge_players", fake_merge)
    content = b"#,Player\n12,Alex Kim\n"
    r = client.post(
        f"{roster_url(game.id)}/import", files={"file": ("roster.csv", content, "text/csv")}, data={"mode": "merge"}
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert calls == {"parse": ("roster.csv", content), "merge": (TeamSide.SCOUTED, "merge")}
    assert body["imported"] == 1 and body["warnings"] == ["Jersey 12 appears twice"]
    assert body["skipped_rows"] == [{"row": 4, "reason": "missing jersey"}]
    assert body["detected_columns"] == {"jersey": "#", "name": "Player"}
    assert [p["jersey"] for p in body["roster"]["players"]] == ["3", "00", "12"]
    assert len(db.get_roster(game.id, TeamSide.SCOUTED).players) == 3


def test_import_roster_errors(client, game, monkeypatch):
    def unsupported(filename, content):
        raise ScoutError(ErrorCode.ROSTER_UNSUPPORTED_FILE)

    monkeypatch.setattr(importer, "parse_roster_file", unsupported)
    r = client.post(f"{roster_url(game.id)}/import", files={"file": ("roster.pdf", b"%PDF", "application/pdf")})
    assert r.status_code == 415 and r.json()["error"]["code"] == "ROSTER_UNSUPPORTED_FILE"
    r = client.post(f"{roster_url(game.id)}/import", files={"file": ("big.csv", b"x" * (2 * 1024 * 1024 + 1), "text/csv")})
    assert r.status_code == 413
    r = client.post(f"{roster_url(game.id)}/import", files={"file": ("r.csv", b"1,A", "text/csv")}, data={"mode": "append"})
    assert r.status_code == 422 and r.json()["error"]["detail"].startswith("mode:")
    assert client.post(f"{roster_url(game.id)}/import").status_code == 422


def test_roster_template(client):
    r = client.get("/api/roster-template.csv")
    assert r.status_code == 200
    assert r.headers["content-type"] == "text/csv; charset=utf-8"
    assert r.headers["content-disposition"] == 'attachment; filename="roster-template.csv"'
    rows = list(csv.reader(io.StringIO(r.text)))
    assert rows[0] == ["Jersey", "First Name", "Last Name", "Position", "Grade", "Height", "FastScout Name", "Notes"]
    assert len(rows) == 3 and all(len(row) == 8 for row in rows)
    assert rows[1][5] == "6'1\""
