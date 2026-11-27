"""Split a film into overlapping pieces for several GPUs, and join their tracking again.

OpenHoopVision analyses one frame after another, so a whole game on one GPU takes about as
long as the game itself (a 75-minute film took 95 minutes on an A10G). Pieces of the film
are analysed at the same time on several GPUs, and their raw OHV output (one JSON record per
analysed frame) is joined into one file *before* anything else reads it: the adapter, the
event detectors, the possession and period logic then see one film, exactly as if a single
GPU had analysed it.

Each piece **owns** a stretch of the film and also analyses ``overlap_s / 2`` seconds on each
side of it, so

* the tracker and the team colours have settled before the piece's own stretch starts,
* an event that starts near the end of a stretch (a shot, a pass) is seen whole by the piece
  that owns its start, and
* the two pieces at a cut both see the frames around it, so a player's track is carried
  across the cut: the boxes of the same player match there, frame for frame.

The join keeps each piece's own frames, gives every player one id on the whole film (a track
linked across a cut keeps its id; the others get new ones), keeps an event in the piece that
owns its first frame, and makes the team labels agree (OHV labels the darker team 0 in each
piece; a piece where the linked players say otherwise is relabelled).

Frames here are 0-based frames of the analysis copy (OHV's records count from 1). Pure Python
on purpose: this module runs where only ``modal`` is installed.
"""

from __future__ import annotations

import gzip
import json
import logging
import math
import os
from collections import Counter, defaultdict
from collections.abc import Iterator, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import IO, Any

logger = logging.getLogger(__name__)

DEFAULT_PIECE_S = 600.0  # about ten minutes of film per GPU
DEFAULT_MAX_PIECES = 8
DEFAULT_OVERLAP_S = 20.0  # analysed by both pieces at a cut: 10 s lead-in, 10 s run-out
MIN_PIECE_S = 120.0  # shorter pieces would spend more time starting a GPU than analysing

# Linking tracks across a cut.
LINK_MIN_IOU = 0.5  # boxes of the same player in the same frame overlap almost entirely
LINK_MIN_FRAMES = 8  # frames in which the two boxes must match
LINK_MIN_SHARE = 0.5  # ... and at least this share of the frames both tracks are in the overlap
MAX_FRAME_SHIFT = 2  # a cut that starts a frame or two off is found and corrected
TEAM_VOTE_MIN_LINKS = 3  # linked players needed to decide the team labels by vote
WEAK_JOIN_LINKS = 3  # fewer linked players at a cut with players on both sides: warn

LOCAL_ID_BLOCK = 10_000_000  # OHV's per-piece local track ids, kept apart: piece * block + id
_EVENT_PLAYER_FIELDS = ("player_id", "receiver_id", "assister", "gained_by")


@dataclass(frozen=True)
class PieceSpec:
    """One piece: the frames it analyses and the frames it owns (``end`` None: to the end)."""

    index: int
    start: int
    end: int | None
    own_start: int
    own_end: int | None

    @property
    def frames(self) -> int | None:
        """Frames to cut for the piece (None: everything from ``start``)."""
        return None if self.end is None else self.end - self.start

    @property
    def whole_film(self) -> bool:
        return self.start == 0 and self.end is None

    def owns(self, frame: int) -> bool:
        return frame >= self.own_start and (self.own_end is None or frame < self.own_end)

    def to_dict(self) -> dict[str, Any]:
        return {
            "index": self.index,
            "start": self.start,
            "end": self.end,
            "own_start": self.own_start,
            "own_end": self.own_end,
        }

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> PieceSpec:
        def opt(key: str) -> int | None:
            return None if raw.get(key) is None else int(raw[key])

        return cls(int(raw["index"]), int(raw["start"]), opt("end"), int(raw["own_start"]), opt("own_end"))


