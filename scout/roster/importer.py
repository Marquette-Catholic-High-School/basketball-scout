"""Roster file import (CSV / TSV / TXT / XLSX) with flexible header detection."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal

from scout.schemas import Roster, RosterPlayer


@dataclass
class RosterParseResult:
    players: list[RosterPlayer]
    skipped_rows: list[dict[str, Any]] = field(default_factory=list)  # [{"row": 7, "reason": "..."}] (1-based file rows)
    warnings: list[str] = field(default_factory=list)
    detected_columns: dict[str, str] = field(default_factory=dict)  # canonical -> source header


def parse_roster_file(filename: str, content: bytes) -> RosterParseResult:
    """Dispatch on extension (.csv/.tsv/.txt -> text, .xlsx -> Excel).

    Header detection is case/space/punctuation-insensitive and finds the header row even
    when a title row precedes it. Recognised columns (examples):
    jersey: "#", "No", "No.", "Num", "Number", "Jersey", "Jersey #", "Uniform";
    name: "Name", "Player", "Player Name", "Full Name" (split "Last, First" and "First Last");
    first/last: "First", "First Name", "Last", "Last Name", "Surname";
    position: "Pos", "Position"; grade: "Gr", "Grade", "Yr", "Year", "Class", "Cl";
    height: "Ht", "Height" (keeps 6-2, 6'2", 74 as typed); notes: "Notes", "Comments".
    Also accepts header-less 2-3 column files whose first column is numeric.
    Jerseys are normalised (strip "#", spaces, ".0" from Excel floats) but "0" vs "00" is
    preserved. Duplicate jerseys -> warning, later row kept as separate player.
    Raises ``ScoutError(ROSTER_UNSUPPORTED_FILE)`` for other extensions and
    ``ScoutError(ROSTER_PARSE_FAILED)`` when no player rows are found.
    """
    raise NotImplementedError


def merge_players(existing: Roster, incoming: list[RosterPlayer], mode: Literal["replace", "merge"] = "replace") -> Roster:
    """``replace``: incoming becomes the roster. ``merge``: update players with the same
    jersey (keeping their ids so track overrides stay valid), append new jerseys."""
    raise NotImplementedError
