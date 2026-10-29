"""Background worker: runs analyze / reanalyze / report jobs.

Run with ``python -m scout.worker`` (systemd: ``basketball-scout-worker.service``).
"""

from __future__ import annotations

from scout.config import Settings
from scout.jobs.queue import JobQueue
from scout.processing.base import Processor
from scout.schemas import Job


class Worker:
    def __init__(
        self,
        settings: Settings | None = None,
        queue: JobQueue | None = None,
        processor: Processor | None = None,
        worker_id: str | None = None,
    ) -> None:
        raise NotImplementedError

    def run_forever(self) -> None:
        raise NotImplementedError

    def run_once(self, timeout: float = 1.0) -> bool:
        """Claim and fully process at most one job synchronously. True if a job ran."""
        raise NotImplementedError

    def process_job(self, job: Job) -> Job:
        raise NotImplementedError

    def stop(self) -> None:
        raise NotImplementedError


def main(argv: list[str] | None = None) -> int:
    raise NotImplementedError


if __name__ == "__main__":
    raise SystemExit(main())
