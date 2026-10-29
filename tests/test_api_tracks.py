"""Track assignments and the coach's manual overrides."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from scout import db
from scout.main import create_app
from scout.schemas import Roster, RosterPlayer, TeamSide
from tests.test_api_support import write_analysis


@pytest.fixture
def client(auth_headers):
    with TestClient(create_app(), headers=auth_headers) as c:
        yield c


@pytest.fixture
def rostered_game(game):
    db.save_roster(Roster(game_id=game.id, side=TeamSide.SCOUTED, players=[RosterPlayer(id="p_s1", jersey="3")]))
    db.save_roster(Roster(game_id=game.id, side=TeamSide.OTHER, players=[RosterPlayer(id="p_o1", jersey="10")]))
    return game


def test_tracks_before_and_after_analysis(client, game, monkeypatch):
    assert client.get(f"/api/games/{game.id}/tracks").json() == {"assignments": [], "overrides": []}
    write_analysis(game, monkeypatch)
    body = client.get(f"/api/games/{game.id}/tracks").json()
    assert [a["track_id"] for a in body["assignments"]] == [7] and body["overrides"] == []


def test_put_override_validates_player_and_side(client, rostered_game):
    url = f"/api/games/{rostered_game.id}/tracks/12"
    r = client.put(url, json={"player_id": "p_s1", "side": "scouted", "track_id": 99})
    assert r.status_code == 200
    assert r.json() == {"track_id": 12, "player_id": "p_s1", "side": "scouted", "ignore": False}  # path id wins

    r = client.put(url, json={"player_id": "p_s1", "side": "other"})
    assert r.status_code == 422 and "other roster" in r.json()["error"]["message"]
    assert client.put(url, json={"player_id": "p_o1"}).status_code == 200  # side unknown: either roster
    r = client.put(url, json={"player_id": "p_ghost"})
    assert r.status_code == 422 and "either roster" in r.json()["error"]["message"]

    assert client.put(f"/api/games/{rostered_game.id}/tracks/40", json={"ignore": True}).status_code == 200
    overrides = client.get(f"/api/games/{rostered_game.id}/tracks").json()["overrides"]
    assert [(o["track_id"], o["player_id"], o["ignore"]) for o in overrides] == [(12, "p_o1", False), (40, None, True)]


def test_delete_override(client, rostered_game):
    url = f"/api/games/{rostered_game.id}/tracks/12"
    client.put(url, json={"player_id": "p_s1"})
    assert client.delete(url).status_code == 204
    assert db.list_track_overrides(rostered_game.id) == []
    assert client.delete(url).status_code == 404


def test_track_id_must_be_a_non_negative_integer(client, game):
    assert client.put(f"/api/games/{game.id}/tracks/abc", json={}).status_code == 422
    assert client.put(f"/api/games/{game.id}/tracks/-1", json={}).status_code == 422
