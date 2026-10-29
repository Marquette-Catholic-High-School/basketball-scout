"""Jersey OCR -> roster player matching, tolerant of OCR errors.

Jersey OCR on game film is noisy: digits get confused (8/3/0/6/9, 1/7, 5/6/3, 2/7),
one digit of a two-digit number is often hidden by an arm or a fold ("23" read as
"2" or "3"), and single frames are wrong. Matching therefore works at the TRACK
level: every read on a track votes (weighted by OCR confidence), then the vote
distribution is matched against the roster of the track's team.

The tracker also splits one player into several tracks (after occlusions, or when
the player leaves the frame), so several tracks may resolve to the same player as
long as they are not on screen at the same time. "On screen" is judged from the
samples, not from a track's first and last frame: a ReID track spans the whole game
with the player on the bench in between.
"""

from __future__ import annotations

import logging
import math
import re
from collections import defaultdict
from dataclasses import dataclass
from functools import lru_cache

from rapidfuzz import fuzz, utils

from scout.schemas import (
    JerseyRead,
    Roster,
    RosterPlayer,
    TeamSide,
    Track,
    TrackAssignment,
    TrackingResult,
    TrackOverride,
)

logger = logging.getLogger(__name__)

# Pairs of digits commonly confused by OCR on jerseys, with a similarity in [0, 1].
DIGIT_CONFUSION: dict[frozenset[str], float] = {
    frozenset({"0", "8"}): 0.7,
    frozenset({"3", "8"}): 0.7,
    frozenset({"6", "8"}): 0.6,
    frozenset({"9", "8"}): 0.55,
    frozenset({"0", "6"}): 0.55,
    frozenset({"0", "9"}): 0.5,
    frozenset({"1", "7"}): 0.7,
    frozenset({"1", "4"}): 0.4,
    frozenset({"5", "6"}): 0.55,
    frozenset({"5", "3"}): 0.5,
    frozenset({"5", "8"}): 0.4,
    frozenset({"2", "7"}): 0.45,
    frozenset({"2", "5"}): 0.35,
    frozenset({"3", "9"}): 0.4,
    frozenset({"4", "9"}): 0.35,
    frozenset({"0", "2"}): 0.3,
}

# Letters OCR returns in place of digits. Only applied to text that looks like a number.
LOOKALIKES: dict[str, str] = {
    "O": "0", "o": "0", "I": "1", "l": "1", "|": "1", "!": "1", "S": "5", "s": "5",
    "B": "8", "Z": "2", "z": "2", "G": "6", "T": "7", "A": "4",
}  # fmt: skip
MAX_JERSEY_DIGITS = 2
ACCEPT_SCORE = 0.5  # minimum match score for a roster player
MIN_READ_CONF = 0.2  # OCR reads below this confidence do not vote
LEADING_ZERO_SIMILARITY = 0.9  # "05" vs "5"
PARTIAL_FIRST_DIGIT = 0.45  # read "2" for jersey 23 (the second digit hidden)
PARTIAL_LAST_DIGIT = 0.4  # read "3" for jersey 23 (slightly less likely: prefer 23 over 32 for "2")
REVERSED_SIMILARITY = 0.3  # read "32" for jersey 23
MAX_SHARED_SCREEN_TIME_S = 1.0  # tracks overlapping longer than this cannot be the same player
NAME_MATCH_THRESHOLD = 80.0

_DIGITS = frozenset("0123456789")
_TOKEN_SEPARATORS = re.compile(r"[^0-9A-Za-z|!]+")


@dataclass(frozen=True)
class _Candidate:
    """A roster player a track's votes could belong to."""

    player: RosterPlayer
    side: TeamSide
    score: float
    exact_share: float  # share of the votes that read exactly this jersey (tie-break)
    method: str  # how the strongest evidence matched: exact / fuzzy / partial


