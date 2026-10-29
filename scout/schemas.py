"""Shared data contracts for Basketball Scout.

Three layers live here:

1. **Tracking contract** (``TrackingResult`` and friends): what the GPU pipeline on
   Modal returns. It is *perception plus raw game events*. Documented in detail in
   ``docs/TRACKING_SCHEMA.md``. All pixel coordinates are in ORIGINAL video
   resolution; all ``frame``/``f`` values are 0-based ORIGINAL video frame numbers
   and ``t = frame / video.fps``.
2. **Analysis output** (``GameAnalysis`` and friends): what the transform module
   (``scout.analysis``) produces after roster matching, possession inference, play
   recognition and box-score aggregation. This is what the UI, exports and the
   Claude report consume.
3. **Domain / API models**: games, rosters, jobs, uploads, reports.

Court coordinates are in feet. Origin is the corner where the LEFT baseline (x=0)
meets the NEAR sideline (y=0, camera side). ``x`` runs along the court length
(0..length_ft), ``y`` across the width (0..width_ft). Baskets sit at
``(basket_from_baseline_ft, width/2)`` and ``(length - basket_from_baseline_ft, width/2)``.
"""

from __future__ import annotations

from datetime import date, datetime
from enum import StrEnum
from typing import Any, Literal
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field, computed_field

TRACKING_SCHEMA_VERSION = "1.0"
ANALYSIS_SCHEMA_VERSION = "1.0"

Point = tuple[float, float]
BBox = tuple[float, float, float, float]


def new_id(prefix: str = "") -> str:
    """Short random id, optionally prefixed (``g_``, ``j_`` ...)."""
    return f"{prefix}{uuid4().hex[:12]}"


class _Model(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)


# ---------------------------------------------------------------------------
# 1. Tracking contract (Modal -> server)
# ---------------------------------------------------------------------------


class VideoInfo(_Model):
    filename: str = ""
    fps: float = Field(gt=0)
    width: int = Field(gt=0)
    height: int = Field(gt=0)
    frame_count: int = Field(ge=0)
    duration_s: float = Field(ge=0)
    analysis_fps: float = Field(gt=0, description="Rate at which frames were analysed / tracks sampled.")
    codec: str | None = None


class PipelineInfo(_Model):
    name: str = Field(description='"openhoopvision", "builtin", "synthetic", ...')
    version: str = "0"
    models: dict[str, str] = Field(default_factory=dict)
    gpu: str | None = None
    elapsed_s: float | None = None
    options: dict[str, Any] = Field(default_factory=dict)


class PipelineWarning(_Model):
    code: str = Field(description='e.g. "NO_COURT_HOMOGRAPHY", "BALL_TRACKING_SPARSE", "GPU_OOM_RECOVERED"')
    message: str
    severity: Literal["info", "warning", "error"] = "warning"


class Homography(_Model):
    """3x3 matrix mapping image pixels ``[px, py, 1]`` (original resolution) to court feet."""

    frame_start: int = 0
    frame_end: int | None = Field(default=None, description="Inclusive. None = until the end of the video.")
    matrix: list[list[float]]
    reprojection_error_px: float | None = None
    source: Literal["model", "manual", "classical"] = "model"


class CourtInfo(_Model):
    length_ft: float = 84.0
    width_ft: float = 50.0
    homographies: list[Homography] = Field(default_factory=list)

    @property
    def homography_available(self) -> bool:
        return bool(self.homographies)


class TeamInfo(_Model):
    team_id: int = Field(description="Pipeline cluster id (usually 0 or 1). Not the same as TeamSide.")
    color_rgb: tuple[int, int, int] | None = None
    color_name: str | None = None
    track_count: int = 0


class JerseyRead(_Model):
    frame: int
    text: str = Field(description="Raw OCR string (may be noisy, e.g. '2', '23', '2B').")
    conf: float = Field(ge=0, le=1)


class TrackSample(_Model):
    f: int
    bbox: BBox
    court_xy: Point | None = Field(default=None, description="Feet; bottom-centre of bbox projected with the homography.")
    conf: float = 1.0


