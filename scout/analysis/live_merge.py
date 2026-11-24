"""Join the GPU results of a live game's parts into one ``TrackingResult`` (docs/LIVE.md).

Each part of a live game is analysed on its own, so its frames start at 0, its tracks are
numbered from scratch and its two teams are whichever cluster the pipeline found first. The
join puts everything on one timeline:

* **Frames** move by the length of the parts before (a part that could not be analysed still
  takes its time, so the timeline stays in step with the film).
* **Tracks** get the id ``part index * 100000 + track id``. It depends only on the part, so the
  id of a track never changes as more parts arrive, and a coach's track assignment stays valid.
  A player is a new track in every part; the roster matcher names each from its jersey reads.
* **Teams** are matched to the first analysed part's teams by jersey colour.
* **Periods**: the parts' own period events are dropped (a 2-minute part cannot see a halftime)
  and the periods are found again on the joined tracking with the GPU pipeline's own detector.
* **Parts without tracking** are of two kinds. In an *empty* part the GPU found no play (a
  timeout, halftime, warm-ups): it is a stoppage like any other, which is how a halftime that
  fills several parts is found. A *failed* part is a hole in the data: it is reported
  (``LIVE_PARTS_MISSING``) and never read as a timeout.

An event that straddles the cut between two parts (a shot released in one and landing in the
next) can be missed. A full re-analysis of the finished film has no cuts.
"""

from __future__ import annotations

import logging
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from itertools import pairwise
from typing import Any

from scout.schemas import (
    ATTR_ASSISTED_BY,
    ATTR_BALL_HANDLER,
    ATTR_BLOCKED_BY,
    ATTR_FOULED_TRACK,
    ATTR_PERIOD,
    ATTR_STOLEN_BY,
    ATTR_TO_TRACK,
    ATTR_WON_BY_TEAM,
    BallSample,
    CourtInfo,
    Homography,
    JerseyRead,
    PipelineWarning,
    RawEvent,
    RawEventType,
    RimInfo,
    TeamInfo,
    Track,
    TrackingResult,
    TrackSample,
    VideoInfo,
)

logger = logging.getLogger(__name__)

TRACK_ID_BLOCK = 100_000  # ids of part n are n * TRACK_ID_BLOCK + the part's own track id
LIVE_OPTION = "live"  # key in TrackingResult.pipeline.options of a joined live game
PARTS_MISSING_CODE = "LIVE_PARTS_MISSING"
NO_PLAY_CODE = "LIVE_NO_PLAY"
PERIODS_NOT_FOUND_CODE = "LIVE_PERIODS_NOT_DETECTED"

_TRACK_ATTRS = (ATTR_ASSISTED_BY, ATTR_BLOCKED_BY, ATTR_TO_TRACK, ATTR_STOLEN_BY, ATTR_FOULED_TRACK, ATTR_BALL_HANDLER, "gained_by_track")
_STRUCTURE_EVENTS = frozenset({RawEventType.PERIOD_START, RawEventType.PERIOD_END})


@dataclass(frozen=True)
class Part:
    """One part of the film: its GPU results, or None when it could not be analysed."""

    index: int
    duration_s: float  # as the capture client measured it; used when there is no tracking
    tracking: TrackingResult | None = None
    empty: bool = False  # without tracking because no play was found in it (a break), not because it failed


def global_track_id(index: int, track_id: int) -> int:
    return index * TRACK_ID_BLOCK + track_id


