"""RedisJobQueue against a small in-memory fake of redis-py (and a real Redis when
SCOUT_TEST_REDIS_URL is set)."""

from __future__ import annotations

import fnmatch
import os
import threading
import time
import uuid

import pytest
import redis

from scout import config, db
from scout.errors import ErrorCode, ScoutError
from scout.jobs import queue as job_queue
from scout.jobs.queue import submit_job
from scout.jobs.redis_queue import DEAD_WORKER_SECONDS, RedisJobQueue
from scout.schemas import JobKind, JobStatus

# Read at import: the autouse fixture in conftest.py removes every SCOUT_* variable.
REAL_REDIS_URL = os.environ.get("SCOUT_TEST_REDIS_URL")


class FakeRedis:
    """The redis-py commands RedisJobQueue uses (decode_responses=True semantics)."""

    def __init__(self) -> None:
        self.lists: dict[str, list[str]] = {}
        self.hashes: dict[str, dict[str, str]] = {}
        self.changed = threading.Condition()
        self.error: Exception | None = None  # raised by every command, e.g. redis.ConnectionError
        self.closed = False

    def _check(self) -> None:
        if self.error is not None:
            raise self.error

    def lpush(self, key: str, *values: str) -> int:
        self._check()
        with self.changed:
            items = self.lists.setdefault(key, [])
            for value in values:
                items.insert(0, str(value))
            self.changed.notify_all()
            return len(items)

    def blmove(
        self, source: str, destination: str, timeout: float, src: str = "LEFT", dest: str = "RIGHT"
    ) -> str | None:
        self._check()
        assert timeout > 0, "BLMOVE with timeout 0 blocks forever"
        deadline = time.monotonic() + timeout
        with self.changed:
            while not self.lists.get(source):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self.changed.wait(remaining)
            items = self.lists[source]
            value = items.pop() if src == "RIGHT" else items.pop(0)
            if not items:
                del self.lists[source]
            target = self.lists.setdefault(destination, [])
            target.insert(0, value) if dest == "LEFT" else target.append(value)
            return value

    def lrem(self, key: str, count: int, value: str) -> int:
        self._check()
        assert count >= 0, "removing from the tail is not used"
        with self.changed:
            items = self.lists.get(key, [])
            kept, removed = [], 0
            for v in items:  # from the head, like Redis
                if v == value and (count == 0 or removed < count):
                    removed += 1
                else:
                    kept.append(v)
            if kept:
                self.lists[key] = kept
            else:
                self.lists.pop(key, None)  # Redis deletes empty lists
            return removed

    def lrange(self, key: str, start: int, end: int) -> list[str]:
        self._check()
        items = self.lists.get(key, [])
        return list(items[start:] if end == -1 else items[start : end + 1])

    def ping(self) -> bool:
        self._check()
        return True

    def hset(self, key: str, field: str, value: object) -> int:
        self._check()
        self.hashes.setdefault(key, {})[field] = str(value)
        return 1

    def hgetall(self, key: str) -> dict[str, str]:
        self._check()
        return dict(self.hashes.get(key, {}))

    def hdel(self, key: str, *fields: str) -> int:
        self._check()
        table = self.hashes.get(key, {})
        return sum(table.pop(f, None) is not None for f in fields)

    def keys(self, pattern: str) -> list[str]:
        self._check()
        return [k for k in [*self.lists, *self.hashes] if fnmatch.fnmatchcase(k, pattern)]

    def close(self) -> None:
        self.closed = True


@pytest.fixture
def fake_redis() -> FakeRedis:
    return FakeRedis()


@pytest.fixture
def rq(fake_redis) -> RedisJobQueue:
    return RedisJobQueue(client=fake_redis)