class Track(_Model):
    track_id: int
    team_id: int | None = None
    role: Literal["player", "referee", "unknown"] = "player"
    jersey_reads: list[JerseyRead] = Field(default_factory=list)
    samples: list[TrackSample] = Field(default_factory=list, description="Sorted by frame, one per analysed frame.")

    @property
    def first_frame(self) -> int | None:
        return self.samples[0].f if self.samples else None

    @property
    def last_frame(self) -> int | None:
        return self.samples[-1].f if self.samples else None


class BallSample(_Model):
    f: int
    xy: Point = Field(description="Ball centre in pixels.")
    court_xy: Point | None = Field(default=None, description="Ground-plane projection of the ball (approximate when airborne).")
    conf: float = 1.0
    holder_track_id: int | None = Field(default=None, description="Player controlling the ball at this frame, if any.")
    interpolated: bool = False


class RimInfo(_Model):
    side: Literal["left", "right"]
    xy_px: Point
    frame_start: int = 0
    frame_end: int | None = None


class RawEventType(StrEnum):
    SHOT = "shot"
    FREE_THROW = "free_throw"
    REBOUND = "rebound"
    PASS = "pass"
    TURNOVER = "turnover"
    FOUL = "foul"
    SCREEN = "screen"
    JUMP_BALL = "jump_ball"
    PERIOD_START = "period_start"
    PERIOD_END = "period_end"
    TIMEOUT = "timeout"


# Attribute keys used in RawEvent.attrs (see docs/TRACKING_SCHEMA.md).
# Steals, blocks and assists are NOT separate raw events: they are attributes of
# the turnover / shot event so nothing can be double counted.
ATTR_MADE = "made"  # shot, free_throw: bool | None
ATTR_IS_THREE = "is_three"  # shot: bool | None (pipeline's own call; server geometry wins when court coords exist)
ATTR_SHOT_XY_PX = "shot_xy_px"  # shot: [x, y] shooter's feet in pixels
ATTR_SHOT_COURT_XY = "shot_court_xy"  # shot: [x, y] feet
ATTR_ASSISTED_BY = "assisted_by_track"  # shot: int | None
ATTR_BLOCKED_BY = "blocked_by_track"  # shot: int | None
ATTR_PUTBACK = "putback"  # shot: bool
ATTR_OFFENSIVE = "offensive"  # rebound: bool | None
ATTR_TO_TRACK = "to_track"  # pass: int
ATTR_KIND = "kind"  # turnover: steal|bad_pass|travel|out_of_bounds|offensive_foul|other ; foul: personal|shooting|offensive|technical
ATTR_STOLEN_BY = "stolen_by_track"  # turnover: int | None
ATTR_FOULED_TRACK = "fouled_track"  # foul: int | None
ATTR_BALL_HANDLER = "ball_handler_track"  # screen: int | None
ATTR_ON_BALL = "on_ball"  # screen: bool
ATTR_PERIOD = "period"  # period_start / period_end: int
ATTR_WON_BY_TEAM = "won_by_team"  # jump_ball: pipeline team id


class RawEvent(_Model):
    event_id: str
    type: RawEventType
    frame: int
    t: float
    track_id: int | None = Field(default=None, description="Primary actor (shooter, rebounder, passer, player losing the ball, fouler, screener).")
    team_id: int | None = Field(default=None, description="Pipeline team id of the primary actor (or of the team for team events).")
    conf: float = Field(default=0.5, ge=0, le=1)
    attrs: dict[str, Any] = Field(default_factory=dict)


class TrackingResult(_Model):
    schema_version: str = TRACKING_SCHEMA_VERSION
    job_id: str | None = None
    video: VideoInfo
    pipeline: PipelineInfo
    court: CourtInfo = Field(default_factory=CourtInfo)
    teams: list[TeamInfo] = Field(default_factory=list)
    tracks: list[Track] = Field(default_factory=list)
    ball: list[BallSample] = Field(default_factory=list)
    events: list[RawEvent] = Field(default_factory=list)
    rims: list[RimInfo] = Field(default_factory=list)
    warnings: list[PipelineWarning] = Field(default_factory=list)
    artifacts: dict[str, str] = Field(default_factory=dict, description="Logical name -> path relative to the Modal volume root.")