@dataclass(frozen=True)
class _Pending:
    """A track waiting for conflict resolution, with its acceptable candidates best first."""

    index: int
    base: TrackAssignment
    presence: list[tuple[int, int]]  # frame ranges the track is on screen
    candidates: list[_Candidate]

    @property
    def priority(self) -> float:
        """Confident, long tracks choose first: score x log(1 + frames)."""
        return self.candidates[0].score * math.log1p(self.base.frames)


@lru_cache(maxsize=4096)  # pure function, and the same OCR strings repeat thousands of times
def normalize_jersey(text: str | None) -> str | None:
    """Clean an OCR/roster jersey string: keep up to 2 digits, map common letter/digit
    lookalikes (O->0, I/l/|->1, S->5, B->8, Z->2, G->6), drop everything else.
    Returns None when nothing digit-like remains. Preserves "0" vs "00".

    Lookalikes (also !->1, T->7, A->4) are mapped only inside a word that contains a
    real digit ("2B" -> "28", "l2" -> "12") or in a word of 1-2 characters made only of
    lookalikes ("O" -> "0", "lO" -> "10"); other words ("No.", "EAGLES") are dropped and
    the digits of the remaining words are joined ("2 3" -> "23"). Leading zeros are kept
    ("05"). Reads that end up with 3+ digits return None: a basketball jersey has at
    most two digits, so a longer read means OCR merged in a stripe, a logo or another
    player's number, and guessing which two digits are real would add wrong votes.
    """
    if text is None:
        return None
    digits: list[str] = []
    for word in _TOKEN_SEPARATORS.split(str(text)):
        if any(char in _DIGITS for char in word):
            digits.extend(char if char in _DIGITS else LOOKALIKES.get(char, "") for char in word)
        elif 0 < len(word) <= MAX_JERSEY_DIGITS and all(char in LOOKALIKES for char in word):
            digits.extend(LOOKALIKES[char] for char in word)
    jersey = "".join(digits)
    return jersey if 0 < len(jersey) <= MAX_JERSEY_DIGITS else None


@lru_cache(maxsize=4096)  # pure function of two short strings, called per read x roster player
def jersey_similarity(read: str, jersey: str) -> tuple[float, str]:
    """Similarity in [0, 1] between an OCR read and a roster jersey, plus the method:
    ``exact`` (1.0), ``fuzzy`` (same length, digit confusions via DIGIT_CONFUSION),
    ``partial`` (one digit of a two-digit jersey visible, ~0.45; or reversed digits ~0.3).

    Both strings are normalised first. Leading zeros are nearly equivalent ("05" vs "5"
    -> 0.9, ``fuzzy``) but "0" and "00" are different numbers. Same-length numbers score
    the product of their per-digit similarities ("28" vs "23" -> 0.7). A single digit
    read for a two-digit jersey scores 0.45 when it is the first digit and 0.4 when it is
    the last, times the digit similarity. Everything else (e.g. a read longer than the
    jersey) scores ``(0.0, "none")``.
    """
    read_digits, jersey_digits = normalize_jersey(read), normalize_jersey(jersey)
    if read_digits is None or jersey_digits is None:
        return 0.0, "none"
    if read_digits == jersey_digits:
        return 1.0, "exact"
    if read_digits.lstrip("0") and read_digits.lstrip("0") == jersey_digits.lstrip("0"):
        return LEADING_ZERO_SIMILARITY, "fuzzy"
    if len(read_digits) == len(jersey_digits):
        fuzzy = math.prod(_digit_similarity(a, b) for a, b in zip(read_digits, jersey_digits, strict=True))
        if read_digits == jersey_digits[::-1] and REVERSED_SIMILARITY > fuzzy:
            return REVERSED_SIMILARITY, "partial"
        return (round(fuzzy, 4), "fuzzy") if fuzzy > 0 else (0.0, "none")
    if len(read_digits) == 1 and len(jersey_digits) == 2:
        partial = max(
            PARTIAL_FIRST_DIGIT * _digit_similarity(read_digits, jersey_digits[0]),
            PARTIAL_LAST_DIGIT * _digit_similarity(read_digits, jersey_digits[1]),
        )
        return (round(partial, 4), "partial") if partial > 0 else (0.0, "none")
    return 0.0, "none"