def test_enqueue_claim_ack(rq, fake_redis, game):
    job = submit_job(game.id, JobKind.ANALYZE, queue=rq)
    assert fake_redis.lists["scout:queue"] == [job.id]

    claimed = rq.claim("w1", timeout=0.5)
    assert claimed.id == job.id and claimed.status == JobStatus.RUNNING and claimed.worker_id == "w1"
    assert "scout:queue" not in fake_redis.lists
    assert fake_redis.lists["scout:processing:w1"] == [job.id]
    assert "w1" in fake_redis.hashes["scout:workers"]  # claim doubles as a heartbeat

    rq.ack(job.id, "w1")
    assert "scout:processing:w1" not in fake_redis.lists


def test_claim_is_fifo(rq, game):
    first = submit_job(game.id, JobKind.REPORT, queue=rq)
    second = submit_job(game.id, JobKind.REPORT, queue=rq)
    assert rq.claim("w1", timeout=0.2).id == first.id
    assert rq.claim("w1", timeout=0.2).id == second.id


def test_claim_drops_ids_that_are_no_longer_runnable(rq, fake_redis, game):
    cancelled = submit_job(game.id, JobKind.REPORT, queue=rq)
    db.request_cancel(cancelled.id)  # queued -> cancelled at once, but its id is still in Redis
    wanted = submit_job(game.id, JobKind.REPORT, queue=rq)
    rq.enqueue(wanted.id)  # a duplicate id is harmless too

    assert rq.claim("w1", timeout=0.5).id == wanted.id
    assert fake_redis.lists["scout:processing:w1"] == [wanted.id]
    assert rq.claim("w1", timeout=0.1) is None  # the duplicate is skipped: the job is already running
    assert fake_redis.lists["scout:processing:w1"] == [wanted.id]


def test_claim_falls_back_to_expired_leases(rq, fake_redis, game):
    job = submit_job(game.id, JobKind.ANALYZE, queue=job_queue.SQLiteJobQueue())  # never pushed to Redis
    assert db.claim_job("w-dead", 60, job_id=job.id) is not None
    db.update_job(job.id, lease_expires_at=time.time() - 1, external_id="fc-123")

    reclaimed = rq.claim("w2", timeout=0.1)
    assert reclaimed.id == job.id and reclaimed.worker_id == "w2" and reclaimed.attempts == 2
    assert reclaimed.external_id == "fc-123"
    assert fake_redis.lists["scout:processing:w2"] == [job.id]


def test_claim_times_out_when_idle(rq):
    started = time.monotonic()
    assert rq.claim("w1", timeout=0.1) is None
    assert time.monotonic() - started < 1.0
    assert rq.claim("w1", timeout=0) is None  # never BLMOVE with 0 (that would block forever)


def test_claim_wakes_up_when_a_job_arrives(rq, game):
    job = db.create_job(game.id, JobKind.REPORT)
    threading.Timer(0.1, rq.enqueue, args=(job.id,)).start()
    started = time.monotonic()
    assert rq.claim("w1", timeout=3).id == job.id
    assert time.monotonic() - started < 2.0


def test_requeue_stale_returns_expired_leases_to_the_queue(rq, fake_redis, game):
    job = submit_job(game.id, JobKind.ANALYZE, queue=rq)
    assert rq.claim("w1", timeout=0.2).id == job.id
    db.update_job(job.id, lease_expires_at=time.time() - 1)

    assert rq.requeue_stale() >= 1
    assert db.get_job(job.id).status == JobStatus.QUEUED
    assert job.id in fake_redis.lists["scout:queue"]
    assert rq.claim("w2", timeout=0.2).id == job.id


