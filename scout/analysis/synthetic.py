"""Synthetic game generator.

Produces a plausible ``TrackingResult`` (tracks, ball, raw events, homography) with
scripted possessions -- pick-and-rolls, isolations, fast breaks, post-ups, handoffs,
zone and man defense, a press -- so that:

* ``SCOUT_PROCESSOR=mock`` can demo the whole app without a GPU, and
* tests can check the transform end to end against known ground truth.

Deterministic for a given ``seed``.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from scout.schemas import Roster, TeamSide, TrackingResult


@dataclass
class SyntheticTruth:
    """Ground truth for tests: what the generator scripted."""

    box: dict[str, dict[str, int]] = field(default_factory=dict)  # jersey key "scouted:#23" -> {"pts":..,"fgm":..}
    plays: list[dict] = field(default_factory=list)  # [{"type": "pick_and_roll", "side": "scouted", "start_t": .., "end_t": ..}]
    score: dict[str, int] = field(default_factory=dict)  # {"scouted": 41, "other": 37}


def generate_synthetic_game(
    *,
    seed: int = 7,
    duration_s: float = 600.0,
    fps: float = 30.0,
    analysis_fps: float = 10.0,
    with_homography: bool = True,
    ocr_noise: float = 0.15,
    filename: str = "synthetic.mp4",
) -> tuple[TrackingResult, SyntheticTruth]:
    """Return ``(tracking, truth)``. ``ocr_noise`` = share of jersey reads that are wrong/confused."""
    raise NotImplementedError


def synthetic_rosters(game_id: str, *, seed: int = 7) -> dict[TeamSide, Roster]:
    """Rosters whose jerseys match the players used by ``generate_synthetic_game`` (same seed)."""
    raise NotImplementedError
