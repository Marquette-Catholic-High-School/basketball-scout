"""Progress reporting: stage weights -> overall percentage, throttled sink calls."""

from __future__ import annotations

import time
from collections.abc import Callable

ProgressSink = Callable[[str, float, str], None]  # (stage, overall_pct 0..100, message)

# Relative cost of each stage (roughly wall-clock share for a 1080p game on an A10G).
STAGE_WEIGHTS: dict[str, float] = {
    "download": 3,
    "probe": 1,
    "detect": 50,
    "track": 4,
    "pose": 10,
    "ocr": 6,
    "teams": 2,
    "court": 3,
    "events": 3,
    "render": 16,
    "write": 2,
}


class ProgressTracker:
    def __init__(self, sink: ProgressSink | None = None, *, min_interval_s: float = 2.0, stages: list[str] | None = None) -> None:
        self.sink = sink
        self.min_interval_s = min_interval_s
        self.stages = stages or list(STAGE_WEIGHTS)
        self._total = sum(STAGE_WEIGHTS.get(s, 1) for s in self.stages)
        self._last_emit = 0.0
        self.overall = 0.0

    def update(self, stage: str, stage_pct: float, message: str = "", *, force: bool = False) -> float:
        done_before = 0.0
        for s in self.stages:
            if s == stage:
                break
            done_before += STAGE_WEIGHTS.get(s, 1)
        weight = STAGE_WEIGHTS.get(stage, 1)
        pct = 100.0 * (done_before + weight * max(0.0, min(100.0, stage_pct)) / 100.0) / self._total
        self.overall = max(self.overall, min(99.9, pct))
        now = time.monotonic()
        if self.sink and (force or now - self._last_emit >= self.min_interval_s):
            self._last_emit = now
            try:
                self.sink(stage, round(self.overall, 1), message)
            except Exception:  # progress must never break processing
                pass
        return self.overall

    def done(self, message: str = "Done") -> None:
        self.overall = 100.0
        if self.sink:
            try:
                self.sink("done", 100.0, message)
            except Exception:
                pass