# ---------------------------------------------------------------------------
# 2. Analysis output
# ---------------------------------------------------------------------------


class TeamSide(StrEnum):
    SCOUTED = "scouted"  # the opponent we are scouting
    OTHER = "other"  # whoever they played in this film (often not us)


class ShotZone(StrEnum):
    PAINT = "paint"
    MID = "mid"
    THREE = "three"
    UNKNOWN = "unknown"


class PlayerRef(_Model):
    player_id: str | None = Field(default=None, description="RosterPlayer.id when matched to a roster.")
    jersey: str | None = None
    name: str | None = None
    side: TeamSide | None = None
    match_confidence: float = 0.0

    @computed_field  # type: ignore[prop-decorator]
    @property
    def label(self) -> str:
        if self.jersey and self.name:
            return f"#{self.jersey} {self.name}"
        if self.jersey:
            return f"#{self.jersey}"
        return self.name or "Unknown player"


class EventType(StrEnum):
    SHOT_MADE = "shot_made"
    SHOT_MISSED = "shot_missed"
    FT_MADE = "ft_made"
    FT_MISSED = "ft_missed"
    OREB = "oreb"
    DREB = "dreb"
    ASSIST = "assist"
    STEAL = "steal"
    BLOCK = "block"
    TURNOVER = "turnover"
    FOUL = "foul"
    SCREEN = "screen"
    PASS = "pass"
    JUMP_BALL = "jump_ball"
    PERIOD_START = "period_start"
    PERIOD_END = "period_end"
    TIMEOUT = "timeout"
    POSSESSION_CHANGE = "possession_change"


class TimelineEvent(_Model):
    id: str
    t: float
    frame: int
    type: EventType
    label: str = Field(description='Human readable, e.g. "3PT Make", "Def. Rebound", "Steal".')
    side: TeamSide | None = None
    player: PlayerRef | None = None
    secondary_player: PlayerRef | None = Field(default=None, description="Assister, blocker, stealer, player stolen from, fouled player...")
    possession_side: TeamSide | None = Field(default=None, description="Team in possession at this moment (the possession indicator).")
    possession_id: int | None = None
    points: int = 0
    is_three: bool | None = None
    zone: ShotZone | None = None
    subzone: str | None = None
    court_xy: Point | None = None
    confidence: float = 0.5
    play_id: str | None = None
    source_event_id: str | None = Field(default=None, description="RawEvent.event_id this row was derived from.")
    score_scouted: int = 0
    score_other: int = 0
    description: str = ""


class PossessionOutcome(StrEnum):
    MADE_FG = "made_fg"
    MISSED_FG = "missed_fg"
    TURNOVER = "turnover"
    FREE_THROWS = "free_throws"
    FOUL = "foul"
    END_OF_PERIOD = "end_of_period"
    UNKNOWN = "unknown"


class Possession(_Model):
    id: int
    side: TeamSide | None
    start_t: float
    end_t: float
    start_frame: int
    end_frame: int
    outcome: PossessionOutcome = PossessionOutcome.UNKNOWN
    points: int = 0
    start_reason: str = Field(default="", description="def_rebound, steal, turnover, made_basket, jump_ball, period_start, inferred ...")
    transition: bool = False
    event_ids: list[str] = Field(default_factory=list)
    play_ids: list[str] = Field(default_factory=list)


class PlayType(StrEnum):
    PICK_AND_ROLL = "pick_and_roll"
    PICK_AND_POP = "pick_and_pop"
    ISOLATION = "isolation"
    FAST_BREAK = "fast_break"
    POST_UP = "post_up"
    HANDOFF = "handoff"
    OFF_BALL_SCREEN = "off_ball_screen"
    SPOT_UP = "spot_up"
    CUT = "cut"
    PUTBACK = "putback"
    MAN_DEFENSE = "man_defense"
    ZONE_DEFENSE = "zone_defense"
    PRESS = "press"


