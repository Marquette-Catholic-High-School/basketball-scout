"""OpenHoopVision output -> ``Perception`` + raw events.

OHV writes one ``basketball_frame_v2`` JSON object per analysed frame (built in OHV's
``pipeline/frame_events.py`` / ``frame_features.py``). The fields used here:

* ``frame`` -- analysed frame number counted from 1 (OHV's ``time = (frame - 1) / fps``).
* ``players[]`` -- ``id`` (global player id after ReID; None while unconfirmed),
  ``local_track_id``, ``box`` [x1, y1, x2, y2] px, ``score``, ``team`` 0/1 (0 = "dark",
  1 = "light"), ``court_xy`` [x, y] metres, ``pose`` 17 x [x, y, score] (COCO-17),
  ``jersey_number`` (str, only once OCR votes lock it), ``jersey_number_candidate``.
* ``holder_id`` -- global id of the player controlling the ball.
* ``ball`` -- ``center`` [x, y] px, ``score``, ``observed`` / ``interpolated``.
* ``rim`` -- the best rim detection; ``detections.referee[]`` -- referee boxes. OHV does
  not track referees, so we link those boxes into ``role="referee"`` tracks.
* ``events[]`` -- completed shot / pass / rebound / turnover / dribble events with
  ``start_frame`` / ``end_frame`` (1-based analysed frames) and global player ids.

Conversions: frames -> 0-based ORIGINAL frames and pixels -> ORIGINAL resolution (via
``FrameMap``, which undoes the pre-transcode); court metres -> our feet frame
(``ohv_court_to_feet``). The JSONL is streamed line by line; missing fields and a
truncated last line (a killed run) are tolerated.

Pure Python on purpose (no numpy): this module also runs where only ``modal`` is installed.
"""

from __future__ import annotations

import bisect
import json
import logging
import math
import os
import statistics
from collections import Counter, defaultdict
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass, field
from typing import Any

from modal_app.pipeline.types import (
    XY,
    BallObs,
    BBox,
    HomographySeg,
    Perception,
    RimObs,
    TrackData,
    TrackObs,
    VideoMeta,
)
from modal_app.pipeline.video import FrameMap

logger = logging.getLogger(__name__)

FractionProgress = Callable[[float, str], None]

FT = 0.3048
TEAM_LABELS = ("dark", "light")  # OHV team id 0 / 1 (OHV sorts its two jersey clusters by lightness)
LOCKED_JERSEY_CONF = 0.9  # OHV locks a number only after several >= 0.85-confidence OCR reads agree
CANDIDATE_JERSEY_CONF = 0.4  # provisional read that OHV has not confirmed
JERSEY_READ_INTERVAL_S = 1.0  # at most one read per track/number per second keeps votes proportional
KEYPOINT_EVERY_N = 3  # keep skeletons on every 3rd analysed frame (memory)
HOLDER_BALL_CONF = 0.2  # ball position guessed from the holder's box (ball itself not seen)
CALIBRATION_MARGIN_FT = 6.0
REFEREE_TRACK_ID_BASE = 1_000_000  # OHV global ids count up from 1
REFEREE_MIN_IOU = 0.3
REFEREE_MAX_GAP_S = 1.0
REFEREE_SAMPLE_EVERY = 3
REFEREE_MIN_OBS = 5
RIM_MAX_SHIFT = 0.04  # fraction of the frame width a rim may move within one segment
RIM_MIN_SEGMENT_S = 1.0
RIM_MAX_GAP_S = 2.0
ORIENTATION_SAMPLES = 500  # OHV-vs-calibration position pairs kept for the orientation check
_EVENT_TYPES = frozenset({"shot", "pass", "rebound", "turnover"})


def ohv_court_to_feet(xy_m: Sequence[float], *, width_ft: float) -> XY:
    """OHV court metres -> our court feet.

    OHV's template puts (0, 0) at the corner its court-keypoint model labels first: the
    LEFT baseline's FAR corner as seen by the camera (OHV's mini-map draws y downward
    from the far sideline). Our origin is the left baseline's NEAR corner, so y mirrors.
    Lengths match because the template is patched to the real gym (see ``ohv.CourtSpec``).
    The far-corner reading comes from OHV's code, not from film: when a manual calibration
    exists, ``_Builder.finish`` checks it and warns ``COURT_ORIENTATION_CHECK`` if OHV's
    positions fit the calibration better mirrored.
    """
    return (float(xy_m[0]) / FT, width_ft - float(xy_m[1]) / FT)


