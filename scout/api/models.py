"""Request/response bodies that exist only at the HTTP layer.

Domain models (Game, Job, Roster, ...) live in ``scout.schemas``; these wrap them in
the shapes listed in docs/ARCHITECTURE.md ("HTTP API").
"""

from __future__ import annotations

from pydantic import BaseModel, Field

from scout.schemas import (
    CalibrationPoint,
    Game,
    Job,
    Roster,
    RosterPlayer,
    TeamSide,
    TrackAssignment,
    TrackOverride,
)


class FilmResult(BaseModel):
    """Response of upload ``complete`` and ``video-url``: the game plus the auto-started job."""

    game: Game
    job: Job | None = None


class CalibrationRequest(BaseModel):
    points: list[CalibrationPoint] = Field(min_length=1, max_length=40)
    frame_t: float | None = Field(default=None, ge=0)
    video_width: int | None = Field(default=None, gt=0)
    video_height: int | None = Field(default=None, gt=0)


class GameRosters(BaseModel):
    scouted: Roster
    other: Roster


class RosterReplace(BaseModel):
    """``PUT /rosters/{side}``: the full player list (ids are kept when given)."""

    team_name: str | None = Field(default=None, max_length=120)
    players: list[RosterPlayer] = Field(max_length=200)


class RosterPlayerPatch(BaseModel):
    """Partial ``RosterPlayer`` for ``PATCH``; only the fields sent are changed."""

    jersey: str | None = Field(default=None, min_length=1, max_length=3)
    first_name: str | None = None
    last_name: str | None = None
    position: str | None = None
    grade: str | None = None
    height: str | None = None
    notes: str | None = None
    fastscout_name: str | None = None


class TrackOverrideBody(BaseModel):
    """``TrackOverride`` with ``track_id`` optional: the id in the URL always wins."""

    track_id: int | None = None
    player_id: str | None = None
    side: TeamSide | None = None
    ignore: bool = False


class TrackState(BaseModel):
    assignments: list[TrackAssignment]
    overrides: list[TrackOverride]


class FastScoutNotes(BaseModel):
    """``GET /export/fastscout-notes``: what to check before pasting, and the team numbers typed in by hand."""

    warnings: list[str]
    team_numbers: str
