"""Auth: password hashing, the Basic-auth middleware matrix, the login throttle, the CLI."""

from __future__ import annotations

import base64
import io
import logging

import pytest
from fastapi.testclient import TestClient

from scout import auth
from scout.main import create_app
from tests.conftest import TEST_PASSWORD, TEST_USER
from tests.test_api_support import make_app

FAST = 1_000  # PBKDF2 iterations for tests that do not check the default


def basic(user: str, password: str) -> dict[str, str]:
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------


def test_hash_password_format_and_verify():
    encoded = auth.hash_password("s3cret pass", iterations=FAST)
    algorithm, iterations, salt, digest = encoded.split("$")
    assert (algorithm, iterations) == ("pbkdf2_sha256", str(FAST))
    assert len(base64.b64decode(salt)) == 16 and len(base64.b64decode(digest)) == 32
    assert auth.verify_password("s3cret pass", encoded)
    assert not auth.verify_password("s3cret pas", encoded)
    assert auth.hash_password("s3cret pass", iterations=FAST) != encoded  # fresh salt each time


def test_default_iterations_are_strong():
    assert auth.DEFAULT_ITERATIONS >= 600_000
    assert auth.hash_password("x").split("$")[1] == str(auth.DEFAULT_ITERATIONS)


@pytest.mark.parametrize(
    "bad",
    ["", "plain", "md5$1000$c2FsdA==$ZGlnZXN0", "pbkdf2_sha256$many$c2FsdA==$ZGlnZXN0", "pbkdf2_sha256$1000$!!$ZGlnZXN0"],
)
def test_malformed_hashes_never_verify(bad):
    assert not auth.verify_password("anything", bad)
    with pytest.raises(ValueError):
        auth.parse_password_hash(bad)


def test_hash_rejects_empty_password():
    with pytest.raises(ValueError):
        auth.hash_password("")


# ---------------------------------------------------------------------------
# Middleware matrix
# ---------------------------------------------------------------------------


@pytest.fixture
def client():
    with TestClient(create_app()) as c:
        yield c


def test_no_credentials_gets_challenge(client):
    for path in ("/api/games", "/", "/static/js/app.js", "/api/health", "/games/g_123/roster"):
        r = client.get(path)
        assert r.status_code == 401, path
        assert r.headers["www-authenticate"] == 'Basic realm="Basketball Scout", charset="UTF-8"'
        assert r.json()["error"]["code"] == "AUTH_REQUIRED"


@pytest.mark.parametrize(
    "headers",
    [
        basic(TEST_USER, "wrong"),
        basic("someone", TEST_PASSWORD),
        {"Authorization": "Basic !!!not-base64"},
        {"Authorization": "Basic " + base64.b64encode(b"no-colon").decode()},
        {"Authorization": "Bearer abc"},
    ],
)
def test_wrong_credentials_rejected(client, headers):
    r = client.get("/api/games", headers=headers)
    assert r.status_code == 401
    assert "www-authenticate" in r.headers


def test_right_credentials_pass(client, auth_headers):
    assert client.get("/api/games", headers=auth_headers).json() == []
    assert client.get("/api/health", headers=auth_headers).status_code == 200


def test_health_live_is_the_only_open_route(client):
    assert client.get("/api/health/live").json() == {"status": "ok"}
    assert client.post("/api/health/live").status_code == 401


def test_password_hash_setting(monkeypatch):
    encoded = auth.hash_password("hashed-pw", iterations=FAST)
    monkeypatch.delenv("SCOUT_AUTH_PASSWORD")
    with TestClient(make_app(monkeypatch, SCOUT_AUTH_PASSWORD_HASH=encoded)) as c:
        assert c.get("/api/games", headers=basic(TEST_USER, "hashed-pw")).status_code == 200
        assert c.get("/api/games", headers=basic(TEST_USER, TEST_PASSWORD)).status_code == 401


def test_hash_wins_over_plain_password(monkeypatch):
    encoded = auth.hash_password("from-hash", iterations=FAST)
    with TestClient(make_app(monkeypatch, SCOUT_AUTH_PASSWORD_HASH=encoded)) as c:
        assert c.get("/api/games", headers=basic(TEST_USER, "from-hash")).status_code == 200
        assert c.get("/api/games", headers=basic(TEST_USER, TEST_PASSWORD)).status_code == 401


def test_verified_hash_is_cached(monkeypatch):
    encoded = auth.hash_password("cached-pw", iterations=FAST)
    calls = []
    real_verify = auth.verify_password
    monkeypatch.setattr(auth, "verify_password", lambda pw, h: calls.append(pw) or real_verify(pw, h))
    with TestClient(make_app(monkeypatch, SCOUT_AUTH_PASSWORD_HASH=encoded)) as c:
        for _ in range(3):
            assert c.get("/api/games", headers=basic(TEST_USER, "cached-pw")).status_code == 200
        assert c.get("/api/games", headers=basic(TEST_USER, "nope")).status_code == 401
    assert calls == ["cached-pw", "nope"]