def calibration_homography(calibration: dict[str, Any] | None, video: VideoMeta) -> HomographySeg | None:
    """The coach's manual pixel->feet calibration, rescaled to the original resolution."""
    if not calibration or not calibration.get("matrix"):
        return None
    matrix = [[float(v) for v in row] for row in calibration["matrix"]]
    if len(matrix) != 3 or any(len(row) != 3 for row in matrix):
        logger.warning("ignoring malformed calibration matrix")
        return None
    sx = float(calibration.get("video_width") or video.width) / video.width
    sy = float(calibration.get("video_height") or video.height) / video.height
    # H_original = H_calibration @ diag(sx, sy, 1): original px -> calibration px -> feet
    scaled = [[row[0] * sx, row[1] * sy, row[2]] for row in matrix]
    return HomographySeg(frame_start=0, frame_end=None, matrix=scaled, source="manual")


def project(matrix: list[list[float]], x: float, y: float) -> XY | None:
    """Map one pixel through a 3x3 homography (None near the horizon)."""
    w = matrix[2][0] * x + matrix[2][1] * y + matrix[2][2]
    if abs(w) < 1e-9:
        return None
    return (
        (matrix[0][0] * x + matrix[0][1] * y + matrix[0][2]) / w,
        (matrix[1][0] * x + matrix[1][1] * y + matrix[1][2]) / w,
    )


@dataclass
class AdapterStats:
    """Data-quality numbers the runner turns into errors / warnings."""

    frames: int = 0
    bad_lines: int = 0
    players_per_frame: list[int] = field(default_factory=list)
    ball_observed_frames: int = 0
    player_obs: int = 0
    court_obs: int = 0  # player observations with an OHV court position
    dribbles: int = 0

    @property
    def median_players(self) -> float:
        return float(statistics.median(self.players_per_frame)) if self.players_per_frame else 0.0

    @property
    def ball_coverage(self) -> float:
        return self.ball_observed_frames / self.frames if self.frames else 0.0

    @property
    def court_coverage(self) -> float:
        return self.court_obs / self.player_obs if self.player_obs else 0.0


@dataclass
class AdapterResult:
    perception: Perception
    events: list[dict[str, Any]]  # RawEvent dicts (docs/TRACKING_SCHEMA.md)
    stats: AdapterStats


def iter_frame_records(
    path: str | os.PathLike[str], stats: AdapterStats, progress: FractionProgress | None = None
) -> Iterator[dict[str, Any]]:
    """Yield JSONL records one at a time, skipping blank or broken lines (counted in ``stats``)."""
    size = max(1, os.path.getsize(path))
    consumed = 0
    with open(path, "rb") as fh:
        for number, raw in enumerate(fh, start=1):
            consumed += len(raw)
            if not raw.strip():
                continue
            try:
                record = json.loads(raw)
            except ValueError:  # truncated last line of a killed run, or garbage
                stats.bad_lines += 1
                logger.warning("skipping unreadable OHV record on line %d", number)
                continue
            if not isinstance(record, dict):
                stats.bad_lines += 1
                continue
            if progress is not None and number % 2000 == 0:
                progress(consumed / size, f"Reading tracking data ({number:,} frames)")
            yield record


def adapt_ohv(
    tracks_path: str | os.PathLike[str],
    video: VideoMeta,
    frame_map: FrameMap,
    *,
    court_length_ft: float = 84.0,
    court_width_ft: float = 50.0,
    team_colors_bgr: Sequence[Sequence[int]] | None = None,
    calibration: dict[str, Any] | None = None,
    progress: FractionProgress | None = None,
) -> AdapterResult:
    """Build the Perception and OHV's events (as RawEvent dicts) from ``tracks_path``."""
    builder = _Builder(
        video,
        frame_map,
        length_ft=court_length_ft,
        width_ft=court_width_ft,
        calibration=calibration_homography(calibration, video),
    )
    for record in iter_frame_records(tracks_path, builder.stats, progress):
        builder.add(record)
    return builder.finish(team_colors_bgr)


