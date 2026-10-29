"""Timeline -> per-player box score lines and team totals.

Who gets the stat: the row's ``player`` -- by roster ``player_id`` when matched, else by
(side, jersey) for jerseys that are not on the roster, else the team's
``team_unattributed`` line. The team is always the row's ``side``.

Minutes and plus-minus come from track presence, measured on the raw samples:
consecutive samples less than ``index.max_gap_frames`` apart count as on the floor
(so thinned samples still count fully, and long gaps do not). With court coordinates,
samples placed more than ``ON_FLOOR_MARGIN_FT`` outside the lines do not count: a player
tracked while sitting on the bench or waiting at the table is not on the floor.
"""

from __future__ import annotations

from bisect import bisect_right

from scout.analysis.events import DEFAULT_TEAM_NAMES
from scout.analysis.tracking_index import TrackingIndex
from scout.schemas import (
    BoxScoreLine,
    EventType,
    PlayerRef,
    Possession,
    Roster,
    ShotZone,
    TeamBoxScore,
    TeamSide,
    TimelineEvent,
    TrackAssignment,
)

COUNTING_FIELDS = ("pts", "fgm", "fga", "tpm", "tpa", "ftm", "fta", "oreb", "dreb", "ast", "stl", "blk", "tov", "pf")
_SIMPLE_STATS = {
    EventType.OREB: "oreb",
    EventType.DREB: "dreb",
    EventType.ASSIST: "ast",
    EventType.STEAL: "stl",
    EventType.BLOCK: "blk",
    EventType.TURNOVER: "tov",
    EventType.FOUL: "pf",
}
_SHOTS = frozenset({EventType.SHOT_MADE, EventType.SHOT_MISSED})
_FREE_THROWS = frozenset({EventType.FT_MADE, EventType.FT_MISSED})

LineKey = tuple[str, str]  # ("p", player_id) or ("j", jersey)
Scoring = list[tuple[int, TeamSide, int]]  # (frame, scoring side, points)
ON_FLOOR_MARGIN_FT = 4.0  # an inbounder stands just outside the lines; the bench is further back


def build_box_scores(
    timeline: list[TimelineEvent],
    possessions: list[Possession],
    assignments: list[TrackAssignment],
    rosters: dict[TeamSide, Roster],
    team_names: dict[TeamSide, str],
    index: TrackingIndex | None = None,
) -> list[TeamBoxScore]:
    """One ``TeamBoxScore`` per side (SCOUTED first).

    * Every roster player appears (zero line if no events), sorted by jersey, followed by
      unrostered jerseys with at least one stat row (``PlayerRef`` without ``player_id``).
    * Events whose player is unknown count toward ``team_unattributed``; ``totals`` is the
      sum of players + unattributed.
    * PTS/FGM/FGA/3PM/3PA from SHOT_* rows (``points``/``is_three``), FTM/FTA from FT rows,
      OREB/DREB, AST, STL, BLK, TOV, PF from their rows. Zone splits from ``zone``.
    * ``minutes_est`` from track presence (``index``) summed over the player's tracks,
      in video minutes (0.0 for a roster player never seen). ``plus_minus`` from scoring
      while the player's tracks were present (None without an index or without tracks).
    * ``possessions``/``points_per_possession`` from ``possessions``.
    """
    presence = _Presence(index) if index is not None else None
    scoring: Scoring = [(r.frame, r.side, r.points) for r in timeline if r.points and r.side is not None]
    boxes = []
    for side in (TeamSide.SCOUTED, TeamSide.OTHER):
        roster = rosters.get(side)
        name = team_names.get(side) or (roster.team_name if roster else "") or DEFAULT_TEAM_NAMES[side]
        box = _team_box(side, name, timeline, roster, assignments, presence, scoring)
        box.possessions = sum(1 for p in possessions if p.side == side)
        if box.possessions:
            box.points_per_possession = round(box.totals.pts / box.possessions, 3)
        boxes.append(box)
    return boxes


def _team_box(
    side: TeamSide,
    team_name: str,
    timeline: list[TimelineEvent],
    roster: Roster | None,
    assignments: list[TrackAssignment],
    presence: _Presence | None,
    scoring: Scoring,
) -> TeamBoxScore:
    best_scores = _best_match_scores(assignments, side)
    lines: dict[LineKey, BoxScoreLine] = {}
    for p in sorted(roster.players if roster else [], key=lambda p: jersey_sort_key(p.jersey)):
        ref = PlayerRef(player_id=p.id, jersey=p.jersey, name=p.name or None, side=side,
                        match_confidence=best_scores.get(p.id, 0.0))
        lines[("p", p.id)] = BoxScoreLine(player=ref)
    unattributed = BoxScoreLine(player=PlayerRef(name="Team", side=side))

    for row in timeline:
        if row.side != side:
            continue
        line = _line_for(row.player, side, lines, unattributed)
        if line is not None:
            _apply(line, row)

    rostered = [line for key, line in lines.items() if key[0] == "p"]
    unrostered = sorted((k for k in lines if k[0] == "j"), key=lambda k: jersey_sort_key(k[1]))
    players = rostered + [lines[k] for k in unrostered]
    if presence is not None:
        tracks = _tracks_by_line(assignments, side, lines)
        for key, line in lines.items():
            line.minutes_est = presence.minutes(tracks.get(key, []))
            line.plus_minus = presence.plus_minus(tracks[key], side, scoring) if key in tracks else None

    totals = BoxScoreLine(player=PlayerRef(name=team_name, side=side))
    for line in [*players, unattributed]:
        _accumulate(totals, line)
    return TeamBoxScore(side=side, team_name=team_name, players=players, team_unattributed=unattributed, totals=totals)


