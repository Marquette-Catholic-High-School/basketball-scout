"""In-memory perception data passed between pipeline stages.

Perception stages (``video``, ``detect``, ``track``, ``pose``, ``ocr``, ``teams``,
``court``, ``ball``) fill a :class:`Perception`; ``possession.assign_ball_holders`` and
``events.detect_events`` turn it into raw game events; ``result.build_tracking_result``
serialises everything into the TrackingResult dict defined in ``scout/schemas.py`` /
``docs/TRACKING_SCHEMA.md``.

Conventions: frames are ORIGINAL video frame numbers; pixels are ORIGINAL video
resolution (stages that run on a downscaled frame must scale coordinates back);
court coordinates are feet in the court frame described in ``scout/schemas.py``.
Pure Python only -- no heavy imports in this module.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

BBox = tuple[float, float, float, float]
XY = tuple[float, float]

# COCO-17 keypoint indices (RTMPose body models use this order).
KP_NOSE = 0
KP_L_SHOULDER, KP_R_SHOULDER = 5, 6
KP_L_ELBOW, KP_R_ELBOW = 7, 8
KP_L_WRIST, KP_R_WRIST = 9, 10
KP_L_HIP, KP_R_HIP = 11, 12
KP_L_KNEE, KP_R_KNEE = 13, 14
KP_L_ANKLE, KP_R_ANKLE = 15, 16


@dataclass
class VideoMeta:
    path: str
    filename: str
    fps: float
    width: int
    height: int
    frame_count: int
    duration_s: float
    analysis_fps: float
    step: int  # analyse every `step`-th original frame
    codec: str | None = None

    def frame_to_t(self, frame: int) -> float:
        return frame / self.fps


@dataclass
class TrackObs:
    frame: int
    bbox: BBox
    conf: float
    court_xy: XY | None = None
    keypoints: list[tuple[float, float, float]] | None = None  # 17 x (x, y, score); kept on a subset of frames


@dataclass
class TrackData:
    track_id: int
    obs: list[TrackObs] = field(default_factory=list)  # sorted by frame
    team_id: int | None = None
    role: str = "player"  # player | referee | unknown
    jersey_reads: list[tuple[int, str, float]] = field(default_factory=list)  # (frame, text, conf)
    color_feature: list[float] | None = None

    def obs_at(self, frame: int) -> TrackObs | None:
        lo, hi = 0, len(self.obs) - 1
        while lo <= hi:
            mid = (lo + hi) // 2
            f = self.obs[mid].frame
            if f == frame:
                return self.obs[mid]
            if f < frame:
                lo = mid + 1
            else:
                hi = mid - 1
        return None


@dataclass
class BallObs:
    frame: int
    xy: XY
    conf: float
    court_xy: XY | None = None
    holder_track_id: int | None = None
    interpolated: bool = False


@dataclass
class RimObs:
    side: str  # "left" | "right" as seen in the image
    xy_px: XY  # rim centre
    bbox: BBox | None = None
    frame_start: int = 0
    frame_end: int | None = None


@dataclass
class HomographySeg:
    frame_start: int
    frame_end: int | None
    matrix: list[list[float]]  # pixels -> court feet
    error_px: float | None = None
    source: str = "model"  # model | manual | classical


@dataclass
class Perception:
    video: VideoMeta
    tracks: dict[int, TrackData] = field(default_factory=dict)
    ball: list[BallObs] = field(default_factory=list)  # sorted by frame, at most one per frame
    rims: list[RimObs] = field(default_factory=list)
    homographies: list[HomographySeg] = field(default_factory=list)
    teams: list[dict[str, Any]] = field(default_factory=list)  # {"team_id", "color_rgb", "color_name", "track_count"}
    court_length_ft: float = 84.0
    court_width_ft: float = 50.0
    warnings: list[dict[str, str]] = field(default_factory=list)

    def warn(self, code: str, message: str, severity: str = "warning") -> None:
        if not any(w["code"] == code for w in self.warnings):
            self.warnings.append({"code": code, "message": message, "severity": severity})

    def homography_for(self, frame: int) -> HomographySeg | None:
        for seg in self.homographies:
            if seg.frame_start <= frame and (seg.frame_end is None or frame <= seg.frame_end):
                return seg
        return None

    def player_tracks(self) -> list[TrackData]:
        return [t for t in self.tracks.values() if t.role == "player"]
