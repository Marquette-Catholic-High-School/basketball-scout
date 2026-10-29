"""Map pipeline team clusters (team_id 0/1) onto TeamSide (scouted / other)."""

from __future__ import annotations

from scout.schemas import Game, TeamSide, TrackingResult


def resolve_team_map(tracking: TrackingResult, game: Game) -> dict[int, TeamSide]:
    """Return ``{pipeline team_id: TeamSide}`` for every team id present in ``tracking``.

    Priority:
    1. ``game.team_id_map`` when the coach set it explicitly (UI "which team is the opponent?").
    2. ``game.scouted_color`` hint ("light"/"dark"/"#rrggbb"/colour word such as "navy")
       compared against ``TeamInfo.color_rgb`` / ``color_name`` (luminance for light/dark,
       nearest colour otherwise).
    3. Fallback: team 0 -> SCOUTED, team 1 -> OTHER (any further ids -> OTHER).
    Never maps two team ids to the same side unless there are more than two ids.
    """
    raise NotImplementedError


def side_of(team_map: dict[int, TeamSide], team_id: int | None) -> TeamSide | None:
    """``team_map.get(team_id)``, tolerating ``None``."""
    raise NotImplementedError