def _line_for(
    ref: PlayerRef | None, side: TeamSide, lines: dict[LineKey, BoxScoreLine], unattributed: BoxScoreLine
) -> BoxScoreLine:
    if ref is not None and ref.player_id and ("p", ref.player_id) in lines:
        return lines[("p", ref.player_id)]
    if ref is not None and ref.jersey:
        key = ("j", ref.jersey)
        if key not in lines:
            lines[key] = BoxScoreLine(player=PlayerRef(jersey=ref.jersey, side=side, match_confidence=0.0))
        return lines[key]
    return unattributed


def _apply(line: BoxScoreLine, row: TimelineEvent) -> None:
    """Add one timeline row's stats to a line (rows that are not stats are ignored)."""
    if row.type in _SHOTS:
        made = row.type == EventType.SHOT_MADE
        line.fga += 1
        line.fgm += int(made)
        line.pts += row.points
        if row.is_three:
            line.tpa += 1
            line.tpm += int(made)
        split = getattr(line.zones, (row.zone or ShotZone.UNKNOWN).value)
        split.attempts += 1
        split.made += int(made)
    elif row.type in _FREE_THROWS:
        line.fta += 1
        line.ftm += int(row.type == EventType.FT_MADE)
        line.pts += row.points
    elif row.type in _SIMPLE_STATS:
        attr = _SIMPLE_STATS[row.type]
        setattr(line, attr, getattr(line, attr) + 1)


def _accumulate(total: BoxScoreLine, line: BoxScoreLine) -> None:
    for name in COUNTING_FIELDS:
        setattr(total, name, getattr(total, name) + getattr(line, name))
    for zone in ShotZone:
        target, source = getattr(total.zones, zone.value), getattr(line.zones, zone.value)
        target.made += source.made
        target.attempts += source.attempts


def jersey_sort_key(jersey: str | None) -> tuple[int, int, str]:
    """Numeric jersey order; "0" before "00" before "1"; non-numeric last."""
    text = jersey or ""
    return (int(text), len(text), text) if text.isdigit() else (10**6, len(text), text)


def _best_match_scores(assignments: list[TrackAssignment], side: TeamSide) -> dict[str, float]:
    best: dict[str, float] = {}
    for a in assignments:
        if a.player_id and a.side == side and not a.ignored:
            best[a.player_id] = max(best.get(a.player_id, 0.0), a.match_score)
    return best


def _tracks_by_line(
    assignments: list[TrackAssignment], side: TeamSide, lines: dict[LineKey, BoxScoreLine]
) -> dict[LineKey, list[int]]:
    tracks: dict[LineKey, list[int]] = {}
    for a in assignments:
        if a.ignored or a.role != "player" or a.side != side:
            continue
        key: LineKey | None = None
        if a.player_id and ("p", a.player_id) in lines:
            key = ("p", a.player_id)
        elif not a.player_id and a.jersey and ("j", a.jersey) in lines:
            key = ("j", a.jersey)
        if key is not None:
            tracks.setdefault(key, []).append(a.track_id)
    return tracks


class _Presence:
    """On-floor frame intervals per track, from the raw track samples."""

    def __init__(self, index: TrackingIndex) -> None:
        self.index = index
        self.fps = index.fps
        self.step = index.step
        self.max_gap = index.max_gap_frames
        self.duration_s = index.tracking.video.duration_s
        self._tracks = {t.track_id: t for t in index.tracking.tracks}
        self._intervals: dict[int, list[tuple[int, int]]] = {}

    def intervals(self, track_id: int) -> list[tuple[int, int]]:
        if track_id not in self._intervals:
            track = self._tracks.get(track_id)
            frames = sorted(s.f for s in track.samples) if track is not None else []
            off = self._off_floor(track_id)
            if off:
                frames = [f for f in frames if f not in off]
            self._intervals[track_id] = _runs(frames, self.max_gap, self.step)
        return self._intervals[track_id]

    def _off_floor(self, track_id: int) -> set[int]:
        """Frames at which the track's court position is known and well outside the lines."""
        if self.index.coord_mode != "court":
            return set()
        frames, xy = self.index.placed_samples(track_id)
        court, margin = self.index.court, ON_FLOOR_MARGIN_FT
        x, y = xy[:, 0], xy[:, 1]
        off = (x < -margin) | (x > court.length_ft + margin) | (y < -margin) | (y > court.width_ft + margin)
        return set(frames[off].tolist())

    def minutes(self, track_ids: list[int]) -> float:
        merged = _merge([iv for tid in track_ids for iv in self.intervals(tid)])
        seconds = sum(end - start for start, end in merged) / self.fps
        if self.duration_s > 0:
            seconds = min(seconds, self.duration_s)
        return round(seconds / 60.0, 1)

    def plus_minus(self, track_ids: list[int], side: TeamSide, scoring: Scoring) -> int:
        merged = _merge([iv for tid in track_ids for iv in self.intervals(tid)])
        starts = [start for start, _ in merged]
        total = 0
        for frame, scorer, points in scoring:
            i = bisect_right(starts, frame) - 1
            if i >= 0 and frame <= merged[i][1]:
                total += points if scorer == side else -points
        return total


def _runs(frames: list[int], max_gap: int, step: int) -> list[tuple[int, int]]:
    """Group sorted sample frames into (start, end) runs; each sample covers ``step`` frames."""
    runs: list[tuple[int, int]] = []
    last = 0
    for f in frames:
        if runs and f - last <= max_gap:
            runs[-1] = (runs[-1][0], f + step)
        else:
            runs.append((f, f + step))
        last = f
    return runs


def _merge(intervals: list[tuple[int, int]]) -> list[tuple[int, int]]:
    merged: list[tuple[int, int]] = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged
