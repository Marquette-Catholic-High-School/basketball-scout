"""Job queue abstraction.

The ``jobs`` table in SQLite is always the source of truth for job state (status,
stage, progress, errors). The queue only decides *which worker runs which job next*:

* ``SQLiteJobQueue`` (default, zero extra infrastructure): workers poll the table and
  claim jobs with an atomic ``UPDATE ... RETURNING``.
* ``RedisJobQueue`` (``SCOUT_QUEUE_BACKEND=redis``): job ids are pushed onto a Redis
  list and workers block on it, so pickup is instant and several worker machines can
  share one queue. See ``scout/jobs/redis_queue.py``.

Use :func:`submit_job` from API code: it creates the job row and enqueues it.
"""

from __future__ import annotations

import time
from abc import ABC, abstractmethod
from typing import Any

from scout import db
from scout.config import Settings, get_settings
from scout.schemas import Job, JobKind


class JobQueue(ABC):
    name: str = "base"

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()

    @abstractmethod
    def enqueue(self, job_id: str) -> None:
        """Make an already-created ``queued`` job row available to workers."""

    @abstractmethod
    def claim(self, worker_id: str, timeout: float = 5.0) -> Job | None:
        """Block up to ``timeout`` seconds for a runnable job and claim it (status -> running)."""

    def ack(self, job_id: str, worker_id: str) -> None:  # noqa: B027 - optional hook
        """Called when a worker finishes a job (any outcome)."""

    def requeue_stale(self) -> int:
        """Return jobs whose worker died (expired lease) to the queue. Returns how many."""
        return 0

    def ping(self) -> bool:
        return True

    def close(self) -> None:  # noqa: B027 - optional hook
        pass


class SQLiteJobQueue(JobQueue):
    name = "sqlite"

    def __init__(self, settings: Settings | None = None, poll_interval: float = 1.0) -> None:
        super().__init__(settings)
        self.poll_interval = poll_interval

    def enqueue(self, job_id: str) -> None:
        # The row is already 'queued'; claim() finds it.
        return None

    def claim(self, worker_id: str, timeout: float = 5.0) -> Job | None:
        deadline = time.monotonic() + max(0.0, timeout)
        while True:
            job = db.claim_job(worker_id, self.settings.job_lease_seconds)
            if job is not None:
                return job
            if time.monotonic() >= deadline:
                return None
            time.sleep(min(self.poll_interval, max(0.0, deadline - time.monotonic())))

    def ping(self) -> bool:
        try:
            db.list_jobs(limit=1)
            return True
        except Exception:
            return False


_queue: JobQueue | None = None


def get_queue(settings: Settings | None = None) -> JobQueue:
    """Process-wide queue instance for the configured backend."""
    global _queue
    settings = settings or get_settings()
    if _queue is not None and _queue.settings is settings:
        return _queue
    if settings.queue_backend == "redis":
        from scout.jobs.redis_queue import RedisJobQueue

        _queue = RedisJobQueue(settings)
    else:
        _queue = SQLiteJobQueue(settings)
    return _queue


def set_queue(queue: JobQueue | None) -> None:
    """Override the process-wide queue (tests)."""
    global _queue
    _queue = queue


def submit_job(game_id: str, kind: JobKind, params: dict[str, Any] | None = None, *, queue: JobQueue | None = None) -> Job:
    """Create a job row and hand it to the queue."""
    settings = get_settings()
    job = db.create_job(game_id, kind, params, processor=settings.processor if kind == JobKind.ANALYZE else None)
    (queue or get_queue(settings)).enqueue(job.id)
    return job
