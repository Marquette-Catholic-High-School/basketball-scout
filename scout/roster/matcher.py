"""Jersey OCR -> roster player matching, tolerant of OCR errors.

Jersey OCR on game film is noisy: digits get confused (8/3/0/6/9, 1/7, 5/6/3, 2/7),
one digit of a two-digit number is often hidden by an arm or a fold ("23" read as
"2" or "3"), and single frames are wrong. Matching therefore works at the TRACK
level: every read on a track votes (weighted by OCR confidence), then the vote
distribution is matched against the roster of the track's team.
"""

from __future__ import annotations

from scout.schemas import JerseyRead, Roster, RosterPlayer, TeamSide, TrackAssignment, TrackingResult, TrackOverride

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


def normalize_jersey(text: str | None) -> str | None:
    """Clean an OCR/roster jersey string: keep up to 2 digits, map common letter/digit
    lookalikes (O->0, I/l/|->1, S->5, B->8, Z->2, G->6), drop everything else.
    Returns None when nothing digit-like remains. Preserves "0" vs "00"."""
    raise NotImplementedError


def jersey_similarity(read: str, jersey: str) -> tuple[float, str]:
    """Similarity in [0, 1] between an OCR read and a roster jersey, plus the method:
    ``exact`` (1.0), ``fuzzy`` (same length, digit confusions via DIGIT_CONFUSION),
    ``partial`` (one digit of a two-digit jersey visible, ~0.45; or reversed digits ~0.3)."""
    raise NotImplementedError


def jersey_votes(reads: list[JerseyRead], *, min_conf: float = 0.2) -> dict[str, float]:
    """Confidence-weighted vote per normalised read (reads below ``min_conf`` ignored)."""
    raise NotImplementedError


def match_votes(votes: dict[str, float], roster: Roster) -> tuple[RosterPlayer | None, float, str]:
    """Best roster player for a vote distribution: score = sum(vote * similarity) /
    sum(votes); returns ``(player, score, method)``. ``(None, 0.0, "none")`` for no votes,
    ``(None, score, "unrostered")`` when the best score is below the acceptance threshold
    (default 0.5) or the roster is empty."""
    raise NotImplementedError


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
    * Conflict resolution: two tracks that overlap in time cannot be the same player.
      When they do, the lower-scoring track falls back to its next-best candidate or
      becomes ``unrostered`` (keeping ``best_read`` as its jersey).
    * ``frames`` = number of samples; ``jersey`` = matched roster jersey, else best read.
    """
    raise NotImplementedError


def match_name(query: str, roster: Roster, *, threshold: float = 80.0) -> tuple[RosterPlayer | None, float]:
    """Fuzzy name lookup (rapidfuzz token-sort ratio, 0-100) for manual corrections."""
    raise NotImplementedError
