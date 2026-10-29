"""SQLite persistence for games, jobs, rosters, track overrides, reports and uploads.

Design notes
------------
* One short-lived connection per call (``sqlite3`` connections are cheap); WAL mode
  lets the web process and the worker process read/write concurrently.
* Most entities are stored as a JSON document (the pydantic model) plus a few
  indexed columns. Jobs get real columns because the SQLite queue claims them with a
  single atomic ``UPDATE ... RETURNING`` statement.
* Migrations are numbered and tracked with ``PRAGMA user_version``.
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from collections.abc import Iterable, Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from scout.config import get_settings
from scout.errors import ErrorCode, ScoutError
from scout.schemas import (
    ErrorInfo,
    Game,
    GameCreate,
    Job,
    JobKind,
    JobStage,
    JobStatus,
    ReportRecord,
    Roster,
    TeamSide,
    TrackOverride,
    UploadSession,
)

_MIGRATIONS: dict[int, str] = {
    1: """
    CREATE TABLE games (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE TABLE jobs (
        id TEXT PRIMARY KEY,
        game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        status TEXT NOT NULL,
        stage TEXT NOT NULL,
        progress REAL NOT NULL DEFAULT 0,
        message TEXT NOT NULL DEFAULT '',
        error TEXT,
        warnings TEXT NOT NULL DEFAULT '[]',
        params TEXT NOT NULL DEFAULT '{}',
        attempts INTEGER NOT NULL DEFAULT 0,
        max_attempts INTEGER NOT NULL DEFAULT 3,
        processor TEXT,
        external_id TEXT,
        cancel_requested INTEGER NOT NULL DEFAULT 0,
        worker_id TEXT,
        lease_expires_at REAL,
        created_at TEXT NOT NULL,
        started_at TEXT,
        finished_at TEXT,
        updated_at TEXT NOT NULL
    );
    CREATE INDEX idx_jobs_status ON jobs(status, created_at);
    CREATE INDEX idx_jobs_game ON jobs(game_id, created_at);
    CREATE TABLE rosters (
        game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
        side TEXT NOT NULL,
        data TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (game_id, side)
    );
    CREATE TABLE track_overrides (
        game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
        track_id INTEGER NOT NULL,
        data TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (game_id, track_id)
    );
    CREATE TABLE reports (
        id TEXT PRIMARY KEY,
        game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
        data TEXT NOT NULL,
        created_at TEXT NOT NULL
    );
    CREATE INDEX idx_reports_game ON reports(game_id, created_at);
    CREATE TABLE uploads (
        id TEXT PRIMARY KEY,
        game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
        data TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE TABLE worker_heartbeats (
        worker_id TEXT PRIMARY KEY,
        seen_at REAL NOT NULL,
        info TEXT NOT NULL DEFAULT '{}'
    );
    """,
}

_init_lock = threading.Lock()
_initialized: set[str] = set()


def utcnow() -> datetime:
    return datetime.now(UTC)


def _iso(value: datetime | None) -> str | None:
    return value.astimezone(UTC).isoformat() if value else None


# ---------------------------------------------------------------------------
# Connections & migrations
# ---------------------------------------------------------------------------


def _db_path(path: Path | None = None) -> Path:
    return Path(path) if path else get_settings().database_path


def connect(path: Path | None = None) -> sqlite3.Connection:
    target = _db_path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(target, timeout=30, isolation_level=None, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def init_db(path: Path | None = None) -> None:
    """Create/upgrade the schema. Safe to call repeatedly and from several processes."""
    key = str(_db_path(path))
    if key in _initialized:
        return
    with _init_lock:
        if key in _initialized:
            return
        conn = connect(Path(key))
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                current = conn.execute("PRAGMA user_version").fetchone()[0]
                for version in sorted(v for v in _MIGRATIONS if v > current):
                    for statement in _split_sql(_MIGRATIONS[version]):
                        conn.execute(statement)
                    conn.execute(f"PRAGMA user_version={int(version)}")
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        finally:
            conn.close()
        _initialized.add(key)


def reset_db_cache() -> None:
    """Forget which databases were initialised (tests point SCOUT_DATA_DIR at temp dirs)."""
    _initialized.clear()


def _split_sql(script: str) -> list[str]:
    return [s.strip() for s in script.split(";") if s.strip()]


@contextmanager
def session(path: Path | None = None) -> Iterator[sqlite3.Connection]:
    init_db(path)
    conn = connect(path)
    try:
        yield conn
    finally:
        conn.close()


@contextmanager
def transaction(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise


def _not_found(what: str, ident: str) -> ScoutError:
    return ScoutError(ErrorCode.NOT_FOUND, f"{what} {ident!r} not found.")


# ---------------------------------------------------------------------------
# Games
# ---------------------------------------------------------------------------


def create_game(data: GameCreate) -> Game:
    now = utcnow()
    game = Game(**data.model_dump(exclude_none=True), created_at=now, updated_at=now)
    with session() as conn:
        conn.execute(
            "INSERT INTO games(id, data, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            (game.id, game.model_dump_json(), game.status.value, _iso(now), _iso(now)),
        )
    return game


def save_game(game: Game) -> Game:
    """Insert or replace a game document (bumps ``updated_at``)."""
    now = utcnow()
    game = game.model_copy(update={"updated_at": now, "created_at": game.created_at or now})
    with session() as conn:
        conn.execute(
            """INSERT INTO games(id, data, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET data=excluded.data, status=excluded.status, updated_at=excluded.updated_at""",
            (game.id, game.model_dump_json(), game.status.value, _iso(game.created_at), _iso(now)),
        )
    return game


def get_game(game_id: str) -> Game | None:
    with session() as conn:
        row = conn.execute("SELECT data FROM games WHERE id = ?", (game_id,)).fetchone()
    return Game.model_validate_json(row["data"]) if row else None


def require_game(game_id: str) -> Game:
    game = get_game(game_id)
    if game is None:
        raise _not_found("Game", game_id)
    return game


def list_games() -> list[Game]:
    with session() as conn:
        rows = conn.execute("SELECT data FROM games ORDER BY created_at DESC").fetchall()
    return [Game.model_validate_json(r["data"]) for r in rows]


def update_game(game_id: str, **changes: Any) -> Game:
    """Atomically merge ``changes`` (Game field names) into a stored game."""
    with session() as conn, transaction(conn):
        row = conn.execute("SELECT data FROM games WHERE id = ?", (game_id,)).fetchone()
        if row is None:
            raise _not_found("Game", game_id)
        current = Game.model_validate_json(row["data"])
        merged = current.model_dump()
        merged.update(changes)
        merged["updated_at"] = utcnow()
        game = Game.model_validate(merged)
        conn.execute(
            "UPDATE games SET data = ?, status = ?, updated_at = ? WHERE id = ?",
            (game.model_dump_json(), game.status.value, _iso(game.updated_at), game_id),
        )
    return game


def delete_game(game_id: str) -> bool:
    with session() as conn:
        cur = conn.execute("DELETE FROM games WHERE id = ?", (game_id,))
    return cur.rowcount > 0


# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

_JOB_JSON_FIELDS = {"error", "warnings", "params"}
_JOB_UPDATABLE = {
    "status",
    "stage",
    "progress",
    "message",
    "error",
    "warnings",
    "params",
    "attempts",
    "max_attempts",
    "processor",
    "external_id",
    "cancel_requested",
    "worker_id",
    "lease_expires_at",
    "started_at",
    "finished_at",
}


def _job_from_row(row: sqlite3.Row) -> Job:
    data = dict(row)
    data["error"] = json.loads(data["error"]) if data.get("error") else None
    data["warnings"] = json.loads(data.get("warnings") or "[]")
    data["params"] = json.loads(data.get("params") or "{}")
    data["cancel_requested"] = bool(data.get("cancel_requested"))
    return Job.model_validate(data)


def _job_value(field: str, value: Any) -> Any:
    if field == "error":
        if value is None:
            return None
        if isinstance(value, ScoutError):
            value = value.to_info()
        if isinstance(value, ErrorInfo):
            return value.model_dump_json()
        return json.dumps(value)
    if field in _JOB_JSON_FIELDS:
        return json.dumps(value, default=str)
    if isinstance(value, datetime):
        return _iso(value)
    if field == "cancel_requested":
        return int(bool(value))
    if hasattr(value, "value"):  # enums
        return value.value
    return value


def create_job(
    game_id: str,
    kind: JobKind,
    params: dict[str, Any] | None = None,
    *,
    max_attempts: int | None = None,
    processor: str | None = None,
) -> Job:
    now = utcnow()
    job = Job(
        game_id=game_id,
        kind=kind,
        params=params or {},
        max_attempts=max_attempts or get_settings().job_max_attempts,
        processor=processor,
        message="Waiting for a worker",
        created_at=now,
        updated_at=now,
    )
    with session() as conn:
        conn.execute(
            """INSERT INTO jobs(id, game_id, kind, status, stage, progress, message, warnings, params,
                                attempts, max_attempts, processor, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, 0, ?, '[]', ?, 0, ?, ?, ?, ?)""",
            (
                job.id,
                game_id,
                kind.value,
                job.status.value,
                job.stage.value,
                job.message,
                json.dumps(job.params, default=str),
                job.max_attempts,
                processor,
                _iso(now),
                _iso(now),
            ),
        )
    return job


def get_job(job_id: str) -> Job | None:
    with session() as conn:
        row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    return _job_from_row(row) if row else None


def require_job(job_id: str) -> Job:
    job = get_job(job_id)
    if job is None:
        raise _not_found("Job", job_id)
    return job


def list_jobs(
    *, game_id: str | None = None, statuses: Iterable[JobStatus] | None = None, limit: int = 100
) -> list[Job]:
    sql = "SELECT * FROM jobs WHERE 1=1"
    args: list[Any] = []
    if game_id:
        sql += " AND game_id = ?"
        args.append(game_id)
    status_values = [s.value for s in statuses] if statuses else []
    if status_values:
        sql += f" AND status IN ({','.join('?' * len(status_values))})"
        args.extend(status_values)
    sql += " ORDER BY created_at DESC, rowid DESC LIMIT ?"
    args.append(int(limit))
    with session() as conn:
        rows = conn.execute(sql, args).fetchall()
    return [_job_from_row(r) for r in rows]


def update_job(job_id: str, **fields: Any) -> Job:
    unknown = set(fields) - _JOB_UPDATABLE
    if unknown:
        raise ValueError(f"cannot update job fields: {sorted(unknown)}")
    fields["updated_at"] = utcnow()
    columns = ", ".join(f"{name} = ?" for name in fields)
    values = [_job_value(name, value) for name, value in fields.items()]
    with session() as conn:
        row = conn.execute(f"UPDATE jobs SET {columns} WHERE id = ? RETURNING *", (*values, job_id)).fetchone()
    if row is None:
        raise _not_found("Job", job_id)
    return _job_from_row(row)


def claim_job(worker_id: str, lease_seconds: float, *, job_id: str | None = None) -> Job | None:
    """Atomically take the oldest runnable job (or ``job_id``).

    Runnable = ``queued``, or ``running`` with an expired lease (its worker died). A
    re-claimed job keeps its stage and ``external_id`` so the new worker can resume
    polling the GPU call instead of resubmitting.
    """
    now = time.time()
    now_iso = _iso(utcnow())
    with session() as conn:
        row = conn.execute(
            """UPDATE jobs
               SET status = 'running', worker_id = :worker, lease_expires_at = :lease,
                   attempts = attempts + 1, started_at = COALESCE(started_at, :now_iso), updated_at = :now_iso
               WHERE id = (
                   SELECT id FROM jobs
                   WHERE (status = 'queued'
                          OR (status = 'running' AND lease_expires_at IS NOT NULL AND lease_expires_at < :now))
                     AND (:job_id IS NULL OR id = :job_id)
                   ORDER BY created_at, rowid
                   LIMIT 1
               )
               RETURNING *""",
            {"worker": worker_id, "lease": now + lease_seconds, "now_iso": now_iso, "now": now, "job_id": job_id},
        ).fetchone()
    return _job_from_row(row) if row else None


def heartbeat_job(job_id: str, worker_id: str, lease_seconds: float) -> bool:
    """Extend the lease if ``worker_id`` still owns the running job."""
    with session() as conn:
        cur = conn.execute(
            "UPDATE jobs SET lease_expires_at = ?, updated_at = ? WHERE id = ? AND worker_id = ? AND status = 'running'",
            (time.time() + lease_seconds, _iso(utcnow()), job_id, worker_id),
        )
    return cur.rowcount > 0


def request_cancel(job_id: str) -> Job:
    """Cancel a queued job immediately; flag a running job so its worker stops it.

    A queued job that already has a processor handle (``external_id``: a GPU call that may still
    be running, as an older version's Redis reaper left them) is flagged like a running one, so the
    worker that claims it cancels the call, deletes the remote files and settles the game.
    """
    with session() as conn, transaction(conn):
        row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        if row is None:
            raise _not_found("Job", job_id)
        job = _job_from_row(row)
        now_iso = _iso(utcnow())
        if job.status == JobStatus.QUEUED and not job.external_id:
            conn.execute(
                """UPDATE jobs SET status = 'cancelled', stage = ?, cancel_requested = 1, message = 'Cancelled',
                   finished_at = ?, updated_at = ? WHERE id = ?""",
                (JobStage.DONE.value, now_iso, now_iso, job_id),
            )
        elif job.status in (JobStatus.QUEUED, JobStatus.RUNNING):
            conn.execute(
                "UPDATE jobs SET cancel_requested = 1, message = 'Cancelling...', updated_at = ? WHERE id = ?",
                (now_iso, job_id),
            )
        row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    return _job_from_row(row)


def active_jobs_for_game(game_id: str) -> list[Job]:
    return list_jobs(game_id=game_id, statuses=[JobStatus.QUEUED, JobStatus.RUNNING])


# ---------------------------------------------------------------------------
# Rosters & track overrides
# ---------------------------------------------------------------------------


def get_roster(game_id: str, side: TeamSide) -> Roster:
    with session() as conn:
        row = conn.execute("SELECT data FROM rosters WHERE game_id = ? AND side = ?", (game_id, side.value)).fetchone()
    if row:
        return Roster.model_validate_json(row["data"])
    game = get_game(game_id)
    team_name = ""
    if game:
        team_name = game.scouted_team if side == TeamSide.SCOUTED else game.other_team
    return Roster(game_id=game_id, side=side, team_name=team_name)


def get_rosters(game_id: str) -> dict[TeamSide, Roster]:
    return {side: get_roster(game_id, side) for side in TeamSide}


def save_roster(roster: Roster) -> Roster:
    now = utcnow()
    roster = roster.model_copy(update={"updated_at": now})
    with session() as conn:
        conn.execute(
            """INSERT INTO rosters(game_id, side, data, updated_at) VALUES (?, ?, ?, ?)
               ON CONFLICT(game_id, side) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at""",
            (roster.game_id, roster.side.value, roster.model_dump_json(), _iso(now)),
        )
    return roster


def list_track_overrides(game_id: str) -> list[TrackOverride]:
    with session() as conn:
        rows = conn.execute(
            "SELECT data FROM track_overrides WHERE game_id = ? ORDER BY track_id", (game_id,)
        ).fetchall()
    return [TrackOverride.model_validate_json(r["data"]) for r in rows]


def set_track_override(game_id: str, override: TrackOverride) -> TrackOverride:
    with session() as conn:
        conn.execute(
            """INSERT INTO track_overrides(game_id, track_id, data, updated_at) VALUES (?, ?, ?, ?)
               ON CONFLICT(game_id, track_id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at""",
            (game_id, override.track_id, override.model_dump_json(), _iso(utcnow())),
        )
    return override


def delete_track_override(game_id: str, track_id: int) -> bool:
    with session() as conn:
        cur = conn.execute("DELETE FROM track_overrides WHERE game_id = ? AND track_id = ?", (game_id, track_id))
    return cur.rowcount > 0


def clear_track_overrides(game_id: str) -> int:
    with session() as conn:
        cur = conn.execute("DELETE FROM track_overrides WHERE game_id = ?", (game_id,))
    return cur.rowcount


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------


def save_report(record: ReportRecord) -> ReportRecord:
    record = record.model_copy(update={"created_at": record.created_at or utcnow()})
    with session() as conn:
        conn.execute(
            """INSERT INTO reports(id, game_id, data, created_at) VALUES (?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET data = excluded.data""",
            (record.id, record.game_id, record.model_dump_json(), _iso(record.created_at)),
        )
    return record


def get_report(report_id: str) -> ReportRecord | None:
    with session() as conn:
        row = conn.execute("SELECT data FROM reports WHERE id = ?", (report_id,)).fetchone()
    return ReportRecord.model_validate_json(row["data"]) if row else None


def list_reports(game_id: str) -> list[ReportRecord]:
    with session() as conn:
        rows = conn.execute(
            "SELECT data FROM reports WHERE game_id = ? ORDER BY created_at DESC, rowid DESC", (game_id,)
        ).fetchall()
    return [ReportRecord.model_validate_json(r["data"]) for r in rows]


def latest_report(game_id: str) -> ReportRecord | None:
    reports = list_reports(game_id)
    return reports[0] if reports else None


# ---------------------------------------------------------------------------
# Uploads
# ---------------------------------------------------------------------------


def save_upload(upload: UploadSession) -> UploadSession:
    now = utcnow()
    upload = upload.model_copy(update={"updated_at": now, "created_at": upload.created_at or now})
    with session() as conn:
        conn.execute(
            """INSERT INTO uploads(id, game_id, data, updated_at) VALUES (?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at""",
            (upload.id, upload.game_id, upload.model_dump_json(), _iso(now)),
        )
    return upload


def get_upload(upload_id: str) -> UploadSession | None:
    with session() as conn:
        row = conn.execute("SELECT data FROM uploads WHERE id = ?", (upload_id,)).fetchone()
    return UploadSession.model_validate_json(row["data"]) if row else None


def list_uploads(game_id: str) -> list[UploadSession]:
    with session() as conn:
        rows = conn.execute("SELECT data FROM uploads WHERE game_id = ? ORDER BY updated_at DESC", (game_id,)).fetchall()
    return [UploadSession.model_validate_json(r["data"]) for r in rows]


def delete_upload(upload_id: str) -> bool:
    with session() as conn:
        cur = conn.execute("DELETE FROM uploads WHERE id = ?", (upload_id,))
    return cur.rowcount > 0


# ---------------------------------------------------------------------------
# Worker heartbeats (for the health endpoint)
# ---------------------------------------------------------------------------


def record_worker_heartbeat(worker_id: str, info: dict[str, Any] | None = None) -> None:
    with session() as conn:
        conn.execute(
            """INSERT INTO worker_heartbeats(worker_id, seen_at, info) VALUES (?, ?, ?)
               ON CONFLICT(worker_id) DO UPDATE SET seen_at = excluded.seen_at, info = excluded.info""",
            (worker_id, time.time(), json.dumps(info or {}, default=str)),
        )


def last_worker_heartbeat() -> float | None:
    """Epoch seconds of the most recent heartbeat from any worker, or None."""
    with session() as conn:
        row = conn.execute("SELECT MAX(seen_at) AS seen FROM worker_heartbeats").fetchone()
    return row["seen"] if row and row["seen"] is not None else None