def test_auth_disabled(monkeypatch, caplog):
    app = make_app(monkeypatch, SCOUT_AUTH_DISABLED="true")
    # localhost: with sign-in off the server answers only to known names (see test_review2_api.py)
    with caplog.at_level(logging.WARNING, logger="scout.auth"), TestClient(app, base_url="http://localhost") as c:
        assert c.get("/api/games").status_code == 200
        assert c.get("/api/health").json()["auth_enabled"] is False
    assert "AUTHENTICATION IS DISABLED" in caplog.text


def test_unconfigured_password_fails_closed(monkeypatch):
    monkeypatch.delenv("SCOUT_AUTH_PASSWORD")
    with TestClient(make_app(monkeypatch)) as c:
        r = c.get("/api/games", headers=basic(TEST_USER, ""))
        assert r.status_code == 503
        error = r.json()["error"]
        assert error["code"] == "AUTH_NOT_CONFIGURED" and "SCOUT_AUTH_PASSWORD" in error["message"]
        assert c.get("/").status_code == 503
        assert c.get("/api/health/live").status_code == 200


def test_malformed_hash_setting_fails_closed(monkeypatch):
    with TestClient(make_app(monkeypatch, SCOUT_AUTH_PASSWORD_HASH="pbkdf2_sha256$oops")) as c:
        r = c.get("/api/games", headers=basic(TEST_USER, TEST_PASSWORD))
        assert r.status_code == 503
        assert "SCOUT_AUTH_PASSWORD_HASH" in r.json()["error"]["message"]


# ---------------------------------------------------------------------------
# Brute-force throttle
# ---------------------------------------------------------------------------


def test_throttle_locks_out_one_ip_after_ten_failures(auth_headers):
    app = create_app()
    attacker = TestClient(app, client=("203.0.113.9", 4000))
    coach = TestClient(app, client=("198.51.100.7", 4000))
    with attacker, coach:
        _attack_then_check(attacker, coach, auth_headers)


def _attack_then_check(attacker: TestClient, coach: TestClient, auth_headers: dict[str, str]) -> None:
    for _ in range(9):
        assert attacker.get("/api/games", headers=basic(TEST_USER, "guess")).status_code == 401
    r = attacker.get("/api/games", headers=basic(TEST_USER, "guess"))
    assert r.status_code == 429
    assert r.json()["error"]["code"] == "AUTH_THROTTLED"
    assert 0 < int(r.headers["retry-after"]) <= 300
    # Locked out even with the right password; other computers are unaffected.
    assert attacker.get("/api/games", headers=auth_headers).status_code == 429
    assert attacker.get("/api/health/live").status_code == 200
    assert coach.get("/api/games", headers=auth_headers).status_code == 200


def test_missing_credentials_do_not_count_as_failures():
    with TestClient(create_app()) as c:
        for _ in range(15):
            assert c.get("/api/games").status_code == 401


class _Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def test_throttle_window_lockout_and_reset():
    clock = _Clock()
    throttle = auth.LoginThrottle(max_failures=10, window_s=300, lockout_s=300, clock=clock)
    for _ in range(9):
        assert not throttle.record_failure("ip")
    clock.now += 301  # those nine failures leave the five-minute window
    assert not throttle.record_failure("ip")
    assert throttle.retry_after("ip") is None

    for _ in range(8):  # 1 + 8 = 9 failures in the window: still allowed
        assert not throttle.record_failure("ip")
    assert throttle.record_failure("ip")  # the tenth locks the address out
    assert throttle.retry_after("ip") == pytest.approx(300)
    clock.now += 299
    assert throttle.retry_after("ip") == pytest.approx(1)
    clock.now += 2
    assert throttle.retry_after("ip") is None

    for _ in range(9):
        throttle.record_failure("other")
    throttle.reset("other")  # reset() clears the count (the middleware lets failures expire instead)
    assert not throttle.record_failure("other")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


class _Stdin(io.StringIO):
    def __init__(self, text: str, tty: bool) -> None:
        super().__init__(text)
        self._tty = tty

    def isatty(self) -> bool:
        return self._tty


def test_cli_hash_password_from_stdin(monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", _Stdin("piped password\n", tty=False))
    assert auth.main(["hash-password"]) == 0
    out, err = capsys.readouterr()
    encoded = out.strip()
    assert len(out.splitlines()) == 1 and auth.verify_password("piped password", encoded)
    assert "SCOUT_AUTH_PASSWORD_HASH='" in err


def test_cli_prompts_twice_on_a_terminal(monkeypatch, capsys):
    answers = iter(["first", "second"])
    monkeypatch.setattr("sys.stdin", _Stdin("", tty=True))
    monkeypatch.setattr("getpass.getpass", lambda prompt="": next(answers))
    assert auth.main(["hash-password"]) == 1
    assert "do not match" in capsys.readouterr().err


def test_cli_rejects_empty_password(monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", _Stdin("\n", tty=False))
    assert auth.main(["hash-password"]) == 1
    assert "empty" in capsys.readouterr().err


def test_auth_config_problem_messages(settings):
    assert auth.auth_config_problem(settings) is None
    unconfigured = settings.model_copy(update={"auth_password": None})
    assert "SCOUT_AUTH_PASSWORD" in auth.auth_config_problem(unconfigured)
    disabled = unconfigured.model_copy(update={"auth_disabled": True})
    assert auth.auth_config_problem(disabled) is None