OFFENSIVE_PLAY_TYPES = frozenset(
    {
        PlayType.PICK_AND_ROLL,
        PlayType.PICK_AND_POP,
        PlayType.ISOLATION,
        PlayType.FAST_BREAK,
        PlayType.POST_UP,
        PlayType.HANDOFF,
        PlayType.OFF_BALL_SCREEN,
        PlayType.SPOT_UP,
        PlayType.CUT,
        PlayType.PUTBACK,
    }
)
DEFENSIVE_PLAY_TYPES = frozenset({PlayType.MAN_DEFENSE, PlayType.ZONE_DEFENSE, PlayType.PRESS})

PLAY_TYPE_LABELS: dict[PlayType, str] = {
    PlayType.PICK_AND_ROLL: "Pick & Roll",
    PlayType.PICK_AND_POP: "Pick & Pop",
    PlayType.ISOLATION: "Isolation",
    PlayType.FAST_BREAK: "Fast Break",
    PlayType.POST_UP: "Post-Up",
    PlayType.HANDOFF: "Dribble Handoff",
    PlayType.OFF_BALL_SCREEN: "Off-Ball Screen",
    PlayType.SPOT_UP: "Spot-Up",
    PlayType.CUT: "Cut",
    PlayType.PUTBACK: "Putback",
    PlayType.MAN_DEFENSE: "Man-to-Man Defense",
    PlayType.ZONE_DEFENSE: "Zone Defense",
    PlayType.PRESS: "Full-Court Press",
}


class PlayOutcome(StrEnum):
    MADE_FG = "made_fg"
    MISSED_FG = "missed_fg"
    TURNOVER = "turnover"
    FOUL = "foul"
    NO_SHOT = "no_shot"
    UNKNOWN = "unknown"


class Play(_Model):
    id: str
    type: PlayType
    category: Literal["offense", "defense"]
    side: TeamSide | None = Field(description="Team running the play (offense) or playing the defense.")
    start_t: float
    end_t: float
    start_frame: int
    end_frame: int
    possession_id: int | None = None
    players: dict[str, PlayerRef] = Field(default_factory=dict, description='Role -> player, e.g. {"ball_handler": ..., "screener": ...}.')
    outcome: PlayOutcome = PlayOutcome.UNKNOWN
    points: int = 0
    confidence: float = 0.5
    attrs: dict[str, Any] = Field(default_factory=dict, description='e.g. {"screen_side": "left", "zone_shape": "2-3", "numbers": "3v2"}.')
    description: str = ""


class ShootingSplit(_Model):
    made: int = 0
    attempts: int = 0

    @computed_field  # type: ignore[prop-decorator]
    @property
    def pct(self) -> float | None:
        return round(self.made / self.attempts, 3) if self.attempts else None


class ZoneSplits(_Model):
    paint: ShootingSplit = Field(default_factory=ShootingSplit)
    mid: ShootingSplit = Field(default_factory=ShootingSplit)
    three: ShootingSplit = Field(default_factory=ShootingSplit)
    unknown: ShootingSplit = Field(default_factory=ShootingSplit)


class BoxScoreLine(_Model):
    player: PlayerRef
    minutes_est: float | None = Field(default=None, description="Approximate on-floor VIDEO minutes from track presence (includes stoppages).")
    pts: int = 0
    fgm: int = 0
    fga: int = 0
    tpm: int = 0
    tpa: int = 0
    ftm: int = 0
    fta: int = 0
    oreb: int = 0
    dreb: int = 0
    ast: int = 0
    stl: int = 0
    blk: int = 0
    tov: int = 0
    pf: int = 0
    plus_minus: int | None = None
    zones: ZoneSplits = Field(default_factory=ZoneSplits)

    @computed_field  # type: ignore[prop-decorator]
    @property
    def reb(self) -> int:
        return self.oreb + self.dreb

    @computed_field  # type: ignore[prop-decorator]
    @property
    def fg_pct(self) -> float | None:
        return round(self.fgm / self.fga, 3) if self.fga else None

    @computed_field  # type: ignore[prop-decorator]
    @property
    def tp_pct(self) -> float | None:
        return round(self.tpm / self.tpa, 3) if self.tpa else None

    @computed_field  # type: ignore[prop-decorator]
    @property
    def ft_pct(self) -> float | None:
        return round(self.ftm / self.fta, 3) if self.fta else None


