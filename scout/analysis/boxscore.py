"""Timeline -> per-player box score lines and team totals."""

from __future__ import annotations

from scout.analysis.tracking_index import TrackingIndex
from scout.schemas import Possession, Roster, TeamBoxScore, TeamSide, TimelineEvent, TrackAssignment


def build_box_scores(
    timeline: list[TimelineEvent],
    possessions: list[Possession],
    assignments: list[TrackAssignment],
    rosters: dict[TeamSide, Roster],
    team_names: dict[TeamSide, str],
    index: TrackingIndex | None = None,
) -> list[TeamBoxScore]:
    """One ``TeamBoxScore`` per side (SCOUTED first).

    * Every roster player appears (zero line if no events), followed by unrostered
      jerseys seen in the film (``PlayerRef`` without ``player_id``), sorted by jersey.
    * Events whose player is unknown count toward ``team_unattributed``; ``totals`` is the
      sum of players + unattributed.
    * PTS/FGM/FGA/3PM/3PA from SHOT_* rows (``points``/``is_three``), FTM/FTA from FT rows,
      OREB/DREB, AST, STL, BLK, TOV, PF from their rows. Zone splits from ``zone``.
    * ``minutes_est`` from track presence (``index``) summed over the player's tracks,
      in video minutes. ``plus_minus`` from scoring while the player's tracks were present
      (None when presence is unknown).
    * ``possessions``/``points_per_possession`` from ``possessions``.
    """
    raise NotImplementedError
