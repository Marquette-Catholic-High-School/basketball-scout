"""A second opinion on each shot: did the ball go down through the rim?

The GPU pipeline decides made or missed itself and reports nearly the same confidence for every
shot, so its own number cannot say which calls to doubt. This check looks at the tracked ball
around each shot: a position just above the rim followed, within a second, by one just below it,
inside the rim's width. Where it disagrees with the GPU, or there is too little ball or no rim to
look at, the shot is listed for the coach to check (``ShotRecord.needs_review``).

It is a second opinion, not a better judge: on the first real film it agreed with the GPU on two
shots in three, and neither alone matched the real score. The coach's call settles it.
"""

from __future__ import annotations

import bisect
import statistics
from collections import defaultdict
from dataclasses import dataclass

from scout.schemas import ATTR_MADE, RawEventType, TrackingResult

RIM_PER_PLAYER_HEIGHT = 0.125  # the rim's half-width is about 1/8 of a standing player's height (9 in of 6 ft)
LOOK_AFTER_S = 2.5  # how long after the release (or the GPU's end of the shot) the ball is followed
MIN_BALL_POINTS = 3
DEFAULT_PLAYER_HEIGHT_PX = 120.0

REASON_UNKNOWN = "the GPU could not tell whether it went in"
REASON_DISAGREE_MADE = "the GPU says made, but the ball was not seen going through the rim"
REASON_DISAGREE_MISSED = "the GPU says missed, but the ball looks like it went through the rim"
REASON_NO_VIEW = "the ball or the rim was not seen well enough to check"


@dataclass(frozen=True)
class Check:
    through: bool | None  # None: not enough to look at
    reason: str | None  # why the coach should look at it; None when the two opinions agree


def check_shots(tracking: TrackingResult) -> dict[str, Check]:
    """A ``Check`` for every shot event, by event id."""
    fps = tracking.video.fps
    ball = sorted((b for b in tracking.ball if not b.interpolated), key=lambda b: b.f)
    frames = [b.f for b in ball]
    heights: dict[int, list[float]] = defaultdict(list)  # per second of film
    for track in tracking.tracks:
        if track.role != "player":
            continue
        for sample in track.samples[::3]:
            heights[int(sample.f // fps)].append(sample.bbox[3] - sample.bbox[1])
    rims = sorted(tracking.rims, key=lambda r: r.frame_start)
    out: dict[str, Check] = {}
    for event in tracking.events:
        if event.type != RawEventType.SHOT:
            continue
        made = event.attrs.get(ATTR_MADE)
        end = event.attrs.get("end_frame")
        start = event.frame
        stop = max(int(end) if isinstance(end, int | float) else start, start) + int(LOOK_AFTER_S * fps)
        path = ball[bisect.bisect_left(frames, start) : bisect.bisect_right(frames, stop)]
        through = None
        if len(path) >= MIN_BALL_POINTS:
            middle = (start + stop) // 2
            near_x = statistics.median(p.xy[0] for p in path)
            nearby = [r for r in rims if r.frame_start - 15 <= middle <= (r.frame_end if r.frame_end is not None else r.frame_start) + 15]
            if nearby:
                rim = min(nearby, key=lambda r: abs(r.xy_px[0] - near_x))
                second = int(start // fps)
                height = statistics.median(heights.get(second) or heights.get(second - 1) or [DEFAULT_PLAYER_HEIGHT_PX])
                through = _through(path, rim.xy_px, RIM_PER_PLAYER_HEIGHT * height, fps)
        if made is None:
            reason = REASON_UNKNOWN
        elif through is None:
            reason = REASON_NO_VIEW
        elif through != made:
            reason = REASON_DISAGREE_MADE if made else REASON_DISAGREE_MISSED
        else:
            reason = None
        out[event.event_id] = Check(through=through, reason=reason)
    return out


def _through(path, rim: tuple[float, float], half_width: float, fps: float) -> bool:
    """A ball position just above the rim, then within a second one just below it, both within its width."""
    rx, ry = rim
    r = max(half_width, 2.0)
    above = [p.f for p in path if abs(p.xy[0] - rx) < 2.5 * r and ry - 6 * r < p.xy[1] < ry - 0.3 * r]
    below = [p.f for p in path if abs(p.xy[0] - rx) < 1.5 * r and ry + 0.3 * r < p.xy[1] < ry + 4 * r]
    return any(0 < b - a < fps for a in above for b in below)