class TeamBoxScore(_Model):
    side: TeamSide
    team_name: str
    players: list[BoxScoreLine] = Field(default_factory=list)
    team_unattributed: BoxScoreLine = Field(description="Stats credited to the team but no identified player.")
    totals: BoxScoreLine
    possessions: int = 0
    points_per_possession: float | None = None


class ShotRecord(_Model):
    event_id: str
    t: float
    side: TeamSide | None
    player: PlayerRef | None = None
    made: bool
    points: int
    is_three: bool | None = None
    zone: ShotZone = ShotZone.UNKNOWN
    subzone: str | None = None
    court_xy: Point | None = None
    half_court_xy: Point | None = Field(
        default=None,
        description="Shot location normalised to a half court: x = feet from the attacked baseline, y = feet from the offense's left sideline.",
    )
    assisted: bool = False
    blocked: bool = False
    play_id: str | None = None


class PlayTypeSummary(_Model):
    type: PlayType
    category: Literal["offense", "defense"]
    side: TeamSide | None
    count: int = 0
    possessions_pct: float | None = Field(default=None, description="Share of the side's possessions featuring this play (0..1).")
    points: int = 0
    ppp: float | None = None
    fgm: int = 0
    fga: int = 0
    turnovers: int = 0


class TrackAssignment(_Model):
    track_id: int
    team_id: int | None = None
    side: TeamSide | None = None
    role: str = "player"
    player_id: str | None = None
    jersey: str | None = Field(default=None, description="Resolved jersey: roster jersey when matched, else best OCR read.")
    best_read: str | None = None
    votes: dict[str, float] = Field(default_factory=dict)
    match_score: float = 0.0
    method: Literal["exact", "fuzzy", "partial", "manual", "unrostered", "none"] = "none"
    frames: int = Field(default=0, description="Number of samples (presence) for this track.")
    ignored: bool = False


class TeamSummary(_Model):
    side: TeamSide
    name: str
    team_id: int | None = Field(default=None, description="Pipeline team id mapped to this side.")
    color_rgb: tuple[int, int, int] | None = None
    color_name: str | None = None
    score: int = 0


class DataQuality(_Model):
    homography_available: bool = False
    coord_mode: Literal["court", "pixel"] = "pixel"
    ball_coverage: float = 0.0
    jersey_match_rate: float = 0.0
    unmatched_jerseys: list[str] = Field(default_factory=list, description='e.g. ["scouted:#14", "other:#3"]')
    tracks_total: int = 0
    tracks_assigned: int = 0
    event_confidence_mean: float | None = None
    warnings: list[PipelineWarning] = Field(default_factory=list)


class GameAnalysis(_Model):
    schema_version: str = ANALYSIS_SCHEMA_VERSION
    game_id: str
    generated_at: datetime
    video: VideoInfo
    pipeline: PipelineInfo
    teams: list[TeamSummary]
    timeline: list[TimelineEvent] = Field(default_factory=list)
    possessions: list[Possession] = Field(default_factory=list)
    plays: list[Play] = Field(default_factory=list)
    shots: list[ShotRecord] = Field(default_factory=list)
    box_scores: list[TeamBoxScore] = Field(default_factory=list)
    play_summary: list[PlayTypeSummary] = Field(default_factory=list)
    track_assignments: list[TrackAssignment] = Field(default_factory=list)
    data_quality: DataQuality = Field(default_factory=DataQuality)

    def team(self, side: TeamSide) -> TeamSummary | None:
        return next((t for t in self.teams if t.side == side), None)

    def box_score(self, side: TeamSide) -> TeamBoxScore | None:
        return next((b for b in self.box_scores if b.side == side), None)


# ---------------------------------------------------------------------------
# 3. Domain / API models
# ---------------------------------------------------------------------------


class RosterPlayer(_Model):
    id: str = Field(default_factory=lambda: new_id("p_"))
    jersey: str = Field(min_length=1, max_length=3, description='Digits as typed; "0" and "00" are different numbers.')
    first_name: str = ""
    last_name: str = ""
    position: str | None = None
    grade: str | None = None
    height: str | None = None
    notes: str | None = None
    fastscout_name: str | None = Field(
        default=None, description="Exact spelling used in the coach's FastScout roster (paste matching is by name)."
    )

    @computed_field  # type: ignore[prop-decorator]
    @property
    def name(self) -> str:
        return " ".join(p for p in (self.first_name.strip(), self.last_name.strip()) if p)


