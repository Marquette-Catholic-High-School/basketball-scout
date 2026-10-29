"""Redis-backed job queue (``SCOUT_QUEUE_BACKEND=redis``)."""

from __future__ import annotations

from scout.config import Settings
from scout.jobs.queue import JobQueue
from scout.schemas import Job


class RedisJobQueue(JobQueue):
    """Reliable-queue pattern: ``LPUSH <prefix>:queue`` / ``BLMOVE`` to a per-worker
    ``<prefix>:processing:<worker_id>`` list, ``LREM`` on ack. Job state still lives in
    SQLite; ``claim`` calls ``db.claim_job(..., job_id=...)`` for the popped id and skips
    ids that are no longer runnable. ``requeue_stale`` re-pushes jobs with expired leases
    (``db.requeue_expired_jobs``) and drains processing lists of dead workers.
    Raises ``ScoutError(QUEUE_UNAVAILABLE)`` when Redis is unreachable."""

    name = "redis"

    def __init__(self, settings: Settings | None = None) -> None:
        raise NotImplementedError

    def enqueue(self, job_id: str) -> None:
        raise NotImplementedError

    def claim(self, worker_id: str, timeout: float = 5.0) -> Job | None:
        raise NotImplementedError