class LiveJoin:
    """The join so far. Parts are added in stream order; ``result()`` is the joined tracking.

    The live job keeps one for the whole game, so a new part costs only its own data.
    """

    def __init__(self, *, filename: str = "live.mp4") -> None:
        self.filename = filename
        self.reference: TrackingResult | None = None
        self.parts = 0
        self.analysed = 0
        self._last_index = -1
        self._leading_gaps: list[tuple[float, bool]] = []  # (seconds, empty) of the parts before the first analysed one
        self._teams: _TeamMatcher | None = None
        self._tracks: list[Track] = []
        self._ball: list[BallSample] = []
        self._events: list[RawEvent] = []
        self._homographies: list[Homography] = []
        self._rims: list[RimInfo] = []
        self._warnings: dict[str, PipelineWarning] = {}
        self._gaps: list[tuple[int, int]] = []  # frame ranges of failed parts
        self._quiet: list[tuple[int, int]] = []  # frame ranges of parts without play
        self._elapsed = 0.0
        self._offset = 0  # frames of the parts added so far

    def add(self, part: Part) -> None:
        if part.index <= self._last_index:
            raise ValueError(f"part {part.index} added after part {self._last_index}")
        self._last_index = part.index
        self.parts += 1
        tracking = part.tracking
        if tracking is None:
            if self.reference is None:
                self._leading_gaps.append((part.duration_s, part.empty))
            else:
                self._gap(part.duration_s, part.empty)
            return
        if self.reference is None:
            self.reference = tracking
            self._teams = _TeamMatcher(tracking.teams)
            for seconds, empty in self._leading_gaps:
                self._gap(seconds, empty)
            self._leading_gaps = []
        assert self._teams is not None
        fps = self.reference.video.fps
        scale = fps / tracking.video.fps  # 1.0 unless the camera changed its frame rate
        frames = _frame_count(tracking, part.duration_s, fps, scale)
        shift = _Shift(self._offset, scale, part.index, self._teams.mapping(tracking.teams))
        self._tracks.extend(shift.track(t) for t in tracking.tracks)
        self._ball.extend(shift.ball(b) for b in tracking.ball)
        self._events.extend(shift.event(e) for e in tracking.events if _keep_event(e))
        last = self._offset + frames - 1
        self._homographies.extend(shift.homography(h, last) for h in tracking.court.homographies)
        self._rims.extend(shift.rim(r, last) for r in tracking.rims)
        for warning in tracking.warnings:
            self._warnings.setdefault(warning.code, warning)
        self._elapsed += tracking.pipeline.elapsed_s or 0.0
        self._teams.count(tracking.teams, shift.team_map)
        self._offset += frames
        self.analysed += 1

    def _gap(self, seconds: float, empty: bool) -> None:
        assert self.reference is not None
        frames = max(1, round(seconds * self.reference.video.fps))
        (self._quiet if empty else self._gaps).append((self._offset, self._offset + frames))
        self._offset += frames

    @property
    def duration_s(self) -> float:
        """Film time the join covers (0 until a part with tracking is in it)."""
        return self._offset / self.reference.video.fps if self.reference is not None else 0.0

    def result(self, *, detect_periods: bool = True) -> TrackingResult:
        """The joined tracking. Raises ``ValueError`` while no part has tracking."""
        reference = self.reference
        if reference is None or self._teams is None:
            raise ValueError("no analysed part to join")
        fps = reference.video.fps
        warnings = dict(self._warnings)
        if self._gaps:
            spans = [(a / fps, b / fps) for a, b in self._gaps]
            warnings[PARTS_MISSING_CODE] = PipelineWarning(code=PARTS_MISSING_CODE, message=_gap_message(spans))
        if self._quiet:
            quiet = ", ".join(f"{_clock(a)}-{_clock(b)}" for a, b in _joined([(a / fps, b / fps) for a, b in self._quiet]))
            message = f"No play was found in these stretches of the film (a break, a timeout or warm-ups): {quiet}."
            warnings[NO_PLAY_CODE] = PipelineWarning(code=NO_PLAY_CODE, message=message, severity="info")
        options = {**reference.pipeline.options, LIVE_OPTION: True, "parts": self.parts, "parts_analysed": self.analysed}
        merged = TrackingResult(
            video=VideoInfo(
                filename=self.filename,
                fps=fps,
                width=reference.video.width,
                height=reference.video.height,
                frame_count=self._offset,
                duration_s=round(self._offset / fps, 3),
                analysis_fps=reference.video.analysis_fps,
                codec=reference.video.codec,
            ),
            pipeline=reference.pipeline.model_copy(update={"options": options, "elapsed_s": round(self._elapsed, 1)}),
            court=CourtInfo(
                length_ft=reference.court.length_ft, width_ft=reference.court.width_ft, homographies=list(self._homographies)
            ),
            teams=self._teams.infos(),
            tracks=list(self._tracks),
            ball=list(self._ball),
            events=sorted(self._events, key=lambda e: e.frame),
            rims=list(self._rims),
            warnings=list(warnings.values()),
        )
        return _with_periods(merged, self._gaps) if detect_periods else merged


