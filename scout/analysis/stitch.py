"""Stitching: let a jersey number carry across the pieces a player's track breaks into.

The tracker starts a new track every time it loses a player (someone walks in front of him, he
leaves the frame), so one player is dozens of short tracks over a game, and most of them never
get a clear look at his number. When a track ends and another of the same team starts a moment
later at nearly the same spot, they are the same player: ``share_jersey_reads`` gives every piece
of such a chain the jersey reads of all of it, and the roster matcher then names each piece the
usual way. Track ids, positions and events are untouched.

Deliberately careful: a link needs both tracks to be each other's clear first choice. A missed
link leaves a piece unnamed, as before; a wrong link would put stats on the wrong player.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from scout.schemas import Track, TrackingResult

logger = logging.getLogger(__name__)

MAX_GAP_S = 1.5  # a track picked up again later than this is not linked
REACH_FT = 5.0  # how far apart the end and the new start may be at once ...
SPEED_FTS = 14.0  # ... plus this much per second of gap (a fast run)
CLEAR_FACTOR = 1.6  # the next-best candidate must be this many times farther (plus CLEAR_MARGIN_FT)
CLEAR_MARGIN_FT = 1.5
PLAYER_HEIGHT_FT = 6.0  # ruler for films without court positions: a player's box is about this tall


@dataclass(frozen=True)
class _End:
    track_id: int
    team: int
    frame: int
    xy: tuple[float, float]
    feet: bool  # court feet (else pixels, with ``ruler`` pixels per PLAYER_HEIGHT_FT)
    ruler: float


def share_jersey_reads(tracking: TrackingResult) -> TrackingResult:
    """``tracking`` with every track carrying the jersey reads of the whole chain it belongs to."""
    chains = link_tracks(tracking)
    if not chains:
        return tracking
    by_id = {t.track_id: t for t in tracking.tracks}
    pooled: dict[int, list] = {}
    for linked in chains:
        for chain in _split_where_numbers_differ(linked, by_id):
            reads = sorted((r for tid in chain for r in by_id[tid].jersey_reads), key=lambda r: r.frame)
            if reads and len(chain) > 1:
                for tid in chain:
                    pooled[tid] = reads
    if not pooled:
        return tracking
    tracks = [t.model_copy(update={"jersey_reads": pooled[t.track_id]}) if t.track_id in pooled else t for t in tracking.tracks]
    logger.info("Stitching: %d chain(s) share jersey reads across %d track(s)", len(chains), len(pooled))
    return tracking.model_copy(update={"tracks": tracks})


def _split_where_numbers_differ(chain: list[int], by_id: dict[int, Track]) -> list[list[int]]:
    """A chain whose pieces read two different numbers is two players (a substitute stepping in where a
    teammate left, a wrong link): it is cut halfway between the two readings, so neither number
    spreads onto the other player."""
    from scout.roster.matcher import jersey_votes

    numbers: list[tuple[int, str]] = []  # (position in the chain, the number that piece read most)
    for position, tid in enumerate(chain):
        votes = jersey_votes(by_id[tid].jersey_reads)
        if votes:
            numbers.append((position, max(votes, key=lambda k: votes[k])))
    cuts = []
    for (a, first), (b, second) in zip(numbers, numbers[1:], strict=False):
        if first != second and first not in second and second not in first:  # "2" and "23" can be one jersey
            cuts.append((a + b + 1) // 2)
    pieces, start = [], 0
    for cut in cuts:
        pieces.append(chain[start:cut])
        start = cut
    pieces.append(chain[start:])
    return [piece for piece in pieces if piece]


def link_tracks(tracking: TrackingResult) -> list[list[int]]:
    """Chains of track ids (two or more, in time order) that are one player followed across breaks."""
    fps = tracking.video.fps
    max_gap = MAX_GAP_S * fps
    ends, starts = [], []
    for track in tracking.tracks:
        if track.role != "player" or track.team_id is None or not track.samples:
            continue
        ends.append(_end(track, last=True))
        starts.append(_end(track, last=False))
    starts.sort(key=lambda s: s.frame)
    frames = [s.frame for s in starts]

    import bisect

    forward: dict[int, list[tuple[float, int]]] = {}  # ending track -> [(cost, starting track)] best first
    backward: dict[int, list[tuple[float, int]]] = {}
    for end in ends:
        lo = bisect.bisect_right(frames, end.frame)
        hi = bisect.bisect_right(frames, end.frame + max_gap)
        for start in starts[lo:hi]:
            if start.team != end.team or start.track_id == end.track_id:
                continue
            cost = _distance_ft(end, start)
            gap_s = (start.frame - end.frame) / fps
            if cost is None or cost > REACH_FT + SPEED_FTS * gap_s:
                continue
            forward.setdefault(end.track_id, []).append((cost, start.track_id))
            backward.setdefault(start.track_id, []).append((cost, end.track_id))
    for options in (*forward.values(), *backward.values()):
        options.sort()

    following: dict[int, int] = {}
    for tid, options in forward.items():
        cost, nxt = options[0]
        back = backward[nxt]
        if back[0][1] == tid and _clear(options) and _clear(back):
            following[tid] = nxt
    followed = set(following.values())
    chains = []
    for head in following:
        if head in followed:
            continue
        chain, seen = [head], {head}
        while chain[-1] in following and following[chain[-1]] not in seen:
            chain.append(following[chain[-1]])
            seen.add(chain[-1])
        chains.append(chain)
    return chains


def _clear(options: list[tuple[float, int]]) -> bool:
    """The best candidate stands clearly apart from the next one."""
    return len(options) < 2 or options[1][0] >= options[0][0] * CLEAR_FACTOR + CLEAR_MARGIN_FT


def _end(track: Track, *, last: bool) -> _End:
    sample = track.samples[-1] if last else track.samples[0]
    x0, y0, x1, y1 = sample.bbox
    if sample.court_xy is not None:
        return _End(track.track_id, track.team_id, sample.f, (sample.court_xy[0], sample.court_xy[1]), True, 1.0)  # type: ignore[arg-type]
    return _End(track.track_id, track.team_id, sample.f, ((x0 + x1) / 2, y1), False, max(1.0, y1 - y0))  # type: ignore[arg-type]


def _distance_ft(a: _End, b: _End) -> float | None:
    """Feet between two track ends; None when one is in court feet and the other only in pixels."""
    if a.feet != b.feet:
        return None
    d = ((a.xy[0] - b.xy[0]) ** 2 + (a.xy[1] - b.xy[1]) ** 2) ** 0.5
    return d if a.feet else d * PLAYER_HEIGHT_FT / ((a.ruler + b.ruler) / 2)
