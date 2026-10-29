"""FastScout exports.

* ``build_paste_block``: plain-text block for pasting into the FastScout Stats
  Database (player box-score lines).
* ``build_custom_table_csv``: CSV for FastScout Web custom tables.
* ``build_timeline_csv``: the full event timeline (for spreadsheets).

Column order, headers, delimiter and name formatting come from
``config/fastscout_columns.yaml`` so they can be adjusted if FastScout changes its
import format. See ``docs/FASTSCOUT.md``.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from scout.schemas import Game, GameAnalysis, TeamSide


def load_fastscout_config(path: Path | str | None = None) -> dict[str, Any]:
    """Load and validate the column mapping (defaults to settings.fastscout_config)."""
    raise NotImplementedError


def build_paste_block(
    analysis: GameAnalysis, game: Game, side: TeamSide = TeamSide.SCOUTED, config: dict[str, Any] | None = None
) -> str:
    raise NotImplementedError


def list_custom_tables(config: dict[str, Any] | None = None) -> list[str]:
    raise NotImplementedError


def build_custom_table_csv(
    analysis: GameAnalysis,
    game: Game,
    side: TeamSide = TeamSide.SCOUTED,
    table: str | None = None,
    config: dict[str, Any] | None = None,
) -> str:
    raise NotImplementedError


def build_timeline_csv(analysis: GameAnalysis) -> str:
    raise NotImplementedError
