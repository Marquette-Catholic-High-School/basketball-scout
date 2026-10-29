"""Fast spatial/temporal lookups over a ``TrackingResult``.

Event building, possession inference and play recognition all ask the same kinds of
questions -- "where was track 7 at frame 1234?", "who had the ball?", "how fast was
the screener moving?" -- so they share this index.

Coordinate modes
----------------
* ``court``: positions are court feet. Used when samples carry ``court_xy`` or a
  homography is available (from the pipeline, or a manual calibration passed in).
* ``pixel``: positions are image pixels (bbox foot points). Distances can still be
  converted to approximate feet with :meth:`TrackingIndex.scale_ft`, which uses the
  player's bounding-box height (``AVG_PLAYER_HEIGHT_FT``) as a ruler.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from typing import Literal

import numpy as np

from scout.analysis.geometry import CourtConfig, apply_homography, bbox_foot_point
from scout.schemas import BallSample, Homography, Point, TrackingResult

AVG_PLAYER_HEIGHT_FT = 6.0


@dataclass(frozen=True)
class HolderSegment:
    track_id: int
    team_id: int | None
    start_frame: int
    end_frame: int

    @property
    def length(self) -> int:
        return self.end_frame - self.start_frame


@dataclass
class _TrackArrays:
    frames: np.ndarray  # int64, sorted
    xs: np.ndarray  # float64 (feet or px)
    ys: np.ndarray
    heights_px: np.ndarray  # bbox heights, for pixel-mode scale


class TrackingIndex:
    def __init__(
        self,
        tracking: TrackingResult,
        court: CourtConfig,
        *,
        homography: list[list[float]] | None = None,
        max_interp_gap_s: float = 1.0,
    ) -> None:
        self.tracking = tracking
        self.court = court
        self.fps = float(tracking.video.fps)
        self.step = max(1, round(self.fps / float(tracking.video.analysis_fps)))
        self.max_gap_frames = max(self.step, int(round(max_interp_gap_s * self.fps)))
        self._homographies: list[Homography] = list(tracking.court.homographies)
        if not self._homographies and homography is not None:
            self._homographies = [Homography(frame_start=0, frame_end=None, matrix=homography, source="manual")]
        has_court_samples = any(s.court_xy is not None for t in tracking.tracks for s in t.samples[:50])
        self.coord_mode: Literal["court", "pixel"] = "court" if (has_court_samples or self._homographies) else "pixel"

        self.roles: dict[int, str] = {}
        self.team_ids: dict[int, int | None] = {}
        self._tracks: dict[int, _TrackArrays] = {}
        for track in tracking.tracks:
            self.roles[track.track_id] = track.role
            self.team_ids[track.track_id] = track.team_id
            frames, xs, ys, hs = [], [], [], []
            for s in sorted(track.samples, key=lambda s: s.f):
                xy = self._sample_xy(s.f, s.court_xy, bbox_foot_point(s.bbox))
                if xy is None:
                    continue
                frames.append(s.f)
                xs.append(xy[0])
                ys.append(xy[1])
                hs.append(max(1.0, s.bbox[3] - s.bbox[1]))
            if frames:
                self._tracks[track.track_id] = _TrackArrays(
                    np.asarray(frames, dtype=np.int64),
                    np.asarray(xs, dtype=float),
                    np.asarray(ys, dtype=float),
                    np.asarray(hs, dtype=float),
                )

        ball = sorted(tracking.ball, key=lambda b: b.f)
        self._ball_samples: list[BallSample] = ball
        self._ball_frames = np.asarray([b.f for b in ball], dtype=np.int64)
        ball_xy = [self._sample_xy(b.f, b.court_xy, b.xy) for b in ball]
        self._ball_x = np.asarray([p[0] if p else np.nan for p in ball_xy], dtype=float)
        self._ball_y = np.asarray([p[1] if p else np.nan for p in ball_xy], dtype=float)
        self._ball_holder = np.asarray(
            [b.holder_track_id if b.holder_track_id is not None else -1 for b in ball], dtype=np.int64
        )

    # ------------------------------------------------------------------ setup
    def homography_for_frame(self, frame: int) -> Homography | None:
        for h in self._homographies:
            if h.frame_start <= frame and (h.frame_end is None or frame <= h.frame_end):
                return h
        return None

    def _sample_xy(self, frame: int, court_xy: Point | None, px: Point) -> Point | None:
        if self.coord_mode == "pixel":
            return (float(px[0]), float(px[1]))
        if court_xy is not None:
            return (float(court_xy[0]), float(court_xy[1]))
        h = self.homography_for_frame(frame)
        return apply_homography(h.matrix, px) if h else None

    # ------------------------------------------------------------------ time
    def frame_to_t(self, frame: int) -> float:
        return frame / self.fps

    def t_to_frame(self, t: float) -> int:
        return int(round(t * self.fps))

    def frames_for_seconds(self, seconds: float) -> int:
        return int(round(seconds * self.fps))

    @property
    def last_frame(self) -> int:
        candidates = [int(a.frames[-1]) for a in self._tracks.values()]
        if len(self._ball_frames):
            candidates.append(int(self._ball_frames[-1]))
        return max(candidates) if candidates else max(0, self.tracking.video.frame_count - 1)

    def sample_frames(self, start: int, end: int) -> list[int]:
        """Analysis-rate frames in ``[start, end]`` (aligned to multiples of ``step``)."""
        first = ((max(0, start) + self.step - 1) // self.step) * self.step
        return list(range(first, end + 1, self.step))

    # ------------------------------------------------------------------ tracks
    def track_ids(self, role: str | None = "player") -> list[int]:
        return [tid for tid in self._tracks if role is None or self.roles.get(tid) == role]

    def team_of(self, track_id: int) -> int | None:
        return self.team_ids.get(track_id)

    def track_span(self, track_id: int) -> tuple[int, int] | None:
        arr = self._tracks.get(track_id)
        return (int(arr.frames[0]), int(arr.frames[-1])) if arr is not None else None

    def track_sample_count(self, track_id: int) -> int:
        arr = self._tracks.get(track_id)
        return int(len(arr.frames)) if arr is not None else 0

    def position(self, track_id: int, frame: int, max_gap_frames: int | None = None) -> Point | None:
        """Interpolated position at ``frame`` (None outside the track or across a long gap)."""
        arr = self._tracks.get(track_id)
        if arr is None:
            return None
        gap = self.max_gap_frames if max_gap_frames is None else max_gap_frames
        frames = arr.frames
        i = int(np.searchsorted(frames, frame))
        if i < len(frames) and frames[i] == frame:
            return (float(arr.xs[i]), float(arr.ys[i]))
        if i == 0 or i == len(frames):
            j = 0 if i == 0 else len(frames) - 1
            if abs(int(frames[j]) - frame) <= self.step:
                return (float(arr.xs[j]), float(arr.ys[j]))
            return None
        f0, f1 = int(frames[i - 1]), int(frames[i])
        if f1 - f0 > gap:
            return None
        w = (frame - f0) / (f1 - f0)
        return (
            float(arr.xs[i - 1] + w * (arr.xs[i] - arr.xs[i - 1])),
            float(arr.ys[i - 1] + w * (arr.ys[i] - arr.ys[i - 1])),
        )

    def positions_at(self, frame: int, track_ids: Iterable[int] | None = None, role: str | None = "player") -> dict[int, Point]:
        ids = list(track_ids) if track_ids is not None else self.track_ids(role)
        out: dict[int, Point] = {}
        for tid in ids:
            p = self.position(tid, frame)
            if p is not None:
                out[tid] = p
        return out

    def team_positions_at(self, frame: int, team_id: int) -> dict[int, Point]:
        return {tid: p for tid, p in self.positions_at(frame).items() if self.team_ids.get(tid) == team_id}

    def velocity(self, track_id: int, frame: int, window_s: float = 0.5) -> Point | None:
        """Central-difference velocity in units per second over ``window_s``."""
        half = max(self.step, self.frames_for_seconds(window_s / 2))
        a = self.position(track_id, frame - half)
        b = self.position(track_id, frame + half)
        if a is None or b is None:
            return None
        dt = (2 * half) / self.fps
        return ((b[0] - a[0]) / dt, (b[1] - a[1]) / dt)

    def speed(self, track_id: int, frame: int, window_s: float = 0.5) -> float | None:
        v = self.velocity(track_id, frame, window_s)
        return None if v is None else float(np.hypot(v[0], v[1])) * self.scale_ft(track_id, frame)

    def scale_ft(self, track_id: int, frame: int) -> float:
        """Feet per coordinate unit near this track (1.0 in court mode)."""
        if self.coord_mode == "court":
            return 1.0
        arr = self._tracks.get(track_id)
        if arr is None or not len(arr.frames):
            return 1.0
        i = int(np.clip(np.searchsorted(arr.frames, frame), 0, len(arr.frames) - 1))
        lo, hi = max(0, i - 5), min(len(arr.frames), i + 6)
        height = float(np.median(arr.heights_px[lo:hi]))
        return AVG_PLAYER_HEIGHT_FT / max(height, 1.0)

    def distance_ft(self, track_a: int, track_b: int, frame: int) -> float | None:
        a, b = self.position(track_a, frame), self.position(track_b, frame)
        if a is None or b is None:
            return None
        scale = (self.scale_ft(track_a, frame) + self.scale_ft(track_b, frame)) / 2
        return float(np.hypot(a[0] - b[0], a[1] - b[1])) * scale

    def distance_to_point_ft(self, track_id: int, frame: int, point: Point) -> float | None:
        p = self.position(track_id, frame)
        if p is None:
            return None
        return float(np.hypot(p[0] - point[0], p[1] - point[1])) * self.scale_ft(track_id, frame)

    # ------------------------------------------------------------------ ball
    def _ball_index(self, frame: int, max_gap_frames: int | None = None) -> int | None:
        if not len(self._ball_frames):
            return None
        gap = self.step if max_gap_frames is None else max_gap_frames
        i = int(np.searchsorted(self._ball_frames, frame))
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(self._ball_frames) and abs(int(self._ball_frames[j]) - frame) <= gap:
                if best is None or abs(int(self._ball_frames[j]) - frame) < abs(int(self._ball_frames[best]) - frame):
                    best = j
        return best

    def ball_at(self, frame: int, max_gap_frames: int | None = None) -> BallSample | None:
        i = self._ball_index(frame, max_gap_frames)
        return self._ball_samples[i] if i is not None else None

    def ball_xy(self, frame: int, max_gap_frames: int | None = None) -> Point | None:
        i = self._ball_index(frame, max_gap_frames)
        if i is None or np.isnan(self._ball_x[i]):
            return None
        return (float(self._ball_x[i]), float(self._ball_y[i]))

    def holder_at(self, frame: int, max_gap_frames: int | None = None) -> int | None:
        i = self._ball_index(frame, max_gap_frames)
        if i is None:
            return None
        holder = int(self._ball_holder[i])
        return holder if holder >= 0 else None

    def holder_segments(self, min_frames: int = 0, max_gap_frames: int | None = None) -> list[HolderSegment]:
        """Contiguous runs where one player controls the ball."""
        gap = self.max_gap_frames if max_gap_frames is None else max_gap_frames
        segments: list[HolderSegment] = []
        cur_id, start, last = -1, 0, 0
        for f, h in zip(self._ball_frames.tolist(), self._ball_holder.tolist(), strict=True):
            if h == cur_id and f - last <= gap:
                last = f
                continue
            if cur_id >= 0 and last - start >= min_frames:
                segments.append(HolderSegment(cur_id, self.team_ids.get(cur_id), start, last))
            cur_id, start, last = h, f, f
        if cur_id >= 0 and last - start >= min_frames:
            segments.append(HolderSegment(cur_id, self.team_ids.get(cur_id), start, last))
        return segments

    @property
    def ball_coverage(self) -> float:
        """Fraction of analysed frames with a (non-interpolated) ball detection."""
        expected = max(1, self.tracking.video.frame_count // self.step)
        detected = sum(1 for b in self._ball_samples if not b.interpolated)
        return min(1.0, detected / expected)