def test_requeue_stale_drains_lists_of_dead_workers(rq, fake_redis, game):
    held = db.create_job(game.id, JobKind.REPORT)
    busy = db.create_job(game.id, JobKind.REPORT)
    fake_redis.lists["scout:processing:host-a:111"] = [held.id]
    fake_redis.lists["scout:processing:host-b:222"] = [busy.id]
    fake_redis.lists["scout:processing:host-c:333"] = ["j_ghost"]  # never sent a heartbeat at all
    fake_redis.hashes["scout:workers"] = {
        "host-a:111": str(time.time() - DEAD_WORKER_SECONDS - 60),
        "host-b:222": str(time.time()),
        "host-d:444": str(time.time() - DEAD_WORKER_SECONDS - 60),  # dead and idle
    }

    assert rq.requeue_stale() == 2
    assert sorted(fake_redis.lists["scout:queue"]) == sorted([held.id, "j_ghost"])
    assert "scout:processing:host-a:111" not in fake_redis.lists
    assert "scout:processing:host-c:333" not in fake_redis.lists
    assert fake_redis.lists["scout:processing:host-b:222"] == [busy.id]  # alive: untouched
    assert set(fake_redis.hashes["scout:workers"]) == {"host-b:222"}
    assert rq.claim("w9", timeout=0.2).id == held.id  # still queued in SQLite, so it runs again


def test_redis_errors_become_queue_unavailable(rq, fake_redis, game):
    fake_redis.error = redis.exceptions.ConnectionError("Error 61 connecting to localhost:6379. Connection refused.")
    calls = (
        lambda: rq.enqueue("j_1"),
        lambda: rq.claim("w1", timeout=0.1),
        rq.requeue_stale,
        lambda: rq.ack("j_1", "w1"),
    )
    for call in calls:
        with pytest.raises(ScoutError) as exc:
            call()
        assert exc.value.code == ErrorCode.QUEUE_UNAVAILABLE
        assert exc.value.retryable
    assert rq.ping() is False

    fake_redis.error = redis.exceptions.ResponseError("ERR unknown command 'BLMOVE'")
    with pytest.raises(ScoutError) as exc:
        rq.claim("w1", timeout=0.1)
    assert exc.value.code == ErrorCode.QUEUE_UNAVAILABLE and "rejected" in exc.value.message

    fake_redis.error = None
    assert rq.ping() is True


def test_custom_prefix_and_close(fake_redis, monkeypatch, game):
    monkeypatch.setenv("SCOUT_REDIS_PREFIX", "school")
    config.reset_settings()
    rq = RedisJobQueue(client=fake_redis)
    submit_job(game.id, JobKind.REPORT, queue=rq)
    assert list(fake_redis.lists) == ["school:queue"]
    rq.close()
    assert fake_redis.closed


def test_get_queue_builds_a_redis_queue_without_connecting(monkeypatch):
    monkeypatch.setenv("SCOUT_QUEUE_BACKEND", "redis")
    monkeypatch.setenv("SCOUT_REDIS_URL", "redis://127.0.0.1:1/0")  # nothing listens there
    config.reset_settings()
    rq = job_queue.get_queue()
    assert isinstance(rq, RedisJobQueue) and rq.name == "redis"
    assert isinstance(rq.client, redis.Redis)  # the connection only opens on the first command


@pytest.mark.skipif(not REAL_REDIS_URL, reason="set SCOUT_TEST_REDIS_URL=redis://host:6379/15 to use a real Redis")
def test_against_a_real_redis(monkeypatch, game):
    prefix = f"scout-test-{uuid.uuid4().hex[:8]}"
    monkeypatch.setenv("SCOUT_REDIS_URL", REAL_REDIS_URL)
    monkeypatch.setenv("SCOUT_REDIS_PREFIX", prefix)
    config.reset_settings()
    rq = RedisJobQueue()
    try:
        assert rq.ping()
        job = submit_job(game.id, JobKind.REPORT, queue=rq)
        claimed = rq.claim("w-real", timeout=2)
        assert claimed.id == job.id
        assert rq.client.lrange(rq.processing_key("w-real"), 0, -1) == [job.id]
        rq.ack(job.id, "w-real")
        assert rq.client.lrange(rq.processing_key("w-real"), 0, -1) == []
        assert rq.claim("w-real", timeout=0.2) is None
        assert rq.requeue_stale() == 0
    finally:
        keys = rq.client.keys(f"{prefix}:*")
        if keys:
            rq.client.delete(*keys)
        rq.close()
