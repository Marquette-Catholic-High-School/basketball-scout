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
five minutes (HTTP 429); thirty from one IPv6 /64 network lock out that network. The
counters live in memory, so a restart clears them. A successful sign-in does not clear
them: on a shared address that would let someone guess forever while the coach's page polls.

Many devices can share one address (a school's NAT, a router that loops the public
address back inside), so anyone behind it could keep the coach locked out. A browser
that signs in successfully therefore gets a signed ``scout_device`` cookie: while it
has one, lockouts of its address or network do not apply to it, but it has its own
limit of ten failures. The cookie is not a credential (every request still needs the
password) and its key lives in memory, so after a restart the next sign-in sets a new one.

Browsers send the saved credentials with every request to this site, including a form
or background ``fetch`` that a page on ANOTHER site submits (cross-site request
forgery). ``SameOriginMiddleware`` therefore refuses POST/PUT/PATCH/DELETE requests
that a browser marks as coming from another site (HTTP 403), with or without auth.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import ipaddress
import logging
import secrets
import sys
import time
from collections import deque
from collections.abc import Callable
from urllib.parse import urlsplit

import anyio
from starlette.responses import JSONResponse, Response
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from scout.config import Settings
from scout.schemas import ErrorInfo

logger = logging.getLogger(__name__)

HASH_ALGORITHM = "pbkdf2_sha256"
DEFAULT_ITERATIONS = 600_000
SALT_BYTES = 16
REALM = "Basketball Scout"
CHALLENGE = f'Basic realm="{REALM}", charset="UTF-8"'
PUBLIC_ROUTES = frozenset({("GET", "/api/health/live")})
SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})
NETWORK_MAX_FAILURES = 30  # per IPv6 /64 within the throttle window (see BasicAuthMiddleware)
DEVICE_COOKIE = "scout_device"
DEVICE_COOKIE_MAX_AGE_S = 365 * 24 * 3600