def merge_parts(parts: Sequence[Part], *, filename: str = "live.mp4", detect_periods: bool = True) -> TrackingResult:
    """One TrackingResult for ``parts`` (any order; joined by ``index``).

    Raises ``ValueError`` when no part has tracking: there is nothing to analyse yet.
    """
    join = LiveJoin(filename=filename)
    for part in sorted(parts, key=lambda p: p.index):
        join.add(part)
    return join.result(detect_periods=detect_periods)


def is_live_tracking(tracking: TrackingResult) -> bool:
    return bool(tracking.pipeline.options.get(LIVE_OPTION))


# ---------------------------------------------------------------------------
# Moving one part onto the joined timeline
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class _Shift:
    offset: int
    scale: float
    index: int
    team_map: dict[int, int]

    def frame(self, frame: int) -> int:
        return self.offset + (frame if self.scale == 1.0 else round(frame * self.scale))

    def track_id(self, track_id: Any) -> Any:
        return global_track_id(self.index, track_id) if isinstance(track_id, int) and not isinstance(track_id, bool) else track_id

    def team(self, team_id: Any) -> Any:
        return self.team_map.get(team_id, team_id) if isinstance(team_id, int) and not isinstance(team_id, bool) else team_id

    def track(self, track: Track) -> Track:
        return Track(
            track_id=global_track_id(self.index, track.track_id),
            team_id=self.team(track.team_id),
            role=track.role,
            jersey_reads=[JerseyRead(frame=self.frame(r.frame), text=r.text, conf=r.conf) for r in track.jersey_reads],
            samples=[TrackSample(f=self.frame(s.f), bbox=s.bbox, court_xy=s.court_xy, conf=s.conf) for s in track.samples],
        )

    def ball(self, sample: BallSample) -> BallSample:
        return sample.model_copy(update={"f": self.frame(sample.f), "holder_track_id": self.track_id(sample.holder_track_id)})

    def event(self, event: RawEvent) -> RawEvent:
        attrs = dict(event.attrs)
        for key in _TRACK_ATTRS:
            if key in attrs:
                attrs[key] = self.track_id(attrs[key])
        if ATTR_WON_BY_TEAM in attrs:
            attrs[ATTR_WON_BY_TEAM] = self.team(attrs[ATTR_WON_BY_TEAM])
        frame = self.frame(event.frame)
        return RawEvent(
            event_id=f"p{self.index:04d}-{event.event_id}",
            type=event.type,
            frame=frame,
            t=0.0,  # set by the caller's fps below
            track_id=self.track_id(event.track_id),
            team_id=self.team(event.team_id),
            conf=event.conf,
            attrs=attrs,
        )

    def homography(self, h: Homography, last: int) -> Homography:
        end = last if h.frame_end is None else min(last, self.frame(h.frame_end))
        return h.model_copy(update={"frame_start": self.frame(h.frame_start), "frame_end": end})

    def rim(self, rim: RimInfo, last: int) -> RimInfo:
        end = last if rim.frame_end is None else min(last, self.frame(rim.frame_end))
        return rim.model_copy(update={"frame_start": self.frame(rim.frame_start), "frame_end": end})


def _frame_count(tracking: TrackingResult, duration_s: float, fps: float, scale: float) -> int:
    """Frames this part takes on the joined timeline: what the GPU counted, else the client's length."""
    if tracking.video.frame_count > 0:
        return max(1, round(tracking.video.frame_count * scale))
    seconds = tracking.video.duration_s or duration_s
    return max(1, round(seconds * fps))


def _keep_event(event: RawEvent) -> bool:
    """Not a part's own idea of the game's structure: the periods are found on the joined tracking."""
    if event.type in _STRUCTURE_EVENTS:
        return False
    return not (event.type == RawEventType.TIMEOUT and event.attrs.get("inferred"))


