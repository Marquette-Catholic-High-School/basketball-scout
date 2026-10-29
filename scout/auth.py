"""HTTP Basic auth for the whole site, password hashing and a login throttle.

Every request (pages, ``/static``, ``/api``) needs the coach's username and password,
except ``GET /api/health/live`` so load balancers and uptime checks can probe the
server. Browsers show their own sign-in box when they get the 401 challenge and then
remember the credentials for the rest of the session.

Passwords can be configured two ways in ``.env``:

* ``SCOUT_AUTH_PASSWORD=...`` (plain text, simplest), or
* ``SCOUT_AUTH_PASSWORD_HASH='pbkdf2_sha256$<iterations>$<salt_b64>$<hash_b64>'``,
  printed by ``python -m scout.auth hash-password``. When both are set the hash wins.

If auth is enabled but neither is set, every request gets a 503 telling the admin what
to do (fail closed). ``SCOUT_AUTH_DISABLED=true`` turns auth off entirely, for a
server that is only reachable from a trusted network.

Ten failed sign-ins from one IP address within five minutes lock that address out for
five minutes (HTTP 429). The counters live in memory, so a restart clears them.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import logging
import secrets
import sys
import time
from collections import deque
from collections.abc import Callable

import anyio
from starlette.responses import JSONResponse, Response
from starlette.types import ASGIApp, Receive, Scope, Send

from scout.config import Settings
from scout.schemas import ErrorInfo

logger = logging.getLogger(__name__)

HASH_ALGORITHM = "pbkdf2_sha256"
DEFAULT_ITERATIONS = 600_000
SALT_BYTES = 16
REALM = "Basketball Scout"
CHALLENGE = f'Basic realm="{REALM}", charset="UTF-8"'
PUBLIC_ROUTES = frozenset({("GET", "/api/health/live")})

# Error codes for the auth responses. They are not in scout.errors.ErrorCode because
# they never come from a ScoutError (the middleware answers before FastAPI runs).
AUTH_REQUIRED = "AUTH_REQUIRED"
AUTH_THROTTLED = "AUTH_THROTTLED"
AUTH_NOT_CONFIGURED = "AUTH_NOT_CONFIGURED"


# ---------------------------------------------------------------------------
# Password hashing
# ---------------------------------------------------------------------------


def hash_password(password: str, *, iterations: int = DEFAULT_ITERATIONS, salt: bytes | None = None) -> str:
    """Return ``pbkdf2_sha256$<iterations>$<salt_b64>$<hash_b64>`` for ``password``."""
    if not password:
        raise ValueError("password must not be empty")
    if iterations < 1:
        raise ValueError("iterations must be positive")
    salt = salt or secrets.token_bytes(SALT_BYTES)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return "$".join((HASH_ALGORITHM, str(iterations), _b64(salt), _b64(digest)))


def parse_password_hash(encoded: str) -> tuple[int, bytes, bytes]:
    """Split a stored hash into ``(iterations, salt, digest)``; ``ValueError`` if malformed."""
    parts = encoded.strip().split("$")
    if len(parts) != 4 or parts[0] != HASH_ALGORITHM:
        raise ValueError(f"expected {HASH_ALGORITHM}$<iterations>$<salt_b64>$<hash_b64>")
    try:
        iterations = int(parts[1])
        salt = base64.b64decode(parts[2], validate=True)
        digest = base64.b64decode(parts[3], validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ValueError(f"invalid number or base64 in password hash: {exc}") from exc
    if iterations < 1 or not salt or not digest:
        raise ValueError("password hash has an empty salt/digest or a bad iteration count")
    return iterations, salt, digest


def verify_password(password: str, encoded: str) -> bool:
    """Constant-time check of ``password`` against a hash from :func:`hash_password`."""
    try:
        iterations, salt, expected = parse_password_hash(encoded)
    except ValueError:
        return False
    actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations, dklen=len(expected))
    return hmac.compare_digest(actual, expected)


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def auth_config_problem(settings: Settings) -> str | None:
    """Why auth cannot work with these settings (None when it can, or when it is disabled)."""
    if not settings.auth_enabled:
        return None
    if settings.auth_password_hash:
        try:
            parse_password_hash(settings.auth_password_hash)
        except ValueError as exc:
            return f"SCOUT_AUTH_PASSWORD_HASH is not valid ({exc}). Create a new one with `python -m scout.auth hash-password`."
        return None
    if not settings.auth_password:
        return "No sign-in password is configured. Set SCOUT_AUTH_PASSWORD (or SCOUT_AUTH_PASSWORD_HASH) in .env and restart."
    return None


def log_auth_status(settings: Settings) -> None:
    """Startup log lines so a misconfiguration is obvious in ``journalctl``."""
    if not settings.auth_enabled:
        logger.warning(
            "!!! AUTHENTICATION IS DISABLED (SCOUT_AUTH_DISABLED=true): anyone who can reach this server "
            "can see and delete every game. Only do this on a trusted, private network. !!!"
        )
        return
    problem = auth_config_problem(settings)
    if problem:
        logger.error("Sign-in is not set up, every request will get HTTP 503: %s", problem)
    elif settings.auth_password_hash and settings.auth_password:
        logger.info("Both SCOUT_AUTH_PASSWORD and SCOUT_AUTH_PASSWORD_HASH are set; using the hash.")


# ---------------------------------------------------------------------------
# Brute-force throttle
# ---------------------------------------------------------------------------


class LoginThrottle:
    """Counts failed sign-ins per client IP and locks an IP out after too many."""

    MAX_TRACKED_CLIENTS = 10_000  # prune old entries beyond this to bound memory

    def __init__(
        self,
        max_failures: int = 10,
        window_s: float = 300.0,
        lockout_s: float = 300.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.max_failures = max_failures
        self.window_s = window_s
        self.lockout_s = lockout_s
        self._clock = clock
        self._failures: dict[str, deque[float]] = {}
        self._locked_until: dict[str, float] = {}

    def retry_after(self, client: str) -> float | None:
        """Seconds until ``client`` may try again, or None if it is not locked out."""
        until = self._locked_until.get(client)
        if until is None:
            return None
        remaining = until - self._clock()
        if remaining <= 0:
            del self._locked_until[client]
            return None
        return remaining

    def record_failure(self, client: str) -> bool:
        """Count a failed attempt. Returns True when this failure triggers a lockout."""
        now = self._clock()
        attempts = self._failures.setdefault(client, deque())
        attempts.append(now)
        while attempts and attempts[0] <= now - self.window_s:
            attempts.popleft()
        if len(attempts) >= self.max_failures:
            del self._failures[client]
            self._locked_until[client] = now + self.lockout_s
            logger.warning("Too many failed sign-ins from %s; locked out for %.0f s", client, self.lockout_s)
            return True
        if len(self._failures) > self.MAX_TRACKED_CLIENTS:
            self._prune(now)
        return False

    def reset(self, client: str) -> None:
        self._failures.pop(client, None)

    def _prune(self, now: float) -> None:
        stale = [c for c, attempts in self._failures.items() if not attempts or attempts[-1] <= now - self.window_s]
        for client in stale:
            del self._failures[client]
        for client in [c for c, until in self._locked_until.items() if until <= now]:
            del self._locked_until[client]


# ---------------------------------------------------------------------------
# ASGI middleware
# ---------------------------------------------------------------------------


class BasicAuthMiddleware:
    """Pure ASGI middleware: checks HTTP Basic credentials before anything else runs.

    Pure ASGI (not ``BaseHTTPMiddleware``) so it never touches the request body; the
    chunked video upload streams straight through to its route.
    """

    MAX_CACHED_LOGINS = 32

    def __init__(self, app: ASGIApp, settings: Settings, throttle: LoginThrottle | None = None) -> None:
        self.app = app
        self.settings = settings
        self.throttle = throttle or LoginThrottle()
        # PBKDF2 is deliberately slow (~0.3 s). Remember credentials that already
        # verified, keyed by an HMAC with a per-process secret, so page loads and
        # progress polling do not pay that cost on every request.
        self._cache_key = secrets.token_bytes(32)
        self._verified: set[bytes] = set()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] not in ("http", "websocket") or not self.settings.auth_enabled or _is_public(scope):
            await self.app(scope, receive, send)
            return
        denial = await self._check(scope)
        if denial is None:
            await self.app(scope, receive, send)
        elif scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 1008})
        else:
            await denial(scope, receive, send)

    async def _check(self, scope: Scope) -> Response | None:
        """None when the request may proceed, else the error response to send."""
        problem = auth_config_problem(self.settings)
        if problem:
            return _error_response(503, AUTH_NOT_CONFIGURED, "Sign-in is not set up", problem)
        client = _client_ip(scope)
        wait = self.throttle.retry_after(client)
        if wait is not None:
            return _throttled_response(wait)
        header = _header(scope, b"authorization")
        if header is None or not header.lower().startswith("basic "):
            return _challenge_response()
        credentials = _decode_basic(header)
        if credentials is not None and await self._credentials_valid(*credentials):
            self.throttle.reset(client)
            return None
        logger.info("Failed sign-in from %s", client)
        if self.throttle.record_failure(client):
            return _throttled_response(self.throttle.lockout_s)
        return _challenge_response()

    async def _credentials_valid(self, username: str, password: str) -> bool:
        user_ok = secrets.compare_digest(username.encode("utf-8"), self.settings.auth_username.encode("utf-8"))
        stored_hash = self.settings.auth_password_hash
        if not stored_hash:
            expected = (self.settings.auth_password or "").encode("utf-8")
            return secrets.compare_digest(password.encode("utf-8"), expected) and user_ok
        cache_key = hmac.new(self._cache_key, f"{username}\x00{password}".encode(), hashlib.sha256).digest()
        if cache_key in self._verified:
            return True
        password_ok = await anyio.to_thread.run_sync(verify_password, password, stored_hash)
        if password_ok and user_ok:
            if len(self._verified) >= self.MAX_CACHED_LOGINS:
                self._verified.clear()
            self._verified.add(cache_key)
            return True
        return False


def _is_public(scope: Scope) -> bool:
    return (scope.get("method", ""), scope.get("path", "")) in PUBLIC_ROUTES


def _client_ip(scope: Scope) -> str:
    """Peer address (uvicorn rewrites it from X-Forwarded-For when nginx is trusted)."""
    client = scope.get("client")
    return client[0] if client else "unknown"


def _header(scope: Scope, name: bytes) -> str | None:
    for key, value in scope.get("headers", []):
        if key == name:
            return value.decode("latin-1")
    return None


def _decode_basic(header: str) -> tuple[str, str] | None:
    """``"Basic dXNlcjpwYXNz"`` -> ``("user", "pass")``; None if the payload is malformed."""
    try:
        decoded = base64.b64decode(header[6:].strip(), validate=True).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError):
        return None
    username, sep, password = decoded.partition(":")
    return (username, password) if sep else None


def _error_response(status: int, code: str, title: str, message: str, *, hint: str | None = None) -> JSONResponse:
    info = ErrorInfo(code=code, title=title, message=message, hint=hint)
    return JSONResponse({"error": info.model_dump()}, status_code=status, headers={"Cache-Control": "no-store"})


def _challenge_response() -> JSONResponse:
    response = _error_response(
        401,
        AUTH_REQUIRED,
        "Sign-in required",
        "Enter the Basketball Scout username and password.",
        hint="Ask the server administrator if you do not have them.",
    )
    response.headers["WWW-Authenticate"] = CHALLENGE
    return response


def _throttled_response(wait_s: float) -> JSONResponse:
    minutes = max(1, round(wait_s / 60))
    response = _error_response(
        429,
        AUTH_THROTTLED,
        "Too many sign-in attempts",
        f"Too many wrong passwords from this computer. Try again in about {minutes} minute(s).",
        hint="Check the username and password with the server administrator.",
    )
    response.headers["Retry-After"] = str(max(1, int(wait_s)))
    return response


# ---------------------------------------------------------------------------
# CLI: python -m scout.auth hash-password
# ---------------------------------------------------------------------------


def _read_new_password() -> str:
    """Prompt twice on a terminal, or read one line from piped stdin (install scripts)."""
    if sys.stdin.isatty():
        import getpass

        first = getpass.getpass("New password: ")
        if first != getpass.getpass("Repeat password: "):
            raise ValueError("the two passwords do not match")
    else:
        first = sys.stdin.readline().rstrip("\r\n")
    if not first:
        raise ValueError("the password must not be empty")
    return first


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m scout.auth", description="Basketball Scout sign-in helpers.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser(
        "hash-password",
        help="Print a SCOUT_AUTH_PASSWORD_HASH value (prompts twice, or reads one line from stdin).",
    )
    parser.parse_args(argv)
    try:
        password = _read_new_password()
    except (ValueError, EOFError, KeyboardInterrupt) as exc:
        print(f"error: {exc or 'no password entered'}", file=sys.stderr)
        return 1
    if len(password) < 8:
        print("warning: passwords shorter than 8 characters are easy to guess", file=sys.stderr)
    encoded = hash_password(password)
    print(encoded)
    print(f"Put this line in .env (keep the single quotes): SCOUT_AUTH_PASSWORD_HASH='{encoded}'", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
