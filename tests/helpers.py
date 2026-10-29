"""Small builders for hand-made TrackingResults in unit tests."""

from __future__ import annotations

from scout.schemas import (
    BallSample,
    CourtInfo,
    Homography,
    JerseyRead,
    PipelineInfo,
    RawEvent,
    RawEventType,
    TeamInfo,
    Track,
    TrackingResult,
    TrackSample,
    VideoInfo,
)

IDENTITY = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]


def video_info(duration_s: float = 120.0, fps: float = 30.0, analysis_fps: float = 10.0) -> VideoInfo:
    return VideoInfo(
        filename="test.mp4",
        fps=fps,
        width=1920,
        height=1080,
        frame_count=int(duration_s * fps),
        duration_s=duration_s,
        analysis_fps=analysis_fps,
    )


def track(
    track_id: int,
    team_id: int | None,
    path: list[tuple[int, float, float]],
    *,
    jersey: str | None = None,
    role: str = "player",
    court: bool = True,
) -> Track:
    """``path`` = [(frame, x, y)] in court feet (court=True) or pixels (court=False)."""
    samples = []
    for f, x, y in path:
        bbox = (x - 20.0, y - 120.0, x + 20.0, y) if not court else (0.0, 0.0, 10.0, 60.0)
        samples.append(TrackSample(f=f, bbox=bbox, court_xy=(x, y) if court else None))
    reads = [JerseyRead(frame=path[0][0], text=jersey, conf=0.9)] if jersey and path else []
    return Track(track_id=track_id, team_id=team_id, role=role, jersey_reads=reads, samples=samples)  # type: ignore[arg-type]


def ball(path: list[tuple[int, float, float, int | None]], *, court: bool = True) -> list[BallSample]:
    """``path`` = [(frame, x, y, holder_track_id)]."""
    return [BallSample(f=f, xy=(x, y), court_xy=(x, y) if court else None, holder_track_id=h) for f, x, y, h in path]


def event(event_id: str, type_: RawEventType | str, frame: int, *, fps: float = 30.0, track_id=None, team_id=None, conf=0.9, **attrs) -> RawEvent:
    return RawEvent(event_id=event_id, type=RawEventType(type_), frame=frame, t=frame / fps, track_id=track_id, team_id=team_id, conf=conf, attrs=attrs)


def tracking(
    tracks: list[Track],
    *,
    balls: list[BallSample] | None = None,
    events: list[RawEvent] | None = None,
    duration_s: float = 120.0,
    homography: bool = True,
) -> TrackingResult:
    court = CourtInfo(homographies=[Homography(matrix=IDENTITY)] if homography else [])
    return TrackingResult(
        video=video_info(duration_s),
        pipeline=PipelineInfo(name="test", version="0"),
        court=court,
        teams=[TeamInfo(team_id=0, color_rgb=(20, 20, 60), color_name="navy"), TeamInfo(team_id=1, color_rgb=(240, 240, 240), color_name="white")],
        tracks=tracks,
        ball=balls or [],
        events=events or [],
    )
