"""Ball-holder assignment: which player controls the ball at each analysed frame.

How it works (image pixels only, so it needs no court mapping):

1. For every ball detection, measure the distance from the ball to each player's hands
   -- the nearer confident wrist keypoint, or the upper half of the bounding box when
   there are no keypoints -- in multiples of that player's bbox height, so the same
   thresholds work for players near and far from the camera.
2. The *candidate* at a frame is the nearest player within ``holder_acquire_dist``.
3. Hysteresis (offline, so it may look ahead): a run of at least ``holder_min_frames``
   frames with the same candidate gives him control from the first frame of the run;
   shorter runs (a deflection, a hand brushing the ball) never switch control.
4. Control continues while the ball stays within ``holder_keep_dist`` of the holder
   (dribbling) and survives the ball being away for up to ``holder_release_frames``
   frames; after that the ball is loose or in flight and the holder is None.

Only ``role == "player"`` tracks can hold the ball (never referees).
"""

from __future__ import annotations

import logging

import numpy as np

from modal_app.pipeline.events import NO_TRACK, EventConfig, frame_slots, hand_distance, wrist_points
from modal_app.pipeline.types import BallObs, Perception

logger = logging.getLogger(__name__)


def assign_ball_holders(perception: Perception, cfg: EventConfig | None = None) -> None:
    """In place: set ``BallObs.holder_track_id`` (None while the ball is loose/in flight).

    Uses distance from the ball to the player's wrists (keypoints when present) or to the
    upper half of the bbox, with hysteresis so a holder must persist ``holder_min_frames``
    before control switches, and never assigns referees.

    Every ball observation is recomputed: holders already set by the front end are
    replaced, so call this only when the front end did not supply them.
    """
    cfg = cfg or EventConfig()
    balls = sorted(perception.ball, key=lambda b: b.frame)
    if not balls:
        return
    step = max(1, int(perception.video.step))
    slots = frame_slots(np.array([b.frame for b in balls]), step)
    ball_idx, track_ids, dist, tiebreak = _hand_distances(perception, balls, slots, step, cfg)
    usable = np.array([b.conf >= cfg.ball_min_conf for b in balls], dtype=bool)
    candidate, near = _candidates(ball_idx, track_ids, dist, tiebreak, usable, cfg)
    holders = _hysteresis(candidate, near, slots, cfg)
    for ball, holder in zip(balls, holders.tolist(), strict=True):
        ball.holder_track_id = holder if holder != NO_TRACK else None
    logger.info("Ball holders: %d of %d ball frames have a holder", int((holders != NO_TRACK).sum()), len(balls))


def _hand_distances(
    perception: Perception, balls: list[BallObs], ball_slots: np.ndarray, step: int, cfg: EventConfig
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """For every (ball detection, player seen in that frame) pair: ball index, track id,
    hand distance (bbox heights) and a tie-break (distance to the upper-body centre)."""
    ball_xy = np.array([b.xy for b in balls], dtype=float).reshape(-1, 2)
    parts: list[tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]] = []
    for track in perception.player_tracks():
        obs = track.obs
        if not obs:
            continue
        obs_slots = frame_slots(np.fromiter((o.frame for o in obs), dtype=np.int64, count=len(obs)), step)
        at = np.minimum(np.searchsorted(ball_slots, obs_slots), len(ball_slots) - 1)
        rows = np.flatnonzero(ball_slots[at] == obs_slots)
        if not len(rows):
            continue
        b = at[rows]
        bbox = np.array([obs[i].bbox for i in rows], dtype=float).reshape(-1, 4)
        wrists = np.array([wrist_points(obs[i], cfg.keypoint_min_score) for i in rows], dtype=float).reshape(-1, 4)
        dist = hand_distance(ball_xy[b, 0], ball_xy[b, 1], bbox, wrists)
        h = np.maximum(bbox[:, 3] - bbox[:, 1], 1.0)
        centre_x, centre_y = (bbox[:, 0] + bbox[:, 2]) / 2, bbox[:, 1] + h / 4
        tiebreak = np.hypot(ball_xy[b, 0] - centre_x, ball_xy[b, 1] - centre_y) / h
        parts.append((b, np.full(len(b), track.track_id, dtype=np.int64), dist, tiebreak))
    if not parts:
        no_ids = np.zeros(0, dtype=np.int64)
        return no_ids, no_ids, np.zeros(0), np.zeros(0)
    b, t, d, tb = zip(*parts, strict=True)
    return np.concatenate(b), np.concatenate(t), np.concatenate(d), np.concatenate(tb)


def _candidates(
    ball_idx: np.ndarray,
    track_ids: np.ndarray,
    dist: np.ndarray,
    tiebreak: np.ndarray,
    usable: np.ndarray,
    cfg: EventConfig,
) -> tuple[np.ndarray, set[tuple[int, int]]]:
    """Nearest player within the acquire distance per ball detection (NO_TRACK if none), and
    the set of (ball index, track) pairs within the keep distance."""
    candidate = np.full(len(usable), NO_TRACK, dtype=np.int64)
    ok = usable[ball_idx]
    keep = ok & (dist <= cfg.holder_keep_dist)
    near = set(zip(ball_idx[keep].tolist(), track_ids[keep].tolist(), strict=True))
    acquire = np.flatnonzero(ok & (dist <= cfg.holder_acquire_dist))
    if len(acquire):
        order = acquire[np.lexsort((tiebreak[acquire], dist[acquire], ball_idx[acquire]))]
        first = order[np.unique(ball_idx[order], return_index=True)[1]]
        candidate[ball_idx[first]] = track_ids[first]
    return candidate, near


def _hysteresis(candidate: np.ndarray, near: set[tuple[int, int]], slots: np.ndarray, cfg: EventConfig) -> np.ndarray:
    """Holder per ball detection from the per-frame candidates (see the module docstring)."""
    cand, slot = candidate.tolist(), slots.tolist()  # plain lists: fast element access in the loops
    n = len(cand)
    holder = np.full(n, NO_TRACK, dtype=np.int64)
    continuous = cfg.holder_release_frames + 1  # max slot step that still counts as "the same moment"
    # 1. Anchors: runs of one candidate long enough to take control.
    start = 0
    while start < n:
        end = start
        while end + 1 < n and cand[end + 1] == cand[start] and slot[end + 1] - slot[end] <= continuous:
            end += 1
        if cand[start] != NO_TRACK and end - start + 1 >= cfg.holder_min_frames:
            holder[start : end + 1] = cand[start]
        start = end + 1
    # 2. Carry control between anchors while the ball stays near the holder; bridge short losses.
    anchors = holder.tolist()
    current, last = NO_TRACK, -1
    for i in range(n):
        if anchors[i] != NO_TRACK:
            if anchors[i] == current and slot[i] - slot[last] <= continuous:
                holder[last + 1 : i] = current
            current, last = anchors[i], i
        elif current != NO_TRACK:
            if slot[i] - slot[last] > continuous:
                current = NO_TRACK  # the ball has been away too long: loose or in flight
            elif (i, current) in near:
                holder[last + 1 : i + 1] = current
                last = i
    return holder
