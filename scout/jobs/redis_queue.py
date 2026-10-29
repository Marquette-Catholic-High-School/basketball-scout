"""Redis-backed job queue (``SCOUT_QUEUE_BACKEND=redis``).

Redis only decides which worker picks up which job id next; the ``jobs`` table in
SQLite stays the source of truth, so a duplicate or stale id in Redis is harmless:
``db.claim_job`` refuses anything that is not runnable and the id is dropped.

Keys (``<prefix>`` = ``SCOUT_REDIS_PREFIX``):

* ``<prefix>:queue`` -- list of waiting job ids (LPUSH in, BLMOVE out from the right: FIFO).
* ``<prefix>:processing:<worker_id>`` -- ids a worker has taken and not acked yet.
* ``<prefix>:workers`` -- hash worker_id -> last heartbeat (epoch seconds).
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from typing import Any, TypeVar

import redis

from scout import db
from scout.config import Settings
from scout.errors import ErrorCode, ScoutError
from scout.jobs.queue import JobQueue
from scout.schemas import Job, JobStatus

logger = logging.getLogger(__name__)

T = TypeVar("T")

DEAD_WORKER_SECONDS = 300.0  # no heartbeat for this long: the worker's taken ids go back to the queue
# Socket read timeout. redis-py >= 6 defaults to 5 s, exactly the worker's idle claim: Redis answers an
# expired BLMOVE a little after its timeout, so the read timed out and every idle claim looked like an
# outage (QUEUE_UNAVAILABLE). Each BLMOVE therefore waits at most _MAX_BLOCK_SECONDS, well inside it.
SOCKET_TIMEOUT_SECONDS = 15.0
_MAX_BLOCK_SECONDS = 5.0
_MIN_BLOCK_SECONDS = 0.05  # BLMOVE with timeout 0 would block forever


class RedisJobQueue(JobQueue):
    """Reliable-queue pattern: ``LPUSH <prefix>:queue`` / ``BLMOVE`` to a per-worker
    ``<prefix>:processing:<worker_id>`` list, ``LREM`` on ack. Job state still lives in
    SQLite; ``claim`` calls ``db.claim_job(..., job_id=...)`` for the popped id and skips
    ids that are no longer runnable. ``requeue_stale`` re-pushes running jobs whose lease
    expired and drains processing lists of dead workers.
    Raises ``ScoutError(QUEUE_UNAVAILABLE)`` when Redis is unreachable."""

    name = "redis"

    def __init__(self, settings: Settings | None = None, client: Any | None = None) -> None:
        super().__init__(settings)
        # The connection opens lazily on the first command, so constructing never fails.
        self.client = client if client is not None else redis.Redis.from_url(
            self.settings.redis_url,
            decode_responses=True,
            socket_connect_timeout=5,
            socket_timeout=SOCKET_TIMEOUT_SECONDS,
        )
        prefix = self.settings.redis_prefix
        self.queue_key = f"{prefix}:queue"
        self.workers_key = f"{prefix}:workers"
        self.processing_prefix = f"{prefix}:processing:"

    def processing_key(self, worker_id: str) -> str:
        return self.processing_prefix + worker_id

    def enqueue(self, job_id: str) -> None:
        self._redis(self.client.lpush, self.queue_key, job_id)

    def claim(self, worker_id: str, timeout: float = 5.0) -> Job | None:
        lease = self.settings.job_lease_seconds
        processing = self.processing_key(worker_id)
        deadline = time.monotonic() + max(0.0, timeout)
        self.heartbeat(worker_id)
        while True:
            block = min(max(deadline - time.monotonic(), _MIN_BLOCK_SECONDS), _MAX_BLOCK_SECONDS)
            job_id = self._redis(self.client.blmove, self.queue_key, processing, block, "RIGHT", "LEFT")
            if job_id is not None:
                job = db.claim_job(worker_id, lease, job_id=job_id)
                if job is not None:
                    return job
                logger.debug("Dropping job id %s from Redis: it is no longer runnable", job_id)
                # count=1 removes only the copy BLMOVE just put at the head: if the id is a duplicate of a
                # job this worker is already running, the original entry must stay until that job's ack.
                self._redis(self.client.lrem, processing, 1, job_id)
            if time.monotonic() >= deadline:
                break
        # Runnable jobs Redis does not know about: expired leases of dead workers, or jobs
        # created while Redis was down.
        job = db.claim_job(worker_id, lease)
        if job is not None:
            self._redis(self.client.lpush, processing, job.id)
        return job

    def ack(self, job_id: str, worker_id: str) -> None:
        self._redis(self.client.lrem, self.processing_key(worker_id), 0, job_id)

    def heartbeat(self, worker_id: str) -> None:
        """Mark ``worker_id`` alive so ``requeue_stale`` leaves its processing list alone."""
        self._redis(self.client.hset, self.workers_key, worker_id, time.time())

    def requeue_stale(self) -> int:
        # The rows stay `running` with their expired lease, as with the SQLite queue: db.claim_job
        # takes them, and a cancel is flagged for the worker that does, which then stops the GPU
        # call. Turned back into `queued` rows, a cancel was final at once: nobody stopped the GPU
        # call or cleared the Modal volume, and the game stayed "processing".
        now = time.time()
        expired = [
            job.id
            for job in db.list_jobs(statuses=[JobStatus.RUNNING], limit=1000)
            if job.lease_expires_at is not None and job.lease_expires_at < now
        ]
        waiting = set(self._redis(self.client.lrange, self.queue_key, 0, -1)) if expired else set()
        requeued = [job_id for job_id in reversed(expired) if job_id not in waiting]  # oldest first
        for job_id in requeued:
            self._redis(self.client.lpush, self.queue_key, job_id)
        if requeued:
            logger.warning("Requeued %d job(s) whose worker lease expired: %s", len(requeued), ", ".join(requeued))
        return len(requeued) + self._drain_dead_workers()

    def ping(self) -> bool:
        try:
            return bool(self.client.ping())
        except redis.exceptions.RedisError as exc:
            logger.warning("Redis ping failed: %s", exc)
            return False

    def close(self) -> None:
        self.client.close()

    def _drain_dead_workers(self) -> int:
        """Move ids held by workers without a recent heartbeat back onto the queue."""
        now = time.time()
        beats = self._redis(self.client.hgetall, self.workers_key)
        alive = {worker for worker, seen in beats.items() if now - _as_float(seen) < DEAD_WORKER_SECONDS}
        moved = 0
        for key in self._redis(self.client.keys, self.processing_prefix + "*"):
            worker_id = key[len(self.processing_prefix) :]
            if worker_id in alive:
                continue
            job_ids = self._redis(self.client.lrange, key, 0, -1)
            for job_id in job_ids:
                self._redis(self.client.lpush, self.queue_key, job_id)
                self._redis(self.client.lrem, key, 0, job_id)
            if job_ids:
                logger.warning(
                    "Worker %s stopped sending heartbeats; returned %d job id(s) to the queue", worker_id, len(job_ids)
                )
            moved += len(job_ids)
        dead = [worker for worker in beats if worker not in alive]
        if dead:
            self._redis(self.client.hdel, self.workers_key, *dead)
        return moved

    @staticmethod
    def _redis(command: Callable[..., T], *args: Any) -> T:
        """Run one Redis command, turning Redis failures into a coach-readable ScoutError."""
        try:
            return command(*args)
        except (redis.exceptions.ConnectionError, redis.exceptions.TimeoutError) as exc:
            raise ScoutError(ErrorCode.QUEUE_UNAVAILABLE, detail=f"{type(exc).__name__}: {exc}") from exc
        except redis.exceptions.RedisError as exc:
            raise ScoutError(
                ErrorCode.QUEUE_UNAVAILABLE,
                f"Redis rejected a queue command: {exc}",
                hint="Check the Redis server log. Basketball Scout needs Redis 6.2 or newer.",
                detail=f"{type(exc).__name__}: {exc}",
            ) from exc


def _as_float(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0