# Error codes for the auth responses. They are not in scout.errors.ErrorCode because
# they never come from a ScoutError (the middleware answers before FastAPI runs).
AUTH_REQUIRED = "AUTH_REQUIRED"
AUTH_THROTTLED = "AUTH_THROTTLED"
AUTH_NOT_CONFIGURED = "AUTH_NOT_CONFIGURED"
CROSS_SITE_REQUEST = "CROSS_SITE_REQUEST"


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

    def __init__(
        self,
        app: ASGIApp,
        settings: Settings,
        throttle: LoginThrottle | None = None,
        network_throttle: LoginThrottle | None = None,
    ) -> None:
        self.app = app
        self.settings = settings
        self.throttle = throttle or LoginThrottle()
        # IPv6 gives every home or school network a /64 with billions of addresses, so
        # failures are also counted per /64; otherwise rotating addresses allows endless
        # guesses. The higher limit keeps one bad device from locking out its network.
        self.network_throttle = network_throttle or LoginThrottle(max_failures=NETWORK_MAX_FAILURES)
        # Browsers that signed in carry a device cookie (see the module docstring); each
        # has its own failure count, so a stolen cookie gives no extra guesses.
        self.device_throttle = LoginThrottle()
        self._device_key = secrets.token_bytes(32)
        # PBKDF2 is deliberately slow (~0.3 s). Remember credentials that already
        # verified, keyed by an HMAC with a per-process secret, so page loads and
        # progress polling do not pay that cost on every request.
        self._cache_key = secrets.token_bytes(32)
        self._verified: set[bytes] = set()
        self._attempt_locks: dict[str, anyio.Lock] = {}

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] not in ("http", "websocket") or not self.settings.auth_enabled or _is_public(scope):
            await self.app(scope, receive, send)
            return
        denial, new_device = await self._check(scope)
        if denial is None:
            if new_device is not None and scope["type"] == "http":
                send = _adding_header(send, self._device_cookie(new_device, secure=scope.get("scheme") == "https"))
            await self.app(scope, receive, send)
        elif scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 1008})
        else:
            await denial(scope, receive, send)

    async def _check(self, scope: Scope) -> tuple[Response | None, str | None]:
        """``(None, new device id or None)`` when the request may proceed, else ``(error response, None)``."""
        problem = auth_config_problem(self.settings)
        if problem:
            return _error_response(503, AUTH_NOT_CONFIGURED, "Sign-in is not set up", problem), None
        client = _client_ip(scope)
        network = _client_network(client)
        device = self._known_device(scope)  # a browser that signed in: other devices' lockouts do not apply
        wait = None if device else self._retry_after(client, network)
        if wait is not None:
            return _throttled_response(wait), None
        header = _header(scope, b"authorization")
        if header is None or not header.lower().startswith("basic "):
            return _challenge_response(), None
        credentials = _decode_basic(header)
        # One attempt at a time per address (per /64 for IPv6): the hash check is slow
        # and runs in a thread, so a burst of parallel guesses would otherwise all be
        # tried before the lockout below could start.
        async with self._attempt_lock(network or client):
            wait = None if device else self._retry_after(client, network)
            if wait is not None:
                return _throttled_response(wait), None
            if credentials is not None and await self._credentials_valid(*credentials):
                # No reset of the failure counts: on a shared address the coach's polling
                # would wipe out someone else's guesses. They expire with the window, and
                # the device cookie keeps this browser clear of the address's lockout.
                return None, (None if device is not None else secrets.token_urlsafe(16))
            logger.info("Failed sign-in from %s", client)
            self.throttle.record_failure(client)
            if network is not None:
                self.network_throttle.record_failure(network)
            if device is not None and not self.device_throttle.record_failure(device):
                return _challenge_response(), None
            wait = self._retry_after(client, network)
            return (_challenge_response() if wait is None else _throttled_response(wait)), None

    def _retry_after(self, client: str, network: str | None) -> float | None:
        """Seconds until this address may sign in again (its own or its network's lockout)."""
        waits = [self.throttle.retry_after(client)]
        if network is not None:
            waits.append(self.network_throttle.retry_after(network))
        return max((wait for wait in waits if wait is not None), default=None)

    def _known_device(self, scope: Scope) -> str | None:
        """The device id from a genuine device cookie, unless that device locked itself out."""
        device, _, tag = (_cookie(scope, DEVICE_COOKIE) or "").partition(".")
        if not device or not hmac.compare_digest(tag.encode(), self._device_tag(device).encode()):
            return None
        return device if self.device_throttle.retry_after(device) is None else None

    def _device_tag(self, device: str) -> str:
        return hmac.new(self._device_key, device.encode(), hashlib.sha256).hexdigest()

    def _device_cookie(self, device: str, *, secure: bool) -> tuple[bytes, bytes]:
        value = f"{DEVICE_COOKIE}={device}.{self._device_tag(device)}; Path=/; Max-Age={DEVICE_COOKIE_MAX_AGE_S}"
        value += "; HttpOnly; SameSite=Lax" + ("; Secure" if secure else "")
        return b"set-cookie", value.encode("latin-1")

    def _attempt_lock(self, key: str) -> anyio.Lock:
        if len(self._attempt_locks) > LoginThrottle.MAX_TRACKED_CLIENTS:  # forget idle addresses
            self._attempt_locks = {k: lock for k, lock in self._attempt_locks.items() if lock.locked()}
        lock = self._attempt_locks.get(key)
        if lock is None:
            lock = self._attempt_locks[key] = anyio.Lock()
        return lock

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