def _gap_message(gaps: list[tuple[float, float]]) -> str:
    spans = ", ".join(f"{_clock(a)}-{_clock(b)}" for a, b in _joined(gaps))
    return f"Part of the film could not be analysed, so it has no stats: {spans}."


def _joined(gaps: list[tuple[float, float]]) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    for a, b in gaps:
        if out and abs(out[-1][1] - a) < 0.5:
            out[-1] = (out[-1][0], b)
        else:
            out.append((a, b))
    return out


def _clock(seconds: float) -> str:
    minutes, rest = divmod(round(seconds), 60)
    return f"{minutes}:{rest:02d}"


# ---------------------------------------------------------------------------
# Teams
# ---------------------------------------------------------------------------


class _TeamMatcher:
    """Maps each part's team ids onto the first analysed part's, by jersey colour."""

    def __init__(self, reference: Sequence[TeamInfo]) -> None:
        self.reference = list(reference)
        self.track_counts: Counter[int] = Counter()

    def mapping(self, teams: Sequence[TeamInfo]) -> dict[int, int]:
        """Team id in the part -> team id in the join. Ids the reference does not have stay as they are."""
        if not self.reference or not teams:
            return {}
        pairs = self._by_name(teams) or self._by_rgb(teams)
        if pairs is None:
            return {}
        # Never two of the part's teams on one id: then the colours did not tell them apart.
        return pairs if len(set(pairs.values())) == len(pairs) else {}

    def _by_name(self, teams: Sequence[TeamInfo]) -> dict[int, int] | None:
        names = {t.color_name: t.team_id for t in self.reference if t.color_name}
        if len(names) != len(self.reference) or any(not t.color_name or t.color_name not in names for t in teams):
            return None
        return {t.team_id: names[t.color_name] for t in teams if t.color_name}

    def _by_rgb(self, teams: Sequence[TeamInfo]) -> dict[int, int] | None:
        if any(t.color_rgb is None for t in self.reference) or any(t.color_rgb is None for t in teams):
            return None
        if len(teams) == 2 and len(self.reference) == 2:  # the pairing with the smaller total colour distance
            a, b = teams
            x, y = self.reference
            straight = _distance(a.color_rgb, x.color_rgb) + _distance(b.color_rgb, y.color_rgb)
            crossed = _distance(a.color_rgb, y.color_rgb) + _distance(b.color_rgb, x.color_rgb)
            first, second = (x, y) if straight <= crossed else (y, x)
            return {a.team_id: first.team_id, b.team_id: second.team_id}
        return {t.team_id: min(self.reference, key=lambda r: _distance(t.color_rgb, r.color_rgb)).team_id for t in teams}

    def count(self, teams: Sequence[TeamInfo], mapping: dict[int, int]) -> None:
        for team in teams:
            self.track_counts[mapping.get(team.team_id, team.team_id)] += team.track_count

    def infos(self) -> list[TeamInfo]:
        return [t.model_copy(update={"track_count": self.track_counts.get(t.team_id, 0)}) for t in self.reference]


def _distance(a: Any, b: Any) -> float:
    return float(sum((int(p) - int(q)) ** 2 for p, q in zip(a, b, strict=True)))


# ---------------------------------------------------------------------------
# Periods
# ---------------------------------------------------------------------------


def rebuild_periods(tracking: TrackingResult) -> TrackingResult:
    """``tracking`` (without period events) with its periods found on the whole timeline."""
    return _with_periods(tracking)