class Roster(_Model):
    game_id: str
    side: TeamSide
    team_name: str = ""
    players: list[RosterPlayer] = Field(default_factory=list)
    updated_at: datetime | None = None

    def by_id(self, player_id: str) -> RosterPlayer | None:
        return next((p for p in self.players if p.id == player_id), None)


class RosterImportResult(_Model):
    roster: Roster
    imported: int = 0
    skipped_rows: list[dict[str, Any]] = Field(default_factory=list, description='[{"row": 7, "reason": "missing jersey"}]')
    warnings: list[str] = Field(default_factory=list)
    detected_columns: dict[str, str] = Field(default_factory=dict, description="Canonical field -> source header.")


class TrackOverride(_Model):
    track_id: int
    player_id: str | None = Field(default=None, description="None = explicitly unassigned (keep the side).")
    side: TeamSide | None = None
    ignore: bool = Field(default=False, description="Exclude the track entirely (bench player, fan, coach).")


class CalibrationPoint(_Model):
    landmark: str = Field(description="Landmark name from GET /api/court/landmarks.")
    px: Point = Field(description="Pixel position in ORIGINAL video resolution.")


class CourtCalibration(_Model):
    points: list[CalibrationPoint]
    matrix: list[list[float]] = Field(description="Pixel -> court feet homography.")
    reprojection_error_ft: float
    frame_t: float | None = None
    video_width: int | None = None
    video_height: int | None = None
    created_at: datetime | None = None


class ErrorInfo(_Model):
    code: str
    title: str
    message: str
    hint: str | None = None
    retryable: bool = False
    detail: str | None = None


class GameStatus(StrEnum):
    DRAFT = "draft"  # created, no video yet
    UPLOADED = "uploaded"  # video present, not queued
    QUEUED = "queued"
    PROCESSING = "processing"
    READY = "ready"
    FAILED = "failed"


class GameCreate(_Model):
    scouted_team: str = Field(min_length=1, max_length=120)
    other_team: str = Field(default="", max_length=120)
    title: str | None = Field(default=None, max_length=200)
    game_date: date | None = None
    location: str | None = Field(default=None, max_length=200)
    level: str | None = Field(default=None, max_length=40, description="Varsity, JV, ...")
    notes: str | None = Field(default=None, max_length=5000)
    scouted_color: str | None = Field(default=None, max_length=40, description='"light", "dark", "#1a2b3c" or a colour word.')


class GameUpdate(_Model):
    scouted_team: str | None = Field(default=None, min_length=1, max_length=120)
    other_team: str | None = Field(default=None, max_length=120)
    title: str | None = Field(default=None, max_length=200)
    game_date: date | None = None
    location: str | None = Field(default=None, max_length=200)
    level: str | None = Field(default=None, max_length=40)
    notes: str | None = Field(default=None, max_length=5000)
    scouted_color: str | None = Field(default=None, max_length=40)
    team_id_map: dict[int, TeamSide] | None = None


class Game(_Model):
    id: str = Field(default_factory=lambda: new_id("g_"))
    title: str = ""
    scouted_team: str
    other_team: str = ""
    game_date: date | None = None
    location: str | None = None
    level: str | None = None
    notes: str | None = None
    scouted_color: str | None = None
    team_id_map: dict[int, TeamSide] = Field(default_factory=dict, description="Pipeline team id -> side. Empty = auto.")
    status: GameStatus = GameStatus.DRAFT
    video_filename: str | None = None
    video_size: int | None = None
    video_url: str | None = Field(default=None, description="Remote source URL when the film was not uploaded.")
    has_video: bool = False
    has_annotated_video: bool = False
    has_analysis: bool = False
    calibration: CourtCalibration | None = None
    latest_job_id: str | None = None
    error: ErrorInfo | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None

    @computed_field  # type: ignore[prop-decorator]
    @property
    def display_title(self) -> str:
        if self.title:
            return self.title
        if self.other_team:
            return f"{self.scouted_team} vs {self.other_team}"
        return self.scouted_team