class SameOriginMiddleware:
    """Pure ASGI middleware: refuse changes that a page on another website sent.

    Current browsers label every request with ``Sec-Fetch-Site``; older ones send an
    ``Origin`` (or at least a ``Referer``) on a form POST. Any of these naming another
    site blocks POST/PUT/PATCH/DELETE with a 403. A request with none of them is not
    from a web page (curl, scripts) and passes; so do all GET/HEAD/OPTIONS requests.
    Add it outside ``BasicAuthMiddleware`` so blocked requests never count as failed
    sign-ins.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and scope.get("method", "GET") not in SAFE_METHODS:
            source = _cross_site_source(scope)
            if source is not None:
                logger.warning("Blocked a cross-site %s %s (%s)", scope.get("method"), scope.get("path"), source)
                response = _error_response(
                    403,
                    CROSS_SITE_REQUEST,
                    "Request blocked",
                    "This change was sent from another website, so it was not made.",
                    hint="Open Basketball Scout directly (type its address or use a bookmark) and try again.",
                )
                await response(scope, receive, send)
                return
        await self.app(scope, receive, send)


def _cross_site_source(scope: Scope) -> str | None:
    """Why the request looks cross-site (for the log), or None when it is same-origin or not from a page."""
    fetch_site = (_header(scope, b"sec-fetch-site") or "").strip().lower()
    if fetch_site:
        return None if fetch_site in ("same-origin", "none") else f"Sec-Fetch-Site: {fetch_site}"
    for name in (b"origin", b"referer"):
        value = _header(scope, name)
        if value is not None:
            hosts = (_header(scope, b"host"), (_header(scope, b"x-forwarded-host") or "").split(",")[0].strip())
            return None if any(_same_host(value, host) for host in hosts) else f"{name.decode()}: {value[:200]}"
    return None


def _same_host(url: str, host: str | None) -> bool:
    """Whether ``url`` (an Origin or Referer) names the host this request was sent to.

    Ports are compared only when ``host`` has one: proxies such as nginx with
    ``proxy_set_header Host $host`` drop it. A page cannot set X-Forwarded-Host on a
    cross-site request, so matching it too is safe (Apache rewrites Host by default).
    """
    if not host:
        return False
    try:
        source, target = urlsplit(url), urlsplit(f"//{host}")
        if source.scheme not in ("http", "https") or not source.hostname or source.hostname != target.hostname:
            return False
        return target.port is None or (source.port or (443 if source.scheme == "https" else 80)) == target.port
    except ValueError:  # malformed port or IPv6 literal
        return False


def _is_public(scope: Scope) -> bool:
    return (scope.get("method", ""), scope.get("path", "")) in PUBLIC_ROUTES


def _client_ip(scope: Scope) -> str:
    """Peer address (uvicorn rewrites it from X-Forwarded-For when nginx is trusted).

    IPv4 clients of a dual-stack socket appear as ``::ffff:a.b.c.d``; they count as IPv4.
    """
    client = scope.get("client")
    host = client[0] if client else "unknown"
    try:
        mapped = getattr(ipaddress.ip_address(host), "ipv4_mapped", None)
    except ValueError:  # "unknown", a unix socket...
        return host
    return str(mapped) if mapped else host


def _client_network(client: str) -> str | None:
    """The /64 network of an IPv6 address (None for IPv4 and unknown peers)."""
    try:
        ip = ipaddress.ip_address(client)
        return str(ipaddress.ip_network(f"{ip}/64", strict=False)) if ip.version == 6 else None
    except ValueError:
        return None


def _header(scope: Scope, name: bytes) -> str | None:
    for key, value in scope.get("headers", []):
        if key == name:
            return value.decode("latin-1")
    return None


def _cookie(scope: Scope, name: str) -> str | None:
    for key, value in scope.get("headers", []):
        if key == b"cookie":
            for pair in value.decode("latin-1").split(";"):
                cookie, sep, content = pair.strip().partition("=")
                if sep and cookie == name:
                    return content.strip()
    return None


def _adding_header(send: Send, header: tuple[bytes, bytes]) -> Send:
    """``send`` that adds ``header`` to the response it starts."""

    async def wrapped(message: Message) -> None:
        if message["type"] == "http.response.start":
            message = {**message, "headers": [*message.get("headers", []), header]}
        await send(message)

    return wrapped


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
        f"Too many wrong passwords were tried from this computer or network. Try again in about {minutes} minute(s).",
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
