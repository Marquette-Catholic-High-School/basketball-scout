"""Ball-holder assignment: which player controls the ball at each analysed frame."""

from __future__ import annotations

from modal_app.pipeline.events import EventConfig
from modal_app.pipeline.types import Perception


def assign_ball_holders(perception: Perception, cfg: EventConfig | None = None) -> None:
    """In place: set ``BallObs.holder_track_id`` (None while the ball is loose/in flight).

    Uses distance from the ball to the player's wrists (keypoints when present) or to the
    upper half of the bbox, with hysteresis so a holder must persist ``holder_min_frames``
    before control switches, and never assigns referees.
    """
    raise NotImplementedError