def piece_count(duration_s: float, *, piece_s: float, max_pieces: int, overlap_s: float) -> int:
    """How many pieces: one per ``piece_s`` of film, at most ``max_pieces``, none too short."""
    if duration_s <= 0 or max_pieces <= 1 or piece_s <= 0:
        return 1
    wanted = math.ceil(duration_s / piece_s)
    shortest = max(MIN_PIECE_S, 3.0 * overlap_s)
    return max(1, min(max_pieces, wanted, int(duration_s // shortest)))


def plan_pieces(
    frames: int,
    fps: float,
    *,
    piece_s: float = DEFAULT_PIECE_S,
    max_pieces: int = DEFAULT_MAX_PIECES,
    overlap_s: float = DEFAULT_OVERLAP_S,
) -> list[PieceSpec]:
    """Equal pieces of the ``frames``-frame analysis copy. The last piece runs to the end of the
    file (its real frame count can differ a little from the expected one)."""
    frames = max(1, int(frames))
    count = piece_count(frames / fps if fps > 0 else 0.0, piece_s=piece_s, max_pieces=max_pieces, overlap_s=overlap_s)
    if count == 1:
        return [PieceSpec(0, 0, None, 0, None)]
    half = max(1, round(overlap_s * fps / 2))
    bounds = [round(i * frames / count) for i in range(count + 1)]
    pieces = []
    for i in range(count):
        last = i == count - 1
        own_start, own_end = bounds[i], None if last else bounds[i + 1]
        start = max(0, own_start - half)
        end = None if last else min(frames, bounds[i + 1] + half)
        pieces.append(PieceSpec(i, start, end, own_start, own_end))
    return pieces


def build_cut_command(src: str, dst: str, piece: PieceSpec, fps_rational: str) -> list[str]:
    """ffmpeg command cutting ``piece`` out of the analysis copy, frame-exact.

    The seek decodes from the keyframe before and drops every frame earlier than the seek
    point, which sits half a frame before ``piece.start``, so the first frame out is frame
    ``start``. Frames pass through unchanged in number (``-fps_mode passthrough``). The join
    still checks the cut against the piece before it (``MAX_FRAME_SHIFT``).
    """
    rate = _rate(fps_rational)
    cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
    if piece.start > 0:
        cmd += ["-ss", f"{(piece.start - 0.5) / rate:.6f}"]
    cmd += ["-i", src, "-map", "0:v:0", "-an", "-sn", "-dn", "-fps_mode", "passthrough"]
    if piece.frames is not None:
        cmd += ["-frames:v", str(piece.frames)]
    cmd += ["-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18"]
    cmd += ["-progress", "pipe:1", "-nostats", dst]
    return cmd


def build_concat_command(list_file: str, dst: str) -> list[str]:
    """ffmpeg command joining the pieces' web videos (same encoder settings) without re-encoding."""
    return [
        "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
        "-f", "concat", "-safe", "0", "-i", list_file,
        "-map", "0:v:0", "-c", "copy", "-movflags", "+faststart", dst,
    ]  # fmt: skip


def concat_list(paths: Sequence[str | os.PathLike[str]]) -> str:
    """The concat demuxer's list file for ``paths``."""
    lines = []
    for path in paths:
        quoted = str(path).replace("'", "'\\''")
        lines.append(f"file '{quoted}'")
    return "\n".join(lines) + "\n"


def _rate(fps_rational: str) -> float:
    num, _, den = str(fps_rational).partition("/")
    value = float(num) / float(den or 1)
    if value <= 0:
        raise ValueError(f"bad frame rate {fps_rational!r}")
    return value


# ---------------------------------------------------------------------------
# Join
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PieceTracks:
    """A finished piece: its OHV records (JSONL, gzip allowed) and the team colours it found."""

    spec: PieceSpec
    path: Path
    team_colors_bgr: Sequence[Sequence[int]] | None = None


@dataclass
class Cut:
    """What the join found where piece ``index`` starts."""

    index: int
    linked: int = 0  # players whose track carries across the cut
    shift: int = 0  # frames the piece's cut was off by (corrected)
    flipped: bool = False  # the piece's team labels were swapped to agree
    players_before: int = 0
    players_after: int = 0

    @property
    def weak(self) -> bool:
        """Players on both sides of the cut, but few of them followed across it."""
        return self.players_before >= 4 and self.players_after >= 4 and self.linked < WEAK_JOIN_LINKS


@dataclass
class JoinReport:
    frames: int = 0
    tracks: int = 0
    events: int = 0
    team_colors_bgr: list[tuple[int, int, int]] | None = None
    cuts: list[Cut] = field(default_factory=list)
    warnings: list[dict[str, str]] = field(default_factory=list)


@dataclass
class _Sighting:
    player: int  # the piece's own OHV id
    box: tuple[float, float, float, float]
    team: Any


def join_tracks(pieces: Sequence[PieceTracks], dest: str | os.PathLike[str]) -> JoinReport:
    """Write the pieces' records as one OHV tracks file at ``dest`` (see the module docstring)."""
    report = JoinReport()
    ordered = sorted(pieces, key=lambda p: p.spec.index)
    reference = next((_colors(p.team_colors_bgr) for p in ordered if _colors(p.team_colors_bgr)), None)
    report.team_colors_bgr = reference
    ids = _IdSpace()
    tail: dict[int, list[tuple[int, _Sighting]]] = {}  # global frame -> (global id, sighting), teams agreed
    with open(dest, "w", encoding="utf-8") as out:
        for number, piece in enumerate(ordered):
            following = ordered[number + 1].spec if number + 1 < len(ordered) else None
            tail = _join_piece(piece, following, tail, ids, reference, report, out, first=number == 0)
    report.tracks = ids.count
    weak = [c for c in report.cuts if c.weak]
    if weak:
        report.warnings.append(_weak_cuts_warning(len(weak)))
    return report


def _join_piece(
    piece: PieceTracks,
    following: PieceSpec | None,
    previous_tail: dict[int, list[tuple[int, _Sighting]]],
    ids: _IdSpace,
    reference: list[tuple[int, int, int]] | None,
    report: JoinReport,
    out: IO[str],
    *,
    first: bool,
) -> dict[int, list[tuple[int, _Sighting]]]:
    spec = piece.spec
    records = _records(piece.path)
    head: list[dict[str, Any]] = []
    if previous_tail:
        last_shared = max(previous_tail) + MAX_FRAME_SHIFT
        for record in records:
            head.append(record)
            if spec.start + _frame(record) > last_shared:
                break
    mapping: dict[int, int] = {}
    shift, flip = 0, False
    if not first:
        cut = Cut(index=spec.index)
        shift, links = _best_shift(previous_tail, head, spec)
        mapping.update(links)
        flip = _flip_teams(previous_tail, head, spec, shift, links, piece.team_colors_bgr, reference)
        cut.linked, cut.shift, cut.flipped = len(links), shift, flip
        cut.players_before = _players_at(previous_tail, spec.own_start)
        cut.players_after = _players_in(head, spec, shift, spec.own_start)
        report.cuts.append(cut)
    elif _swapped(piece.team_colors_bgr, reference):
        flip = True
    local_base = spec.index * LOCAL_ID_BLOCK

    def gid(raw: Any) -> int | None:
        player = _int(raw)
        if player is None:
            return None
        if player not in mapping:
            mapping[player] = ids.new()
        return mapping[player]

    tail: dict[int, list[tuple[int, _Sighting]]] = {}
    events: list[dict[str, Any]] = []
    held: dict[str, Any] | None = None  # the last own record, written with the piece's events
    for record in _chain(head, records):
        frame = spec.start + _frame(record) + shift
        for event in record.get("events") or ():
            if isinstance(event, dict) and (moved := _move_event(event, spec, shift, gid, local_base, flip)):
                events.append(moved)
        sightings = _sightings(record)
        if following is not None and frame >= following.start - MAX_FRAME_SHIFT:
            tail[frame] = [(gid(s.player), _flipped_sighting(s, flip)) for s in sightings]  # type: ignore[misc]
        if not spec.owns(frame):
            continue
        if held is not None:
            out.write(json.dumps(held, separators=(",", ":")) + "\n")
        held = _move_record(record, frame, gid, local_base, flip)
        report.frames += 1
    if held is not None:
        held["events"] = events
        out.write(json.dumps(held, separators=(",", ":")) + "\n")
        report.events += len(events)
    elif events:
        logger.warning("piece %d owns no frames; %d events dropped", spec.index, len(events))
    return tail


class _IdSpace:
    """Player ids on the whole film: 1, 2, 3, ... (the adapter keeps ids from 1,000,000 for referees)."""

    def __init__(self) -> None:
        self.count = 0

    def new(self) -> int:
        self.count += 1
        return self.count


def _records(path: Path) -> Iterator[dict[str, Any]]:
    opener = gzip.open if str(path).endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as fh:  # type: ignore[operator]
        for raw in fh:
            if not raw.strip():
                continue
            try:
                record = json.loads(raw)
            except ValueError:  # a truncated last line: the adapter counts those, we skip them
                continue
            if isinstance(record, dict) and _int(record.get("frame")) is not None:
                yield record


def _chain(head: list[dict[str, Any]], rest: Iterator[dict[str, Any]]) -> Iterator[dict[str, Any]]:
    yield from head
    yield from rest


def _frame(record: dict[str, Any]) -> int:
    """OHV's 1-based frame -> 0-based frame of the piece."""
    return max(0, (_int(record.get("frame")) or 1) - 1)


def _int(value: Any) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _box(value: Any) -> tuple[float, float, float, float] | None:
    if not isinstance(value, (list, tuple)) or len(value) < 4:
        return None
    try:
        x1, y1, x2, y2 = (float(v) for v in value[:4])
    except (TypeError, ValueError):
        return None
    return (x1, y1, x2, y2) if x2 > x1 and y2 > y1 else None


def _sightings(record: dict[str, Any]) -> list[_Sighting]:
    found = []
    for player in record.get("players") or ():
        if not isinstance(player, dict):
            continue
        number, box = _int(player.get("id")), _box(player.get("box"))
        if number is not None and box is not None:
            found.append(_Sighting(number, box, player.get("team")))
    return found


def _iou(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> float:
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    if w <= 0 or h <= 0:
        return 0.0
    inter = w * h
    return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter)


def _best_shift(
    previous_tail: dict[int, list[tuple[int, _Sighting]]], head: list[dict[str, Any]], spec: PieceSpec
) -> tuple[int, dict[int, int]]:
    """The frame shift (within ``MAX_FRAME_SHIFT``) at which the boxes on both sides of the cut
    agree best, and the links (piece id -> global id) at that shift. Every shift is scored on the
    same frames of the film; a tie goes to the smaller shift. No match at all: shift 0, no links."""
    if not previous_tail:
        return 0, {}
    window = (spec.start + MAX_FRAME_SHIFT, max(previous_tail) + 1 - MAX_FRAME_SHIFT)
    best: tuple[float, int, dict[int, int]] = (-1.0, 0, {})
    for shift in sorted(range(-MAX_FRAME_SHIFT, MAX_FRAME_SHIFT + 1), key=abs):
        score, links = _links(previous_tail, head, spec, shift, window)
        if score > best[0] + 1e-9:
            best = (score, shift, links)
    return best[1], best[2]


def _links(
    previous_tail: dict[int, list[tuple[int, _Sighting]]],
    head: list[dict[str, Any]],
    spec: PieceSpec,
    shift: int,
    window: tuple[int, int],
) -> tuple[float, dict[int, int]]:
    """Links at ``shift``, and how well the boxes agree there (the sum of the matching IoUs)."""
    votes: Counter[tuple[int, int]] = Counter()
    seen_before: Counter[int] = Counter()
    seen_after: Counter[int] = Counter()
    score = 0.0
    for record in head:
        frame = spec.start + _frame(record) + shift
        before = previous_tail.get(frame)
        if not before or not window[0] <= frame < window[1]:
            continue
        after = _sightings(record)
        seen_before.update(g for g, _ in before)
        seen_after.update(s.player for s in after)
        for g, old in before:
            for new in after:
                overlap = _iou(old.box, new.box)
                if overlap >= LINK_MIN_IOU:
                    votes[(g, new.player)] += 1
                    score += overlap
    links: dict[int, int] = {}
    used: set[int] = set()
    for (g, player), count in votes.most_common():
        if g in used or player in links:
            continue
        both = min(seen_before[g], seen_after[player])
        if count >= LINK_MIN_FRAMES and count >= LINK_MIN_SHARE * both:
            links[player] = g
            used.add(g)
    return score, links


def _flip_teams(
    previous_tail: dict[int, list[tuple[int, _Sighting]]],
    head: list[dict[str, Any]],
    spec: PieceSpec,
    shift: int,
    links: dict[int, int],
    colors: Sequence[Sequence[int]] | None,
    reference: list[tuple[int, int, int]] | None,
) -> bool:
    """Swap this piece's team labels? Decided by the linked players' teams on both sides of the
    cut, or by the jersey colours when too few linked players have a team."""
    before: dict[int, Counter[int]] = defaultdict(Counter)
    for sightings in previous_tail.values():
        for g, s in sightings:
            if (team := _team(s.team)) is not None:
                before[g][team] += 1
    after: dict[int, Counter[int]] = defaultdict(Counter)
    for record in head:
        for s in _sightings(record):
            if (team := _team(s.team)) is not None and s.player in links:
                after[s.player][team] += 1
    agree = disagree = 0
    for player, g in links.items():
        if before[g] and after[player]:
            if before[g].most_common(1)[0][0] == after[player].most_common(1)[0][0]:
                agree += 1
            else:
                disagree += 1
    if agree + disagree >= TEAM_VOTE_MIN_LINKS:
        return disagree > agree
    return _swapped(colors, reference)


def _team(value: Any) -> int | None:
    if isinstance(value, str):
        label = value.strip().lower()
        if label in ("dark", "light"):
            return 0 if label == "dark" else 1
        value = _int(label)
    number = _int(value)
    return number if number in (0, 1) else None


def _other_team(value: Any) -> Any:
    """The other team, in the same form OHV wrote it (0/1 or "dark"/"light")."""
    if isinstance(value, str):
        label = value.strip().lower()
        if label in ("dark", "light"):
            return "light" if label == "dark" else "dark"
    team = _team(value)
    return value if team is None else 1 - team


def _colors(raw: Sequence[Sequence[int]] | None) -> list[tuple[int, int, int]] | None:
    if not raw or len(raw) != 2:
        return None
    try:
        return [tuple(int(v) for v in c[:3]) for c in raw]  # type: ignore[misc]
    except (TypeError, ValueError):
        return None


def _swapped(raw: Sequence[Sequence[int]] | None, reference: list[tuple[int, int, int]] | None) -> bool:
    colors = _colors(raw)
    if colors is None or reference is None:
        return False

    def distance(a: tuple[int, ...], b: tuple[int, ...]) -> float:
        return math.dist(a, b)

    same = distance(colors[0], reference[0]) + distance(colors[1], reference[1])
    crossed = distance(colors[0], reference[1]) + distance(colors[1], reference[0])
    return crossed < same


def _flipped_sighting(s: _Sighting, flip: bool) -> _Sighting:
    return _Sighting(s.player, s.box, _other_team(s.team)) if flip else s


def _players_at(tail: dict[int, list[tuple[int, _Sighting]]], frame: int) -> int:
    near = [len(v) for f, v in tail.items() if abs(f - frame) <= MAX_FRAME_SHIFT]
    return max(near, default=0)


def _players_in(head: list[dict[str, Any]], spec: PieceSpec, shift: int, frame: int) -> int:
    near = [len(_sightings(r)) for r in head if abs(spec.start + _frame(r) + shift - frame) <= MAX_FRAME_SHIFT]
    return max(near, default=0)


def _move_record(record: dict[str, Any], frame: int, gid: Any, local_base: int, flip: bool) -> dict[str, Any]:
    moved = {key: value for key, value in record.items() if key != "events"}
    moved["frame"] = frame + 1
    players = []
    for player in record.get("players") or ():
        if not isinstance(player, dict):
            continue
        player = dict(player)
        if "id" in player:
            player["id"] = gid(player.get("id"))
        if (local := _int(player.get("local_track_id"))) is not None:
            player["local_track_id"] = local_base + local
        if flip and "team" in player:
            player["team"] = _other_team(player["team"])
        players.append(player)
    if "players" in record:
        moved["players"] = players
    if "holder_id" in record:
        moved["holder_id"] = gid(record.get("holder_id"))
    return moved


def _move_event(
    event: dict[str, Any], spec: PieceSpec, shift: int, gid: Any, local_base: int, flip: bool
) -> dict[str, Any] | None:
    """The event on the whole film's frames and ids, or None when another piece owns it."""
    start = _int(event.get("start_frame")) or _int(event.get("end_frame"))
    if start is None:
        return None
    offset = spec.start + shift
    if not spec.owns(offset + max(0, start - 1)):
        return None
    moved = dict(event)
    for key in ("start_frame", "end_frame"):
        if (value := _int(event.get(key))) is not None:
            moved[key] = value + offset
    for key in _EVENT_PLAYER_FIELDS:
        if key in event:
            moved[key] = gid(event.get(key))
    if (local := _int(event.get("local_track_id"))) is not None:
        moved["local_track_id"] = local_base + local
    if flip and "team" in event:
        moved["team"] = _other_team(event["team"])
    return moved


def _weak_cuts_warning(count: int) -> dict[str, str]:
    where = "one of the cuts" if count == 1 else f"{count} of the cuts"
    return {
        "code": "PIECES_JOIN_WEAK",
        "message": (
            f"The film was analysed in pieces on several GPUs, and at {where} few players could be followed "
            "from one piece into the next: their tracks start again there, so check the names on the Players tab."
        ),
        "severity": "info",
    }