def jersey_votes(reads: list[JerseyRead], *, min_conf: float = MIN_READ_CONF) -> dict[str, float]:
    """Confidence-weighted vote per normalised read (reads below ``min_conf`` ignored).

    The result is ordered by vote, strongest first.
    """
    totals: dict[str, float] = defaultdict(float)
    for read in reads:
        if read.conf < min_conf:
            continue
        jersey = normalize_jersey(read.text)
        if jersey is not None:
            totals[jersey] += read.conf
    ordered = sorted(totals.items(), key=lambda item: (-item[1], item[0]))
    return {jersey: round(vote, 4) for jersey, vote in ordered}


def match_votes(
    votes: dict[str, float], roster: Roster, *, accept: float = ACCEPT_SCORE
) -> tuple[RosterPlayer | None, float, str]:
    """Best roster player for a vote distribution: score = sum(vote * similarity) /
    sum(votes); returns ``(player, score, method)``. ``(None, 0.0, "none")`` for no votes,
    ``(None, score, "unrostered")`` when the best score is below the acceptance threshold
    (default 0.5) or the roster is empty.

    Ties are broken by the share of votes that read the jersey exactly, then by roster
    order. ``method`` is how the read contributing most to the score matched.
    """
    if sum(votes.values()) <= 0:
        return None, 0.0, "none"
    ranked = _rank_candidates(votes, [(player, roster.side) for player in roster.players])
    if not ranked:
        return None, 0.0, "unrostered"
    best = ranked[0]
    if best.score < accept:
        return None, best.score, "unrostered"
    return best.player, best.score, best.method


def assign_tracks(
    tracking: TrackingResult,
    team_map: dict[int, TeamSide],
    rosters: dict[TeamSide, Roster],
    overrides: list[TrackOverride] | None = None,
) -> list[TrackAssignment]:
    """One ``TrackAssignment`` per track (players and referees).

    * Referees -> ``role="referee"``, never matched.
    * Overrides win (``method="manual"``; ``ignore=True`` -> ``ignored=True``).
    * Otherwise match each track's votes against its side's roster.
    * Conflict resolution: two tracks on screen at the same time cannot be the same
      player. When they are, the lower-priority track falls back to its next-best
      candidate or becomes ``unrostered`` (keeping ``best_read`` as its jersey).
    * ``frames`` = number of samples; ``jersey`` = matched roster jersey, else best read.

    Details: an override is applied even to a track the pipeline called a referee (the
    coach has the final word); an override naming a player who is no longer on a roster
    is ignored. A track whose team id is missing from ``team_map`` is matched against both
    rosters and takes the side of the better match; an exact tie between the two teams'
    players leaves it unrostered rather than guessing. Tracks choose in order of
    score x log(1 + frames), and every track's best candidate is settled before any
    track falls back to a weaker one, so a fallback guess never takes a player from a
    track that read that player's number. Two tracks conflict when they are on screen
    together (from their samples; gaps over ``MAX_SHARED_SCREEN_TIME_S`` are absences)
    for longer than ``MAX_SHARED_SCREEN_TIME_S`` (shorter overlaps are tracker
    hand-overs), so fragments and ReID ids of one player that are never on screen
    together all match the same player. Unrostered tracks score the vote share of their
    best read. Assignments come back in ``tracking.tracks`` order.
    """
    video = tracking.video
    tolerance_frames = MAX_SHARED_SCREEN_TIME_S * video.fps
    max_gap = max(tolerance_frames, 2 * video.fps / video.analysis_fps)  # never below two sample steps
    overrides_by_track = {override.track_id: override for override in overrides or []}
    results: dict[int, TrackAssignment] = {}
    on_screen: dict[str, list[list[tuple[int, int]]]] = defaultdict(list)  # player id -> presence of its tracks
    pending: list[_Pending] = []

    for index, track in enumerate(tracking.tracks):
        base = _base_assignment(track, team_map)
        override = overrides_by_track.get(track.track_id)
        manual = _apply_override(base, override, rosters) if override else None
        if manual is not None:
            results[index] = manual
            if manual.player_id:
                on_screen[manual.player_id].append(_presence(track, max_gap))
        elif track.role == "referee":
            results[index] = base.model_copy(update={"side": None})
        elif candidates := _acceptable_candidates(base, rosters):
            presence = _presence(track, max_gap)
            pending.append(_Pending(index=index, base=base, presence=presence, candidates=candidates))
        else:
            results[index] = _unrostered(base)

    ranked = sorted(pending, key=lambda p: (-p.priority, p.base.track_id))
    for rank in range(max((len(item.candidates) for item in ranked), default=0)):
        for item in ranked:  # round ``rank``: each still unmatched track tries its next candidate
            if item.index in results or rank >= len(item.candidates):
                continue
            choice = item.candidates[rank]
            if not any(_overlaps(item.presence, other, tolerance_frames) for other in on_screen[choice.player.id]):
                on_screen[choice.player.id].append(item.presence)
                results[item.index] = _matched(item.base, choice)
    for item in ranked:
        if item.index not in results:
            results[item.index] = _unrostered(item.base)

    assignments = [results[index] for index in range(len(tracking.tracks))]
    matched = sum(1 for a in assignments if a.player_id)
    logger.info("Jersey matching: %d of %d tracks matched to a roster player", matched, len(assignments))
    return assignments


def match_name(
    query: str, roster: Roster, *, threshold: float = NAME_MATCH_THRESHOLD
) -> tuple[RosterPlayer | None, float]:
    """Fuzzy name lookup (rapidfuzz token-sort ratio, 0-100) for manual corrections.

    Compares against each player's name and FastScout name, ignoring case, punctuation
    and word order ("Smith, John" == "John Smith"). Returns ``(None, best_score)`` when
    nothing reaches ``threshold``.
    """
    cleaned = " ".join(query.split())
    best: RosterPlayer | None = None
    best_score = 0.0
    if cleaned:
        for player in roster.players:
            for candidate in (player.name, player.fastscout_name):
                if not candidate:
                    continue
                score = fuzz.token_sort_ratio(cleaned, candidate, processor=utils.default_process)
                if score > best_score:
                    best, best_score = player, score
    if best is None or best_score < threshold:
        return None, round(best_score, 1)
    return best, round(best_score, 1)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _digit_similarity(a: str, b: str) -> float:
    return 1.0 if a == b else DIGIT_CONFUSION.get(frozenset((a, b)), 0.0)


def _rank_candidates(votes: dict[str, float], pool: list[tuple[RosterPlayer, TeamSide]]) -> list[_Candidate]:
    """Every player in ``pool`` with a positive score, best first (stable for ties)."""
    total = sum(votes.values())
    if total <= 0:
        return []
    candidates: list[_Candidate] = []
    for player, side in pool:
        weighted = exact = strongest = 0.0
        method = "none"
        for read, vote in votes.items():
            similarity, how = jersey_similarity(read, player.jersey)
            evidence = vote * similarity
            weighted += evidence
            if how == "exact":
                exact += vote
            if evidence > strongest:
                strongest, method = evidence, how
        if weighted > 0:
            candidates.append(_Candidate(player, side, round(weighted / total, 4), round(exact / total, 4), method))
    candidates.sort(key=lambda c: (-c.score, -c.exact_share))
    return candidates


def _base_assignment(track: Track, team_map: dict[int, TeamSide]) -> TrackAssignment:
    """Votes, side and presence for a track, before any roster matching."""
    votes = jersey_votes(track.jersey_reads)
    side = team_map.get(track.team_id) if track.team_id is not None else None
    return TrackAssignment(
        track_id=track.track_id,
        team_id=track.team_id,
        side=TeamSide(side) if side is not None else None,
        role=track.role,
        best_read=_best_read(votes),
        votes=votes,
        frames=len(track.samples),
    )


def _best_read(votes: dict[str, float]) -> str | None:
    """Strongest read; on a tie the fuller one ("23" over "2")."""
    if not votes:
        return None
    return max(votes, key=lambda read: (votes[read], len(read)))


def _acceptable_candidates(base: TrackAssignment, rosters: dict[TeamSide, Roster]) -> list[_Candidate]:
    """Candidates scoring at least ACCEPT_SCORE on the track's side (both sides when unknown)."""
    sides = [base.side] if base.side is not None else list(TeamSide)
    pool = [(player, side) for side in sides if side in rosters for player in rosters[side].players]
    candidates = [c for c in _rank_candidates(base.votes, pool) if c.score >= ACCEPT_SCORE]
    if base.side is None and candidates:
        best = candidates[0]
        if any(c.side != best.side and (c.score, c.exact_share) == (best.score, best.exact_share) for c in candidates):
            return []  # e.g. both teams have a #23 and we do not know this track's team
    return candidates


def _apply_override(
    base: TrackAssignment, override: TrackOverride, rosters: dict[TeamSide, Roster]
) -> TrackAssignment | None:
    """The coach's correction for one track; None when it names a player no longer on a roster."""
    side = override.side or base.side
    if override.ignore:
        return base.model_copy(update={"ignored": True, "method": "manual", "side": side})
    if override.player_id is None:  # explicitly "not a roster player", keeping (or setting) the side
        return base.model_copy(update={"side": side, "jersey": base.best_read, "method": "manual"})
    for side, roster in rosters.items():
        player = roster.by_id(override.player_id)
        if player is not None:
            return base.model_copy(
                update={
                    "player_id": player.id,
                    "side": TeamSide(side),
                    "jersey": player.jersey,
                    "role": "player",
                    "match_score": 1.0,
                    "method": "manual",
                }
            )
    logger.warning("Override for track %s names a player no longer on a roster; matching automatically", base.track_id)
    return None


def _matched(base: TrackAssignment, choice: _Candidate) -> TrackAssignment:
    return base.model_copy(
        update={
            "player_id": choice.player.id,
            "side": choice.side,
            "jersey": choice.player.jersey,
            "role": "player",
            "match_score": choice.score,
            "method": choice.method,
        }
    )


def _unrostered(base: TrackAssignment) -> TrackAssignment:
    """No roster player: show the best OCR read, scored by how dominant that read is."""
    if base.best_read is None:
        return base
    share = base.votes[base.best_read] / sum(base.votes.values())
    return base.model_copy(update={"jersey": base.best_read, "match_score": round(share, 4), "method": "unrostered"})


def _presence(track: Track, max_gap: float) -> list[tuple[int, int]]:
    """Frame ranges the track is on screen: samples more than ``max_gap`` frames apart start a new range."""
    ranges: list[tuple[int, int]] = []
    for frame in sorted(sample.f for sample in track.samples):
        if ranges and frame - ranges[-1][1] <= max_gap:
            ranges[-1] = (ranges[-1][0], frame)
        else:
            ranges.append((frame, frame))
    return ranges


def _overlaps(a: list[tuple[int, int]], b: list[tuple[int, int]], tolerance_frames: float) -> bool:
    """True when two tracks are on screen together for more than ``tolerance_frames`` at a stretch."""
    i = j = 0
    while i < len(a) and j < len(b):
        if min(a[i][1], b[j][1]) - max(a[i][0], b[j][0]) > tolerance_frames:
            return True
        if a[i][1] < b[j][1]:
            i += 1
        else:
            j += 1
    return False