class JobKind(StrEnum):
    ANALYZE = "analyze"  # GPU processing + transform (+ report)
    REANALYZE = "reanalyze"  # transform only, from stored tracking.json.gz (after roster/override edits)
    REPORT = "report"  # Claude scouting report only


class JobStatus(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLED = "cancelled"


ACTIVE_JOB_STATUSES = frozenset({JobStatus.QUEUED, JobStatus.RUNNING})


class JobStage(StrEnum):
    QUEUED = "queued"
    PREPARING = "preparing"
    UPLOADING = "uploading_to_gpu"
    GPU_PROCESSING = "gpu_processing"
    DOWNLOADING = "downloading_results"
    ANALYZING = "analyzing"
    REPORTING = "reporting"
    DONE = "done"


class Job(_Model):
    id: str = Field(default_factory=lambda: new_id("j_"))
    game_id: str
    kind: JobKind
    status: JobStatus = JobStatus.QUEUED
    stage: JobStage = JobStage.QUEUED
    progress: float = Field(default=0.0, ge=0, le=100)
    message: str = ""
    error: ErrorInfo | None = None
    warnings: list[str] = Field(default_factory=list)
    params: dict[str, Any] = Field(default_factory=dict)
    attempts: int = 0
    max_attempts: int = 3
    processor: str | None = None
    external_id: str | None = Field(default=None, description="Processor handle, e.g. the Modal FunctionCall id.")
    cancel_requested: bool = False
    worker_id: str | None = None
    lease_expires_at: float | None = Field(default=None, description="Epoch seconds.")
    created_at: datetime | None = None
    started_at: datetime | None = None
    finished_at: datetime | None = None
    updated_at: datetime | None = None


class UploadInit(_Model):
    filename: str = Field(min_length=1, max_length=255)
    size: int = Field(gt=0)
    content_type: str | None = None


class UploadSession(_Model):
    id: str = Field(default_factory=lambda: new_id("u_"))
    game_id: str
    filename: str
    size: int
    received: int = 0
    chunk_size: int
    status: Literal["open", "complete", "aborted"] = "open"
    created_at: datetime | None = None
    updated_at: datetime | None = None


class VideoUrlRequest(_Model):
    url: str = Field(min_length=8, max_length=2000)
    filename: str | None = None


class JobCreate(_Model):
    kind: JobKind
    params: dict[str, Any] = Field(default_factory=dict)


class ReportRequest(_Model):
    coach_focus: str | None = Field(default=None, max_length=2000, description="Optional extra instructions, e.g. 'we play a 2-3 zone'.")


class KeyPlayer(_Model):
    jersey: str
    name: str
    role: str
    threat_level: Literal["high", "medium", "low"]
    strengths: list[str]
    weaknesses: list[str]
    how_to_defend: str


class PlayTendency(_Model):
    play_type: str
    frequency: str
    effectiveness: str
    counter: str


class ScoutingReport(_Model):
    headline: str
    executive_summary: str
    offensive_identity: list[str]
    defensive_identity: list[str]
    key_players: list[KeyPlayer]
    play_tendencies: list[PlayTendency]
    transition: list[str]
    special_situations: list[str]
    keys_to_win: list[str]
    defensive_game_plan: list[str]
    offensive_game_plan: list[str]
    practice_emphasis: list[str]
    data_caveats: list[str]


class ReportRecord(_Model):
    id: str = Field(default_factory=lambda: new_id("r_"))
    game_id: str
    created_at: datetime | None = None
    model: str
    coach_focus: str | None = None
    report: ScoutingReport
    markdown: str
    usage: dict[str, int] = Field(default_factory=dict)
    stop_reason: str | None = None


class HealthStatus(_Model):
    status: Literal["ok", "degraded"] = "ok"
    version: str
    processor: str
    queue_backend: str
    queue_ok: bool = True
    modal_configured: bool = False
    claude_configured: bool = False
    ffmpeg_available: bool = False
    worker_last_seen_s: float | None = Field(default=None, description="Seconds since the last worker heartbeat.")
    auth_enabled: bool = True