# ---------------------------------------------------------------------------
# Field helpers (OHV output is JSON written by research code: be defensive)
# ---------------------------------------------------------------------------


def _int(value: Any) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _finite(values: Any, size: int) -> list[float] | None:
    if not isinstance(values, (list, tuple)) or len(values) < size:
        return None
    try:
        numbers = [float(v) for v in values[:size]]
    except (TypeError, ValueError):
        return None
    return numbers if all(math.isfinite(n) for n in numbers) else None


def _box(value: Any) -> BBox | None:
    numbers = _finite(value, 4)
    if numbers is None or numbers[2] <= numbers[0] or numbers[3] <= numbers[1]:
        return None
    return (numbers[0], numbers[1], numbers[2], numbers[3])


def _xy(value: Any) -> XY | None:
    numbers = _finite(value, 2)
    return (numbers[0], numbers[1]) if numbers is not None else None


def _conf(value: Any, default: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return min(1.0, max(0.0, number)) if math.isfinite(number) else default


def _team_id(value: Any) -> int | None:
    """OHV teams are 0/1 ints or "dark"/"light" labels."""
    if isinstance(value, str):
        label = value.strip().lower()
        return TEAM_LABELS.index(label) if label in TEAM_LABELS else _team_id(_int(label))
    number = _int(value)
    return number if number in (0, 1) else None


def _jersey_text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text if text.isdigit() and len(text) <= 3 else None


def _iou(a: BBox, b: BBox) -> float:
    inter = max(0.0, min(a[2], b[2]) - max(a[0], b[0])) * max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


@dataclass
class _RimRun:
    start: int
    end: int
    sum_x: float
    sum_y: float
    count: int
    bbox: BBox | None

    @property
    def center(self) -> XY:
        return (self.sum_x / self.count, self.sum_y / self.count)


class _RimSegments:
    """Group per-frame rim detections into steady segments (a panning camera starts a new one)."""

    def __init__(self, video: VideoMeta, frame_map: FrameMap) -> None:
        self.frame_map = frame_map
        self.width = video.width
        self.max_shift = RIM_MAX_SHIFT * video.width
        self.max_gap = RIM_MAX_GAP_S * video.fps
        self.min_length = RIM_MIN_SEGMENT_S * video.fps
        self.current: _RimRun | None = None
        self.segments: list[RimObs] = []

    def add(self, rim: Any, frame: int) -> None:
        center = _xy(rim.get("center")) if isinstance(rim, dict) else None
        if center is None:
            return
        x, y = self.frame_map.point(*center)
        box = _box(rim.get("box"))
        bbox = self.frame_map.bbox(box) if box else None
        run = self.current
        if run is not None and frame - run.end <= self.max_gap and math.dist(run.center, (x, y)) <= self.max_shift:
            run.end, run.sum_x, run.sum_y, run.count = frame, run.sum_x + x, run.sum_y + y, run.count + 1
            run.bbox = bbox or run.bbox
            return
        self._close()
        self.current = _RimRun(frame, frame, x, y, 1, bbox)

    def finish(self) -> list[RimObs]:
        self._close()
        return self.segments

    def _close(self) -> None:
        run, self.current = self.current, None
        if run is None or run.end - run.start < self.min_length:
            return
        cx, cy = run.center
        side = "left" if cx < self.width / 2 else "right"
        self.segments.append(RimObs(side=side, xy_px=(cx, cy), bbox=run.bbox, frame_start=run.start, frame_end=run.end))


class _RefereeLinker:
    """Greedy IoU linking of OHV's per-frame referee boxes into referee tracks."""

    def __init__(self, video: VideoMeta, frame_map: FrameMap) -> None:
        self.frame_map = frame_map
        self.max_gap = max(1, round(REFEREE_MAX_GAP_S * video.fps))
        self.tracks: list[TrackData] = []
        self.active: list[TrackData] = []
        self.last: dict[int, tuple[int, BBox]] = {}  # track id -> (frame, box)

    def add(self, detections: Any, frame: int, index: int) -> None:
        if not isinstance(detections, list):
            return
        boxes = []
        for det in detections:
            box = _box(det.get("box")) if isinstance(det, dict) else None
            if box is not None:
                boxes.append((self.frame_map.bbox(box), _conf(det.get("score"), 0.5)))
        self.active = [t for t in self.active if frame - self.last[t.track_id][0] <= self.max_gap]
        free = list(self.active)
        for box, conf in sorted(boxes, key=lambda item: -item[1]):
            match = max(free, key=lambda t: _iou(self.last[t.track_id][1], box), default=None)
            if match is not None and _iou(self.last[match.track_id][1], box) >= REFEREE_MIN_IOU:
                free.remove(match)
            else:
                match = TrackData(track_id=REFEREE_TRACK_ID_BASE + len(self.tracks), role="referee")
                self.tracks.append(match)
                self.active.append(match)
            self.last[match.track_id] = (frame, box)
            if not match.obs or index % REFEREE_SAMPLE_EVERY == 0:
                match.obs.append(TrackObs(frame=frame, bbox=box, conf=conf))

    def finish(self) -> list[TrackData]:
        return [t for t in self.tracks if len(t.obs) >= REFEREE_MIN_OBS]


class _Builder:
    def __init__(
        self,
        video: VideoMeta,
        frame_map: FrameMap,
        *,
        length_ft: float,
        width_ft: float,
        calibration: HomographySeg | None,
    ) -> None:
        self.video = video
        self.frame_map = frame_map
        self.length_ft = length_ft
        self.width_ft = width_ft
        self.calibration = calibration
        self.stats = AdapterStats()
        self.tracks: dict[int, TrackData] = {}
        self.team_votes: dict[int, Counter[int]] = defaultdict(Counter)
        self.local_to_global: dict[int, Counter[int]] = defaultdict(Counter)
        self.jersey_last: dict[tuple[int, str], int] = {}
        self.read_interval = max(1, round(JERSEY_READ_INTERVAL_S * video.fps))
        self.ball: list[BallObs] = []
        self.raw_events: list[dict[str, Any]] = []
        self.rims = _RimSegments(video, frame_map)
        self.referees = _RefereeLinker(video, frame_map)
        self._frames_by_track: dict[int, list[int]] = {}
        self._orientation_pairs: list[tuple[XY, XY]] = []  # (OHV position, calibrated position)

    # -- per record ---------------------------------------------------------
    def add(self, record: dict[str, Any]) -> None:
        index = max(0, (_int(record.get("frame")) or self.stats.frames + 1) - 1)  # 0-based analysed frame
        frame = self.frame_map.to_original(index)
        self.stats.frames += 1
        players = [p for p in record.get("players") or () if isinstance(p, dict)]
        self.stats.players_per_frame.append(sum(1 for p in players if _box(p.get("box")) is not None))
        seen: dict[int, TrackObs] = {}
        for player in players:
            self._add_player(player, frame, index, seen)
        self._add_ball(record, frame, seen)
        self.rims.add(record.get("rim"), frame)
        self.referees.add((record.get("detections") or {}).get("referee"), frame, index)
        events = record.get("events")
        if isinstance(events, list):
            self.raw_events.extend(e for e in events if isinstance(e, dict))

    def _add_player(self, player: dict[str, Any], frame: int, index: int, seen: dict[int, TrackObs]) -> None:
        box = _box(player.get("box"))
        if box is None:
            return
        local, gid = _int(player.get("local_track_id")), _int(player.get("id"))
        if local is not None and gid is not None:
            self.local_to_global[local][gid] += 1
        if gid is None or gid in seen:  # unconfirmed identity, or a duplicate id in this frame
            return
        bbox = self.frame_map.bbox(box)
        obs = TrackObs(
            frame=frame,
            bbox=bbox,
            conf=_conf(player.get("score"), 1.0),
            court_xy=self._player_court(player.get("court_xy"), bbox),
            keypoints=self._keypoints(player.get("pose")) if index % KEYPOINT_EVERY_N == 0 else None,
        )
        track = self.tracks.setdefault(gid, TrackData(track_id=gid))
        track.obs.append(obs)
        seen[gid] = obs
        self.stats.player_obs += 1
        team = _team_id(player.get("team"))
        if team is not None:
            self.team_votes[gid][team] += 1
        self._add_jersey(track, frame, player)

    def _player_court(self, raw: Any, bbox: BBox) -> XY | None:
        xy = _xy(raw)
        foot = ((bbox[0] + bbox[2]) / 2, bbox[3])
        if xy is None:
            return self._calibrated(*foot)
        self.stats.court_obs += 1
        position = ohv_court_to_feet(xy, width_ft=self.width_ft)
        if self.calibration is not None and len(self._orientation_pairs) < ORIENTATION_SAMPLES:
            calibrated = self._calibrated(*foot)
            if calibrated is not None:
                self._orientation_pairs.append((position, calibrated))
        return position

    def _calibrated(self, x: float, y: float) -> XY | None:
        if self.calibration is None:
            return None
        point = project(self.calibration.matrix, x, y)
        margin = CALIBRATION_MARGIN_FT
        if point is None:
            return None
        if not (-margin <= point[0] <= self.length_ft + margin and -margin <= point[1] <= self.width_ft + margin):
            return None  # projects off the floor: not a usable position
        return point

    def _keypoints(self, pose: Any) -> list[tuple[float, float, float]] | None:
        if not isinstance(pose, list) or len(pose) != 17:
            return None
        points = []
        for item in pose:
            numbers = _finite(item, 3)
            if numbers is None:
                return None
            x, y = self.frame_map.point(numbers[0], numbers[1])
            points.append((x, y, numbers[2]))
        return points

    def _add_jersey(self, track: TrackData, frame: int, player: dict[str, Any]) -> None:
        text, conf = _jersey_text(player.get("jersey_number")), LOCKED_JERSEY_CONF
        if text is None:
            text, conf = _jersey_text(player.get("jersey_number_candidate")), CANDIDATE_JERSEY_CONF
        if text is None:
            return
        key = (track.track_id, text)
        last = self.jersey_last.get(key)
        if last is None or frame - last >= self.read_interval:
            self.jersey_last[key] = frame
            track.jersey_reads.append((frame, text, conf))

    def _add_ball(self, record: dict[str, Any], frame: int, seen: dict[int, TrackObs]) -> None:
        holder = _int(record.get("holder_id"))
        holder_obs = seen.get(holder) if holder is not None else None
        ball = record.get("ball") if isinstance(record.get("ball"), dict) else None
        center = _xy(ball.get("center")) if ball else None
        if ball is not None and center is not None:
            xy = self.frame_map.point(*center)
            interpolated = bool(ball.get("interpolated")) or ball.get("observed") is False
            conf = _conf(ball.get("score"), 0.3 if interpolated else 0.5)
            if not interpolated:
                self.stats.ball_observed_frames += 1
        elif holder_obs is not None:  # ball hidden in the holder's hands: OHV still knows who has it
            x1, y1, x2, y2 = holder_obs.bbox
            xy, interpolated, conf = ((x1 + x2) / 2, y1 + 0.45 * (y2 - y1)), True, HOLDER_BALL_CONF
        else:
            return
        court = holder_obs.court_xy if holder_obs is not None else self._calibrated(*xy)
        holder_id = holder if holder in self.tracks else None
        self.ball.append(
            BallObs(frame=frame, xy=xy, conf=conf, court_xy=court, holder_track_id=holder_id, interpolated=interpolated)
        )

    # -- finish -------------------------------------------------------------
    def finish(self, team_colors_bgr: Sequence[Sequence[int]] | None) -> AdapterResult:
        for gid, track in self.tracks.items():
            votes = self.team_votes.get(gid)
            track.team_id = votes.most_common(1)[0][0] if votes else None
        players = list(self.tracks.values())
        teams = [
            {
                "team_id": team,
                "color_rgb": _rgb(team_colors_bgr, team),
                "color_name": TEAM_LABELS[team],
                "track_count": sum(1 for t in players if t.team_id == team),
            }
            for team in (0, 1)
        ]
        events = self._convert_events()
        all_tracks = dict(self.tracks)
        for referee in self.referees.finish():
            all_tracks[referee.track_id] = referee
        perception = Perception(
            video=self.video,
            tracks=all_tracks,
            ball=self.ball,
            rims=self.rims.finish(),
            homographies=[self.calibration] if self.calibration else [],
            teams=teams,
            court_length_ft=self.length_ft,
            court_width_ft=self.width_ft,
        )
        self._check_orientation(perception)
        return AdapterResult(perception=perception, events=events, stats=self.stats)

    def _check_orientation(self, perception: Perception) -> None:
        """Warn when OHV's court positions agree with the manual calibration only if mirrored."""
        if len(self._orientation_pairs) < 20:
            return
        direct = statistics.median(math.dist(ohv_xy, cal) for ohv_xy, cal in self._orientation_pairs)
        mirrored = statistics.median(
            math.dist((ohv_xy[0], self.width_ft - ohv_xy[1]), cal) for ohv_xy, cal in self._orientation_pairs
        )
        logger.info("court orientation check: median %.1f ft as is, %.1f ft mirrored", direct, mirrored)
        if direct > 5.0 and mirrored < 0.5 * direct:
            perception.warn(
                "COURT_ORIENTATION_CHECK",
                f"OpenHoopVision's court positions match the manual calibration only when mirrored side to side "
                f"(median error {direct:.0f} ft as is, {mirrored:.0f} ft mirrored). Please report this film.",
                "info",
            )

    # -- events -------------------------------------------------------------
    def _convert_events(self) -> list[dict[str, Any]]:
        """OHV events -> RawEvent dicts, deduplicated and in frame order.

        ===========  ===============================  =========================================
        OHV event    primary actor                    attrs
        ===========  ===============================  =========================================
        shot         player_id (shooter)              made, is_three, shot_court_xy, shot_xy_px,
                                                      assisted_by_track (OHV ``assister``)
        pass         player_id (passer)               to_track (receiver_id), completed
        rebound      player_id (rebounder)            offensive (from rebound_type)
        turnover     player_id (lost the ball)        kind steal|other, stolen_by_track
        dribble      -- dropped --
        ===========  ===============================  =========================================
        """
        converted: list[dict[str, Any]] = []
        seen: set[tuple[Any, ...]] = set()
        for raw in self.raw_events:
            kind = raw.get("event")
            if kind == "dribble":
                self.stats.dribbles += 1
                continue
            start = _int(raw.get("start_frame")) or _int(raw.get("end_frame"))
            if kind not in _EVENT_TYPES or start is None:
                continue
            key = (kind, start, _int(raw.get("end_frame")), raw.get("player_id"), raw.get("local_track_id"))
            if key not in seen:
                seen.add(key)
                converted.append(self._event(kind, raw, start))
        converted.sort(key=lambda e: e["frame"])
        for number, event in enumerate(converted, start=1):
            event["event_id"] = f"ohv-{number:05d}"
        return converted

    def _event(self, kind: str, raw: dict[str, Any], start: int) -> dict[str, Any]:
        frame = self.frame_map.to_original(max(0, start - 1))
        actor = self._global_id(raw.get("player_id"), raw.get("local_track_id"))
        team = _team_id(raw.get("team"))
        if team is None and actor in self.tracks:
            team = self.tracks[actor].team_id
        attrs: dict[str, Any] = {"source": "openhoopvision"}
        end = _int(raw.get("end_frame"))
        if end is not None:
            attrs["end_frame"] = self.frame_map.to_original(max(0, end - 1))
        if kind == "shot":
            attrs.update(self._shot_attrs(raw, actor, frame))
        elif kind == "pass":
            attrs.update(to_track=self._global_id(raw.get("receiver_id"), None), completed=True)
        elif kind == "rebound":
            attrs["offensive"] = {"offensive": True, "defensive": False}.get(raw.get("rebound_type"))
        elif kind == "turnover":
            gained = self._global_id(raw.get("gained_by"), None)
            steal = raw.get("cause") == "steal"
            attrs.update(kind="steal" if steal else "other", stolen_by_track=gained if steal else None)
            if not steal and gained is not None:
                attrs["gained_by_track"] = gained
        return {
            "event_id": "",
            "type": kind,
            "frame": frame,
            "t": round(frame / self.video.fps, 3),
            "track_id": actor,
            "team_id": team,
            "conf": _event_conf(kind, raw),
            "attrs": attrs,
        }

    def _shot_attrs(self, raw: dict[str, Any], shooter: int | None, frame: int) -> dict[str, Any]:
        result = raw.get("result")
        made = True if result == "made" else False if result in ("miss", "missed") else None
        location = _xy(raw.get("location"))
        court = ohv_court_to_feet(location, width_ft=self.width_ft) if location is not None else None
        attrs: dict[str, Any] = {
            "made": made,
            "is_three": _is_three(raw),
            "shot_court_xy": [round(court[0], 2), round(court[1], 2)] if court else None,
            "shot_xy_px": self._foot_px(shooter, frame),
            "assisted_by_track": _int(raw.get("assister")) if made else None,
            "blocked_by_track": None,
        }
        if made and raw.get("points_source"):
            attrs["points_source"] = str(raw["points_source"])  # "two_point_fallback" = location unreliable
        return attrs

    def _global_id(self, player_id: Any, local_id: Any) -> int | None:
        """Event player ids are global; fall back to the majority global id of the local track."""
        gid = _int(player_id)
        if gid is not None:
            return gid
        local = _int(local_id)
        votes = self.local_to_global.get(local) if local is not None else None
        return votes.most_common(1)[0][0] if votes else None

    def _foot_px(self, track_id: int | None, frame: int) -> list[float] | None:
        """Shooter's feet (bottom-centre of the box) at the nearest observation within 1 s."""
        track = self.tracks.get(track_id) if track_id is not None else None
        if track is None or not track.obs:
            return None
        frames = self._frames_by_track.get(track.track_id)
        if frames is None:
            frames = self._frames_by_track[track.track_id] = [o.frame for o in track.obs]
        i = bisect.bisect_left(frames, frame)
        nearest = min((j for j in (i - 1, i) if 0 <= j < len(frames)), key=lambda j: abs(frames[j] - frame))
        if abs(frames[nearest] - frame) > self.video.fps:
            return None
        x1, _, x2, y2 = track.obs[nearest].bbox
        return [round((x1 + x2) / 2, 2), round(y2, 2)]


def _is_three(raw: dict[str, Any]) -> bool | None:
    """OHV's call (made on the patched high-school geometry); None when unsure."""
    value = _int(raw.get("shot_value"))
    if value in (2, 3):
        return value == 3
    if raw.get("result") == "made" and raw.get("points_source") == "court_location":
        return _int(raw.get("points")) == 3
    return None


def _event_conf(kind: str, raw: dict[str, Any]) -> float:
    """OHV has no numeric event confidence; derive one from its evidence labels."""
    if kind == "shot":
        if raw.get("result") == "unknown":
            return 0.4
        return 0.9 if raw.get("verdict_confidence") == "detector_confirmed" else 0.7
    if kind == "rebound":
        return 0.65 if raw.get("rebound_type") in ("offensive", "defensive") else 0.55
    if kind == "turnover":
        return 0.65 if raw.get("cause") == "steal" else 0.55
    return 0.6


def _rgb(team_colors_bgr: Sequence[Sequence[int]] | None, team: int) -> tuple[int, int, int] | None:
    """The team's jersey colour from OHV's summary line; None when OHV did not print it (the
    server then compares the colour hint with the "dark" / "light" name only)."""
    if team_colors_bgr and len(team_colors_bgr) == 2 and len(team_colors_bgr[team]) == 3:
        b, g, r = (max(0, min(255, int(v))) for v in team_colors_bgr[team])
        return (r, g, b)
    return None