def _with_periods(merged: TrackingResult, gaps: Sequence[tuple[int, int]] = ()) -> TrackingResult:
    """``merged`` with its times set and the game's periods found on the whole timeline.

    ``gaps``: frame ranges of parts without tracking. Nobody is seen there, which looks like a
    stoppage: a "timeout" that starts in one is dropped.
    """
    fps = merged.video.fps
    events = [e.model_copy(update={"t": round(e.frame / fps, 3)}) for e in merged.events]
    try:
        structure = _period_events(merged, events)
    except Exception:  # never lose the stats over the period labels
        logger.exception("Could not detect the periods of the joined live tracking")
        structure = []
    slack = round(2 * fps)
    structure = [
        e
        for e in structure
        if not (e.type == RawEventType.TIMEOUT and any(a - slack <= e.frame <= b for a, b in gaps))
    ]
    warnings = list(merged.warnings)
    if not structure:
        structure = _fallback_period(merged, events)
        if not any(w.code == PERIODS_NOT_FOUND_CODE for w in warnings):
            warnings.append(
                PipelineWarning(
                    code=PERIODS_NOT_FOUND_CODE,
                    message="The periods could not be told apart, so the whole game is shown as one period.",
                    severity="info",
                )
            )
    order = {RawEventType.PERIOD_START: 0, RawEventType.JUMP_BALL: 1, RawEventType.PERIOD_END: 3}
    events = sorted(events + structure, key=lambda e: (e.frame, order.get(e.type, 2)))
    return merged.model_copy(update={"events": events, "warnings": warnings})


def _period_events(merged: TrackingResult, events: list[RawEvent]) -> list[RawEvent]:
    """The GPU pipeline's period detector (pure Python + numpy) on the joined tracking."""
    from modal_app.pipeline.events import detect_period_events
    from modal_app.pipeline.types import BallObs, HomographySeg, Perception, RimObs, TrackData, TrackObs, VideoMeta

    video = merged.video
    perception = Perception(
        video=VideoMeta(
            path="",
            filename=video.filename,
            fps=video.fps,
            width=video.width,
            height=video.height,
            frame_count=video.frame_count,
            duration_s=video.duration_s,
            analysis_fps=video.analysis_fps,
            step=_sample_step(merged),
            codec=video.codec,
        ),
        court_length_ft=merged.court.length_ft,
        court_width_ft=merged.court.width_ft,
    )
    for track in merged.tracks:
        perception.tracks[track.track_id] = TrackData(
            track_id=track.track_id,
            obs=[TrackObs(frame=s.f, bbox=s.bbox, conf=s.conf, court_xy=s.court_xy) for s in track.samples],
            team_id=track.team_id,
            role=track.role,
        )
    perception.ball = [
        BallObs(frame=b.f, xy=b.xy, conf=b.conf, court_xy=b.court_xy, holder_track_id=b.holder_track_id, interpolated=b.interpolated)
        for b in sorted(merged.ball, key=lambda b: b.f)
    ]
    perception.rims = [RimObs(side=r.side, xy_px=r.xy_px, frame_start=r.frame_start, frame_end=r.frame_end) for r in merged.rims]
    perception.homographies = [
        HomographySeg(frame_start=h.frame_start, frame_end=h.frame_end, matrix=h.matrix, error_px=h.reprojection_error_px, source=h.source)
        for h in merged.court.homographies
    ]
    existing = [e.model_dump(mode="json") for e in events]
    drafts = detect_period_events(perception, existing_events=existing)
    return [RawEvent.model_validate({**draft, "event_id": f"lp{number:05d}"}) for number, draft in enumerate(drafts, start=1)]


def _sample_step(merged: TrackingResult) -> int:
    """Frames between two samples of a track: the analysis rate, or wider when the GPU thinned the samples."""
    nominal = max(1, round(merged.video.fps / merged.video.analysis_fps))
    deltas: Counter[int] = Counter()
    for track in merged.tracks[:200]:
        frames = [s.f for s in track.samples[:500]]
        deltas.update(b - a for a, b in pairwise(frames) if b > a)
    if not deltas:
        return nominal
    return max(nominal, deltas.most_common(1)[0][0])


def _fallback_period(merged: TrackingResult, events: list[RawEvent]) -> list[RawEvent]:
    """One period from the first thing that happens (a tracking without any period event reads oddly)."""
    held = next((b.f for b in merged.ball if b.holder_track_id is not None), None)
    first_event = events[0].frame if events else None
    candidates = [f for f in (held, first_event) if f is not None]
    if not candidates:
        return []
    frame = min(candidates)
    return [
        RawEvent(
            event_id="lp00001",
            type=RawEventType.PERIOD_START,
            frame=frame,
            t=round(frame / merged.video.fps, 3),
            conf=0.3,
            attrs={ATTR_PERIOD: 1},
        )
    ]
