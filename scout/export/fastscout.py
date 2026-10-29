"""FastScout exports.

* ``build_paste_block``: plain-text block for pasting into the FastScout Classic Stats
  Database ("Paste <Team> Data" on a game's Box Score tab). FastScout maps columns by
  HEADER NAME and matches players by NAME, so names are reduced to letters and spaces
  and only players who actually played get a row (FastScout ticks G for every row).
* ``paste_block_warnings``: what the coach should check before pasting (unrostered
  players, renamed players, stats nobody was credited with...).
* ``team_helper_block``: team numbers the coach types in by hand (not part of the paste).
* ``build_custom_table_csv``: CSV for a FastScout Web "Custom Table" tile. Custom tables
  are display-only, so every cell is pre-formatted text ("5-11", "45.5%").
* ``build_timeline_csv``: the full event timeline (for spreadsheets).

Column order, headers, delimiter and name formatting come from
``config/fastscout_columns.yaml`` so they can be adjusted if FastScout changes its
import format. See ``docs/FASTSCOUT.md``.
"""

from __future__ import annotations

import csv
import io
import logging
import math
import re
import unicodedata
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from scout import db
from scout.config import get_settings
from scout.errors import ErrorCode, ScoutError
from scout.schemas import (
    BoxScoreLine,
    EventType,
    Game,
    GameAnalysis,
    PlayType,
    PlayTypeSummary,
    Roster,
    RosterPlayer,
    ShotZone,
    TeamBoxScore,
    TeamSide,
)

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Defaults. config/fastscout_columns.yaml ships with exactly these values (a test
# keeps the two in sync); they are also used when the file is missing.
# ---------------------------------------------------------------------------


def _columns(*pairs: tuple[str, str]) -> list[dict[str, str]]:
    return [{"header": header, "field": field} for header, field in pairs]


DEFAULT_PLAY_LABELS: dict[str, str] = {
    PlayType.PICK_AND_ROLL.value: "P&R Ball Handler",
    PlayType.PICK_AND_POP.value: "Pick & Pop",
    PlayType.ISOLATION.value: "Isolation",
    PlayType.FAST_BREAK.value: "Transition",
    PlayType.POST_UP.value: "Post Up",
    PlayType.HANDOFF.value: "Hand Off",
    PlayType.OFF_BALL_SCREEN.value: "Off Screen",
    PlayType.SPOT_UP.value: "Spot Up",
    PlayType.CUT.value: "Cut",
    PlayType.PUTBACK.value: "Putbacks",
    PlayType.MAN_DEFENSE.value: "Man-to-Man",
    PlayType.ZONE_DEFENSE.value: "Zone",
    PlayType.PRESS.value: "Full-Court Press",
}

DEFAULT_CONFIG: dict[str, Any] = {
    "paste_block": {
        "delimiter": "tab",
        "header_row": True,
        "name_format": "first_last",
        "skip_dnp": True,
        "unknown_minutes": "blank",
        "unrostered_name": "Unknown {jersey_words}",
        "columns": _columns(
            ("NAME", "name"),
            ("MIN", "min"),
            ("FGM-A", "fgm_fga"),
            ("3PM-A", "tpm_tpa"),
            ("FTM-A", "ftm_fta"),
            ("OREB", "oreb"),
            ("REB", "reb"),
            ("AST", "ast"),
            ("ST", "stl"),
            ("BLK", "blk"),
            ("TO", "tov"),
            ("PF", "pf"),
            ("PTS", "pts"),
        ),
    },
    "csv": {
        "delimiter": "comma",
        "line_ending": "crlf",
        "bom": False,
        "default_table": "box",
        "unrostered_name": "Unknown",
        "totals_label": "Team Totals",
        "unattributed_label": "Unidentified",
    },
    "play_labels": DEFAULT_PLAY_LABELS,
    "custom_tables": {
        "box": {
            "title": "Box Score",
            "rows": "players",
            "columns": _columns(
                ("#", "jersey"),
                ("Player", "name"),
                ("MIN", "min"),
                ("PTS", "pts"),
                ("FGM-A", "fgm_fga"),
                ("FG%", "fg_pct"),
                ("3PM-A", "tpm_tpa"),
                ("3P%", "tp_pct"),
                ("FTM-A", "ftm_fta"),
                ("FT%", "ft_pct"),
                ("ORB", "oreb"),
                ("DRB", "dreb"),
                ("REB", "reb"),
                ("AST", "ast"),
                ("TO", "tov"),
                ("STL", "stl"),
                ("BLK", "blk"),
                ("PF", "pf"),
            ),
        },
        "zones": {
            "title": "Shot Zones",
            "rows": "players",
            "columns": _columns(
                ("#", "jersey"),
                ("Player", "name"),
                ("Paint FGM-A", "zone_paint"),
                ("Paint FG%", "zone_paint_pct"),
                ("Mid FGM-A", "zone_mid"),
                ("Mid FG%", "zone_mid_pct"),
                ("3PT FGM-A", "zone_three"),
                ("3P%", "zone_three_pct"),
            ),
        },
        "plays": {
            "title": "Play Types",
            "rows": "plays",
            "columns": _columns(
                ("Play Type", "label"),
                ("Poss", "count"),
                ("% Poss", "possessions_pct"),
                ("PTS", "points"),
                ("PPP", "ppp"),
                ("FG", "fgm_fga"),
                ("TO", "turnovers"),
            ),
        },
        "defense": {
            "title": "Defensive Looks",
            "rows": "defense",
            "columns": _columns(
                ("Defense", "label"),
                ("Poss", "count"),
                ("% Poss", "possessions_pct"),
                ("PTS Allowed", "points"),
                ("PPP Allowed", "ppp"),
                ("Opp FG", "fgm_fga"),
                ("TO Forced", "turnovers"),
                ("Zone Shape", "zone_shapes"),
            ),
        },
    },
}

DELIMITERS: dict[str, str] = {"tab": "\t", "comma": ",", "semicolon": ";", "pipe": "|"}
FORMATS = ("auto", "text", "int", "dec1", "dec2", "pct", "signed")
MAX_TABLE_COLUMNS = 18  # FastScout Web custom tables get hard to read beyond this
JERSEY_WORDS_PLACEHOLDER = "{jersey_words}"
_MINUTE_FIELDS = frozenset({"min", "minutes_est"})
_TURNOVER_STARTS = frozenset({"steal", "turnover"})
_PARTIAL_FILM_WARNING = "FILM_PARTIALLY_ANALYSED"  # docs/TRACKING_SCHEMA.md warning code

# ---------------------------------------------------------------------------
# Rows and fields: a "field" in the YAML names one of the getters below.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class _PlayerRow:
    """One box-score line plus the jersey / names to print for it."""

    line: BoxScoreLine
    jersey: str
    name: str
    first_name: str = ""
    last_name: str = ""
    position: str = ""


@dataclass(frozen=True)
class _PlayRow:
    """One play-type summary (offense or defense) with its display label."""

    summary: PlayTypeSummary
    label: str
    zone_shapes: str = ""


@dataclass(frozen=True)
class _Field:
    """How to read one column's value from a row, and its default display format."""

    get: Callable[[Any], Any]
    format: str


_COUNTING_STATS = (
    "pts", "fgm", "fga", "tpm", "tpa", "ftm", "fta", "oreb", "dreb", "reb", "ast", "stl", "blk", "tov", "pf",
)


def _made_att(made: int, attempts: int) -> str:
    return f"{made}-{attempts}"


def _ratio(made: int, attempts: int) -> float | None:
    return made / attempts if attempts else None


def _line_attr(attr: str) -> Callable[[_PlayerRow], Any]:
    return lambda row: getattr(row.line, attr)


def _zone_value(zone: str, part: str) -> Callable[[_PlayerRow], Any]:
    def get(row: _PlayerRow) -> Any:
        split = getattr(row.line.zones, zone)
        if part == "made":
            return split.made
        if part == "att":
            return split.attempts
        if part == "pct":
            return split.pct
        return _made_att(split.made, split.attempts)

    return get


def _player_fields() -> dict[str, _Field]:
    fields = {
        "jersey": _Field(lambda r: r.jersey, "text"),
        "name": _Field(lambda r: r.name, "text"),
        "first_name": _Field(lambda r: r.first_name, "text"),
        "last_name": _Field(lambda r: r.last_name, "text"),
        "position": _Field(lambda r: r.position, "text"),
        "min": _Field(lambda r: r.line.minutes_est, "int"),
        "minutes_est": _Field(lambda r: r.line.minutes_est, "dec1"),
        "fgm_fga": _Field(lambda r: _made_att(r.line.fgm, r.line.fga), "text"),
        "tpm_tpa": _Field(lambda r: _made_att(r.line.tpm, r.line.tpa), "text"),
        "ftm_fta": _Field(lambda r: _made_att(r.line.ftm, r.line.fta), "text"),
        "plus_minus": _Field(lambda r: r.line.plus_minus, "signed"),
    }
    for stat in _COUNTING_STATS:
        fields[stat] = _Field(_line_attr(stat), "int")
    for pct in ("fg_pct", "tp_pct", "ft_pct"):
        fields[pct] = _Field(_line_attr(pct), "pct")
    for zone in ShotZone:
        fields[f"zone_{zone.value}"] = _Field(_zone_value(zone.value, "split"), "text")
        fields[f"zone_{zone.value}_made"] = _Field(_zone_value(zone.value, "made"), "int")
        fields[f"zone_{zone.value}_att"] = _Field(_zone_value(zone.value, "att"), "int")
        fields[f"zone_{zone.value}_pct"] = _Field(_zone_value(zone.value, "pct"), "pct")
    return fields


def _play_fields() -> dict[str, _Field]:
    return {
        "label": _Field(lambda r: r.label, "text"),
        "type": _Field(lambda r: r.summary.type.value, "text"),
        "count": _Field(lambda r: r.summary.count, "int"),
        "possessions_pct": _Field(lambda r: r.summary.possessions_pct, "pct"),
        "points": _Field(lambda r: r.summary.points, "int"),
        "ppp": _Field(lambda r: r.summary.ppp, "dec2"),
        "fgm": _Field(lambda r: r.summary.fgm, "int"),
        "fga": _Field(lambda r: r.summary.fga, "int"),
        "fgm_fga": _Field(lambda r: _made_att(r.summary.fgm, r.summary.fga), "text"),
        "fg_pct": _Field(lambda r: _ratio(r.summary.fgm, r.summary.fga), "pct"),
        "turnovers": _Field(lambda r: r.summary.turnovers, "int"),
        "zone_shapes": _Field(lambda r: r.zone_shapes, "text"),
    }


PLAYER_FIELDS: dict[str, _Field] = _player_fields()
PLAY_FIELDS: dict[str, _Field] = _play_fields()
ROW_SOURCES: dict[str, dict[str, _Field]] = {"players": PLAYER_FIELDS, "plays": PLAY_FIELDS, "defense": PLAY_FIELDS}

# ---------------------------------------------------------------------------
# Config loading / validation
# ---------------------------------------------------------------------------

_TOP_KEYS = frozenset({"paste_block", "csv", "play_labels", "custom_tables"})
_PASTE_KEYS = frozenset(DEFAULT_CONFIG["paste_block"])
_CSV_KEYS = frozenset(DEFAULT_CONFIG["csv"])
_TABLE_KEYS = frozenset({"title", "rows", "skip_dnp", "totals_row", "unattributed_row", "columns"})
_COLUMN_KEYS = frozenset({"header", "field", "format"})
_TABLE_NAME = re.compile(r"[A-Za-z0-9_-]+")


class _ConfigChecker:
    """Validates one config mapping; every error names the exact key that is wrong."""

    def __init__(self, source: str) -> None:
        self.source = source

    def error(self, key: str, problem: str) -> ScoutError:
        return ScoutError(
            ErrorCode.CONFIG_INVALID,
            f"FastScout export settings ({self.source}): '{key}' {problem}",
            hint="Fix that setting in config/fastscout_columns.yaml (docs/FASTSCOUT.md explains each one), "
            "or delete the file to use the built-in defaults.",
        )

    def mapping(self, value: Any, key: str) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise self.error(key, "must be a group of 'name: value' settings")
        return value

    def known_keys(self, section: dict[str, Any], allowed: frozenset[str], key: str) -> None:
        for name in section:
            if name not in allowed:
                full_key = f"{key}.{name}" if key else str(name)
                raise self.error(full_key, f"is not a known setting (expected one of: {', '.join(sorted(allowed))})")

    def boolean(self, value: Any, key: str) -> bool:
        if not isinstance(value, bool):
            raise self.error(key, f"must be true or false (got {value!r})")
        return value

    def choice(self, value: Any, key: str, choices: tuple[str, ...] | list[str]) -> str:
        if value not in choices:
            raise self.error(key, f"must be one of: {', '.join(choices)} (got {value!r})")
        return str(value)

    def text(self, value: Any, key: str) -> str:
        if not isinstance(value, str) or not value.strip() or "\n" in value or "\r" in value:
            raise self.error(key, f"must be a non-empty single line of text (got {value!r})")
        return value.strip()

    def columns(self, value: Any, key: str, fields: dict[str, _Field], *, forbidden: str = "") -> list[dict[str, str]]:
        if not isinstance(value, list) or not value:
            raise self.error(key, "must be a list of columns, each with a header and a field")
        columns = []
        for i, raw in enumerate(value):
            col_key = f"{key}[{i}]"
            col = self.mapping(raw, col_key)
            self.known_keys(col, _COLUMN_KEYS, col_key)
            header = self.text(col.get("header"), f"{col_key}.header")
            if forbidden and forbidden in header:
                raise self.error(f"{col_key}.header", "must not contain the delimiter")
            field = col.get("field")
            if not isinstance(field, str) or field not in fields:
                raise self.error(f"{col_key}.field", f"is an unknown field {field!r} (see the field list in the file)")
            fmt = self.choice(col.get("format", "auto"), f"{col_key}.format", FORMATS)
            if fields[field].format == "text" and fmt not in ("auto", "text"):
                raise self.error(f"{col_key}.format", f"'{fmt}' only works with number fields, and {field!r} is text")
            columns.append({"header": header, "field": field, "format": fmt})
        return columns


def validate_fastscout_config(data: Any, *, source: str = "config") -> dict[str, Any]:
    """Check a raw config mapping and fill in defaults.

    Raises ``ScoutError(CONFIG_INVALID)`` naming the bad key. Missing or empty sections
    and missing settings fall back to the defaults; ``custom_tables`` and ``columns`` lists replace
    the defaults entirely so a coach can remove columns or tables.
    """
    check = _ConfigChecker(source)
    data = check.mapping({} if data is None else data, "(top level)")
    check.known_keys(data, _TOP_KEYS, "")
    # A section whose settings are all commented out is empty (None): the same as leaving it out.
    data = {key: value for key, value in data.items() if value is not None}
    paste = _validate_paste(check, data.get("paste_block", {}))
    csv_cfg = _validate_csv(check, data.get("csv", {}))
    labels = _validate_labels(check, data.get("play_labels", {}))
    tables = _validate_tables(check, data.get("custom_tables", DEFAULT_CONFIG["custom_tables"]))
    if csv_cfg["default_table"] not in tables:
        raise check.error("csv.default_table", f"names a table that does not exist (tables: {', '.join(tables)})")
    return {"paste_block": paste, "csv": csv_cfg, "play_labels": labels, "custom_tables": tables}


def _validate_paste(check: _ConfigChecker, raw: Any) -> dict[str, Any]:
    section = check.mapping(raw, "paste_block")
    check.known_keys(section, _PASTE_KEYS, "paste_block")
    merged = {**DEFAULT_CONFIG["paste_block"], **section}
    delimiter = check.choice(merged["delimiter"], "paste_block.delimiter", list(DELIMITERS))
    template = check.text(merged["unrostered_name"], "paste_block.unrostered_name")
    if not re.fullmatch(r"[A-Za-z ]*", template.replace(JERSEY_WORDS_PLACEHOLDER, "")):
        raise check.error(
            "paste_block.unrostered_name",
            f"may only contain letters, spaces and {JERSEY_WORDS_PLACEHOLDER} "
            "(FastScout rejects digits and symbols in names)",
        )
    return {
        "delimiter": delimiter,
        "header_row": check.boolean(merged["header_row"], "paste_block.header_row"),
        "name_format": check.choice(merged["name_format"], "paste_block.name_format", ("first_last", "last_first")),
        "skip_dnp": check.boolean(merged["skip_dnp"], "paste_block.skip_dnp"),
        "unknown_minutes": check.choice(merged["unknown_minutes"], "paste_block.unknown_minutes", ("blank", "zero")),
        "unrostered_name": template,
        "columns": check.columns(
            merged["columns"], "paste_block.columns", PLAYER_FIELDS, forbidden=DELIMITERS[delimiter]
        ),
    }


def _validate_csv(check: _ConfigChecker, raw: Any) -> dict[str, Any]:
    section = check.mapping(raw, "csv")
    check.known_keys(section, _CSV_KEYS, "csv")
    merged = {**DEFAULT_CONFIG["csv"], **section}
    return {
        "delimiter": check.choice(merged["delimiter"], "csv.delimiter", list(DELIMITERS)),
        "line_ending": check.choice(merged["line_ending"], "csv.line_ending", ("crlf", "lf")),
        "bom": check.boolean(merged["bom"], "csv.bom"),
        "default_table": check.text(merged["default_table"], "csv.default_table"),
        "unrostered_name": check.text(merged["unrostered_name"], "csv.unrostered_name"),
        "totals_label": check.text(merged["totals_label"], "csv.totals_label"),
        "unattributed_label": check.text(merged["unattributed_label"], "csv.unattributed_label"),
    }


def _validate_labels(check: _ConfigChecker, raw: Any) -> dict[str, str]:
    section = check.mapping(raw, "play_labels")
    labels = dict(DEFAULT_PLAY_LABELS)
    for play_type, label in section.items():
        if play_type not in DEFAULT_PLAY_LABELS:
            expected = ", ".join(DEFAULT_PLAY_LABELS)
            raise check.error(f"play_labels.{play_type}", f"is not a play type (expected one of: {expected})")
        labels[play_type] = check.text(label, f"play_labels.{play_type}")
    return labels


def _validate_tables(check: _ConfigChecker, raw: Any) -> dict[str, dict[str, Any]]:
    section = check.mapping(raw, "custom_tables")
    if not section:
        raise check.error("custom_tables", "must define at least one table")
    tables: dict[str, dict[str, Any]] = {}
    for name, raw_table in section.items():
        key = f"custom_tables.{name}"
        if not isinstance(name, str) or not _TABLE_NAME.fullmatch(name):
            raise check.error(key, "table names may only use letters, digits, '-' and '_'")
        table = check.mapping(raw_table, key)
        check.known_keys(table, _TABLE_KEYS, key)
        rows = check.choice(table.get("rows", "players"), f"{key}.rows", list(ROW_SOURCES))
        columns = check.columns(table.get("columns"), f"{key}.columns", ROW_SOURCES[rows])
        if len(columns) > MAX_TABLE_COLUMNS:
            logger.warning(
                "FastScout table %r has %d columns; FastScout Web tables are easiest to read with %d or fewer.",
                name,
                len(columns),
                MAX_TABLE_COLUMNS,
            )
        tables[name] = {
            "title": check.text(table.get("title", name), f"{key}.title"),
            "rows": rows,
            "skip_dnp": check.boolean(table.get("skip_dnp", True), f"{key}.skip_dnp"),
            "totals_row": check.boolean(table.get("totals_row", True), f"{key}.totals_row"),
            "unattributed_row": check.boolean(table.get("unattributed_row", True), f"{key}.unattributed_row"),
            "columns": columns,
        }
    return tables


def load_fastscout_config(path: Path | str | None = None) -> dict[str, Any]:
    """Load and validate the column mapping (defaults to settings.fastscout_config).

    Read on every call (it is tiny) so a coach's edits apply without a restart. A
    missing file means "use the defaults"; a broken one raises CONFIG_INVALID.
    """
    target = Path(path) if path is not None else get_settings().fastscout_config
    if not target.exists():
        logger.warning("FastScout settings file %s not found; using the built-in defaults.", target)
        return validate_fastscout_config({}, source="built-in defaults")
    try:
        data = yaml.safe_load(target.read_text(encoding="utf-8"))
    except UnicodeDecodeError as exc:
        raise ScoutError(
            ErrorCode.CONFIG_INVALID,
            f"FastScout export settings ({target.name}) are not saved as UTF-8 text.",
            hint="Save the file as UTF-8 (most editors offer it under 'Save As' / 'Encoding').",
        ) from exc
    except yaml.YAMLError as exc:
        raise ScoutError(
            ErrorCode.CONFIG_INVALID,
            f"FastScout export settings ({target.name}) are not valid YAML: {exc}",
            hint="Check the indentation and quotes near the line mentioned, or delete the file to use the defaults.",
        ) from exc
    except OSError as exc:  # a folder, or a file the server may not read
        raise ScoutError(
            ErrorCode.CONFIG_INVALID,
            f"FastScout export settings ({target}) could not be read: {exc.strerror or exc}.",
            hint="Point SCOUT_FASTSCOUT_CONFIG at a readable .yaml file, or delete it to use the built-in defaults.",
        ) from exc
    return validate_fastscout_config(data, source=target.name)


def _resolve_config(config: dict[str, Any] | None) -> dict[str, Any]:
    return validate_fastscout_config(config) if config is not None else load_fastscout_config()


def list_custom_tables(config: dict[str, Any] | None = None) -> list[str]:
    """Names of the FastScout Web custom tables, in the order the YAML lists them."""
    return list(_resolve_config(config)["custom_tables"])


def custom_table_titles(config: dict[str, Any] | None = None) -> dict[str, str]:
    """Table name -> display title (e.g. "zones" -> "Shot Zones"), for menus in the UI."""
    return {name: table["title"] for name, table in _resolve_config(config)["custom_tables"].items()}


# ---------------------------------------------------------------------------
# Names and jerseys
# ---------------------------------------------------------------------------

# Letters that NFKD does not decompose into an ASCII base letter.
_TRANSLITERATE = str.maketrans(
    {
        "Ø": "O", "ø": "o", "Æ": "AE", "æ": "ae", "Œ": "OE", "œ": "oe", "ß": "ss",
        "Ł": "L", "ł": "l", "Đ": "D", "đ": "d", "Þ": "Th", "þ": "th", "ı": "i",
    }
)
_WORD_BREAKS = re.compile(r"[\s\-_/]+")
_ONES = (
    "Zero One Two Three Four Five Six Seven Eight Nine Ten "
    "Eleven Twelve Thirteen Fourteen Fifteen Sixteen Seventeen Eighteen Nineteen"
).split()
_TENS = {2: "Twenty", 3: "Thirty", 4: "Forty", 5: "Fifty", 6: "Sixty", 7: "Seventy", 8: "Eighty", 9: "Ninety"}


def sanitize_fastscout_name(text: str) -> str:
    """Reduce a name to what the Stats Database accepts: ASCII letters and single spaces.

    Accents are folded ("José Núñez" -> "Jose Nunez"), hyphens / underscores / slashes
    become spaces, and everything else (periods, apostrophes, digits, '#') is dropped:
    "J.R. Smith" -> "JR Smith", "O'Neil" -> "ONeil".
    """
    folded = unicodedata.normalize("NFKD", text.translate(_TRANSLITERATE))
    spaced = _WORD_BREAKS.sub(" ", folded)
    letters = "".join(ch for ch in spaced if ch == " " or (ch.isascii() and ch.isalpha()))
    return " ".join(letters.split())


def jersey_words(jersey: str | None) -> str:
    """A jersey number in words, because FastScout names cannot contain digits.

    "23" -> "Twenty Three", "0" -> "Zero", "00" -> "Double Zero"; numbers with a leading
    zero or three digits are read digit by digit ("07" -> "Zero Seven").
    """
    if not jersey or not jersey.isdigit():
        return ""
    if jersey == "00":
        return "Double Zero"
    if len(jersey) > 2 or (len(jersey) == 2 and jersey.startswith("0")):
        return " ".join(_ONES[int(digit)] for digit in jersey)
    number = int(jersey)
    if number < 20:
        return _ONES[number]
    tens, ones = divmod(number, 10)
    return _TENS[tens] if ones == 0 else f"{_TENS[tens]} {_ONES[ones]}"


def _unrostered_name(template: str, jersey: str) -> str:
    name = sanitize_fastscout_name(template.replace(JERSEY_WORDS_PLACEHOLDER, jersey_words(jersey)))
    return name or "Unknown Player"


def _clean_text(text: str) -> str:
    """Collapse whitespace (including line breaks) to single spaces."""
    return " ".join(text.split())


def _jersey_key(jersey: str) -> tuple[int, int, int]:
    """Sort jerseys numerically ("0" before "00" before "1"); odd values last."""
    return (0, int(jersey), len(jersey)) if jersey.isdigit() else (1, 0, 0)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _side(side: TeamSide | str) -> TeamSide:
    try:
        return TeamSide(side)
    except ValueError:
        message = f"Unknown team side {side!r}; use 'scouted' or 'other'."
        raise ScoutError(ErrorCode.VALIDATION_FAILED, message) from None


def _other_side(side: TeamSide) -> TeamSide:
    return TeamSide.OTHER if side == TeamSide.SCOUTED else TeamSide.SCOUTED


def _team_name(analysis: GameAnalysis, side: TeamSide, game: Game | None = None) -> str:
    team = analysis.team(side)
    if team and team.name:
        return team.name
    box = analysis.box_score(side)
    if box and box.team_name:
        return box.team_name
    if game is not None:
        name = game.scouted_team if side == TeamSide.SCOUTED else game.other_team
        if name:
            return name
    return "Scouted team" if side == TeamSide.SCOUTED else "Other team"


def _require_box(analysis: GameAnalysis, side: TeamSide, game: Game | None = None) -> TeamBoxScore:
    box = analysis.box_score(side)
    if box is None:
        raise ScoutError(
            ErrorCode.ANALYSIS_NOT_READY,
            f"The analysis has no box score for {_team_name(analysis, side, game)}.",
            hint="Re-run the analysis from the game page.",
        )
    return box


def _has_stats(line: BoxScoreLine) -> bool:
    return any((line.pts, line.fga, line.fta, line.oreb, line.dreb, line.ast, line.stl, line.blk, line.tov, line.pf))


def _played(line: BoxScoreLine) -> bool:
    """Any stat, or at least a minute on the floor."""
    return _has_stats(line) or (line.minutes_est or 0.0) >= 1.0


def _roster(game: Game, side: TeamSide, roster: Roster | None) -> Roster:
    """The current roster (names / FastScout spellings may have been edited after the analysis)."""
    return roster if roster is not None else db.get_roster(game.id, side)


def _roster_player(line: BoxScoreLine, roster: Roster) -> RosterPlayer | None:
    return roster.by_id(line.player.player_id) if line.player.player_id else None


def _round_half_up(value: float) -> int:
    return int(math.floor(float(value) + 0.5))


def _format_value(value: Any, fmt: str) -> str:
    if value is None:
        return ""
    if fmt == "int":
        return str(_round_half_up(value))
    if fmt == "dec1":
        return f"{float(value):.1f}"
    if fmt == "dec2":
        return f"{float(value):.2f}"
    if fmt == "pct":
        return f"{float(value) * 100:.1f}%"
    if fmt == "signed":
        number = _round_half_up(value)
        return f"+{number}" if number > 0 else str(number)
    return _clean_text(str(value))


def _cell(row: Any, column: dict[str, str], fields: dict[str, _Field], *, unknown_minutes: str = "blank") -> str:
    field = fields[column["field"]]
    value = field.get(row)
    if value is None and column["field"] in _MINUTE_FIELDS and unknown_minutes == "zero":
        value = 0
    fmt = field.format if column.get("format", "auto") == "auto" else column["format"]
    return _format_value(value, fmt)


# ---------------------------------------------------------------------------
# Paste block (FastScout Classic Stats Database)
# ---------------------------------------------------------------------------


def _raw_paste_name(line: BoxScoreLine, player: RosterPlayer | None, name_format: str) -> str:
    """FastScout spelling > roster name > name stored in the analysis."""
    if player is None:
        return (line.player.name or "").strip()
    if player.fastscout_name and player.fastscout_name.strip():
        return player.fastscout_name.strip()
    first, last = player.first_name.strip(), player.last_name.strip()
    parts = (last, first) if name_format == "last_first" else (first, last)
    return " ".join(part for part in parts if part)


def _paste_name(
    line: BoxScoreLine, player: RosterPlayer | None, jersey: str, cfg: dict[str, Any], team: str
) -> tuple[str, str | None]:
    """The FastScout-safe name for one row, plus a warning when the coach should check it."""
    number = f"#{jersey}" if jersey else "no jersey number"
    raw = _raw_paste_name(line, player, cfg["name_format"])
    fallback = _unrostered_name(cfg["unrostered_name"], jersey)
    if not raw:
        reason = "is not on" if player is None else "has no name on"
        return fallback, (
            f'The player with {number} {reason} the {team} roster, so the row is named "{fallback}". '
            "Fix it on the Roster page, or rename the row in FastScout after pasting."
        )
    name = sanitize_fastscout_name(raw)
    if not name:
        return fallback, (
            f'"{raw}" ({number}) has no letters FastScout accepts, so the row is named "{fallback}". '
            "Set the player's FastScout name on the Roster page."
        )
    if name != _clean_text(raw):
        return name, (
            f'"{raw}" ({number}) is pasted as "{name}" because FastScout names can only contain letters and spaces. '
            "If your FastScout roster spells it differently, set the player's FastScout name on the Roster page."
        )
    return name, None


def _paste_rows(
    analysis: GameAnalysis, game: Game, side: TeamSide, cfg: dict[str, Any], roster: Roster | None
) -> tuple[list[_PlayerRow], list[str]]:
    """Rows for the paste block (sorted by jersey) and the warnings that go with them."""
    box = _require_box(analysis, side, game)
    roster = _roster(game, side, roster)
    team = _team_name(analysis, side, game)
    rows: list[_PlayerRow] = []
    name_warnings: list[str] = []
    for line in box.players:
        if cfg["skip_dnp"] and not _played(line):
            continue
        player = _roster_player(line, roster)
        jersey = (player.jersey if player else line.player.jersey) or ""
        name, warning = _paste_name(line, player, jersey, cfg, team)
        if warning:
            name_warnings.append(warning)
        rows.append(
            _PlayerRow(
                line=line,
                jersey=jersey,
                name=name,
                first_name=sanitize_fastscout_name(player.first_name) if player else "",
                last_name=sanitize_fastscout_name(player.last_name) if player else "",
                position=(player.position or "") if player else "",
            )
        )
    rows.sort(key=lambda r: (_jersey_key(r.jersey), r.name))
    warnings = [
        *_partial_film_warnings(analysis),
        *name_warnings,
        *_duplicate_name_warnings(rows),
        *_minutes_warnings(rows, cfg),
        *_unattributed_warnings(box),
    ]
    if not rows:
        warnings.append(f"No {team} player has a stat or a minute on the floor, so the paste has only the header row.")
    return rows, warnings


def _partial_film_warnings(analysis: GameAnalysis) -> list[str]:
    """The pipeline's note that only the start of the film could be read: the numbers are not the whole game."""
    return [
        f"Not the whole game: {w.message}"
        for w in analysis.data_quality.warnings
        if w.code == _PARTIAL_FILM_WARNING
    ]


def _duplicate_name_warnings(rows: list[_PlayerRow]) -> list[str]:
    counts = Counter(row.name for row in rows)
    return [
        f'{count} rows are named "{name}". FastScout matches players by name, '
        "so give them different FastScout names on the Roster page."
        for name, count in sorted(counts.items())
        if count > 1
    ]


def _minutes_warnings(rows: list[_PlayerRow], cfg: dict[str, Any]) -> list[str]:
    if not any(col["field"] in _MINUTE_FIELDS for col in cfg["columns"]):
        return []
    missing = [f"#{row.jersey}" if row.jersey else row.name for row in rows if row.line.minutes_est is None]
    if not missing:
        return []
    shown = "left blank" if cfg["unknown_minutes"] == "blank" else "set to 0"
    return [f"Minutes could not be measured from the film for {', '.join(missing)}; MIN is {shown} for them."]


def _unattributed_warnings(box: TeamBoxScore) -> list[str]:
    line = box.team_unattributed
    stats = {
        "PTS": line.pts, "FGA": line.fga, "FTA": line.fta, "REB": line.reb, "AST": line.ast,
        "ST": line.stl, "BLK": line.blk, "TO": line.tov, "PF": line.pf,
    }
    parts = [f"{value} {label}" for label, value in stats.items() if value]
    if not parts:
        return []
    return [
        f"Some {box.team_name or 'team'} stats could not be credited to a player and are not in the paste "
        f"({', '.join(parts)}). FastScout adds up the player rows, so its team totals will be lower than the film's."
    ]


def build_paste_block(
    analysis: GameAnalysis,
    game: Game,
    side: TeamSide = TeamSide.SCOUTED,
    config: dict[str, Any] | None = None,
    *,
    roster: Roster | None = None,
) -> str:
    """Header row + one row per player who played, ready for "Paste <Team> Data".

    No totals or percentage rows (FastScout computes those). ``roster`` defaults to the
    game's current roster in the database (for FastScout name spellings).
    """
    side = _side(side)
    cfg = _resolve_config(config)["paste_block"]
    rows, _ = _paste_rows(analysis, game, side, cfg, roster)
    delimiter = DELIMITERS[cfg["delimiter"]]
    lines = [delimiter.join(col["header"] for col in cfg["columns"])] if cfg["header_row"] else []
    for row in rows:
        cells = [_cell(row, col, PLAYER_FIELDS, unknown_minutes=cfg["unknown_minutes"]) for col in cfg["columns"]]
        lines.append(delimiter.join(cells))
    return "\n".join(lines)


def paste_block_warnings(
    analysis: GameAnalysis,
    game: Game,
    side: TeamSide = TeamSide.SCOUTED,
    config: dict[str, Any] | None = None,
    *,
    roster: Roster | None = None,
) -> list[str]:
    """Plain-English things to check before pasting (unrostered or renamed players, uncredited stats...)."""
    side = _side(side)
    cfg = _resolve_config(config)["paste_block"]
    _, warnings = _paste_rows(analysis, game, side, cfg, roster)
    return warnings


# ---------------------------------------------------------------------------
# Team numbers typed in by hand
# ---------------------------------------------------------------------------


def _score(analysis: GameAnalysis, side: TeamSide) -> int:
    team = analysis.team(side)
    if team is not None:
        return team.score
    box = analysis.box_score(side)
    return box.totals.pts if box else 0


def _fast_break_points(analysis: GameAnalysis, side: TeamSide) -> int:
    """Points on possessions flagged as transition or containing a fast-break play."""
    fast_breaks = {play.id for play in analysis.plays if play.type == PlayType.FAST_BREAK and play.side == side}
    return sum(
        p.points
        for p in analysis.possessions
        if p.side == side and (p.transition or fast_breaks.intersection(p.play_ids))
    )


def _second_chance_points(analysis: GameAnalysis, side: TeamSide) -> int:
    """Points scored after an offensive rebound, within the same possession."""
    after_oreb: set[int] = set()
    points = 0
    for event in analysis.timeline:
        if event.side != side or event.possession_id is None:
            continue
        if event.type == EventType.OREB:
            after_oreb.add(event.possession_id)
        elif event.points and event.possession_id in after_oreb:
            points += event.points
    return points


def _points_off_turnovers(analysis: GameAnalysis, side: TeamSide) -> int:
    return sum(p.points for p in analysis.possessions if p.side == side and p.start_reason in _TURNOVER_STARTS)


def team_helper_block(analysis: GameAnalysis, side: TeamSide = TeamSide.SCOUTED) -> str:
    """The team numbers a coach types into FastScout by hand (they are not part of the paste)."""
    side = _side(side)
    team, opponent = _team_name(analysis, side), _team_name(analysis, _other_side(side))
    box = analysis.box_score(side)
    zones = box.totals.zones if box else None
    unplaced = zones.unknown.made if zones else 0
    if zones is None:
        paint = "unknown"
    elif zones.unknown.attempts and not (zones.paint.attempts or zones.mid.attempts or zones.three.attempts):
        paint = "unknown (no shot had a court location - map the court to get this number)"
    else:
        paint = f"{2 * zones.paint.made}"
        if unplaced:
            paint += f" (approximate: {unplaced} made shot{'' if unplaced == 1 else 's'} had no court location)"
    lines = [
        f"{team}: team numbers to type in by hand (not part of the paste)",
        f"Final score: {team} {_score(analysis, side)}, {opponent} {_score(analysis, _other_side(side))}",
        f"Fast-break points: {_fast_break_points(analysis, side)}",
        f"Points in the paint: {paint}",
        f"Second-chance points: {_second_chance_points(analysis, side)}",
        f"Points off turnovers: {_points_off_turnovers(analysis, side)}",
        *_partial_film_warnings(analysis),
        "From video analysis - verify against the film.",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CSV (FastScout Web custom tables, timeline)
# ---------------------------------------------------------------------------

_FORMULA_START = re.compile(r"[=+\-@\t\r]")
_PLAIN_NUMBER = re.compile(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)%?")


def _safe_cell(value: str) -> str:
    """Stop spreadsheets from running text as a formula ("=...", "-1+cmd|..."); plain numbers like
    "-3" and "+5" are untouched."""
    return f"'{value}" if _FORMULA_START.match(value) and not _PLAIN_NUMBER.fullmatch(value) else value


def _write_csv(header: list[str], body: list[list[str]], csv_cfg: dict[str, Any]) -> str:
    """RFC 4180 CSV (quotes only where needed); UTF-8 BOM only when the config asks for it.

    Headers come from the YAML and are written as-is; body cells get the formula guard.
    """
    buffer = io.StringIO()
    writer = csv.writer(
        buffer,
        delimiter=DELIMITERS[csv_cfg["delimiter"]],
        lineterminator="\r\n" if csv_cfg["line_ending"] == "crlf" else "\n",
        quoting=csv.QUOTE_MINIMAL,
    )
    writer.writerow([_clean_text(cell) for cell in header])
    writer.writerows([[_safe_cell(_clean_text(cell)) for cell in row] for row in body])
    text = buffer.getvalue()
    return "\ufeff" + text if csv_cfg["bom"] else text


def _display_name(line: BoxScoreLine, player: RosterPlayer | None, fallback: str) -> str:
    """Display name ("First Last") without commas; FastScout Web custom tables are plain text."""
    name = player.name if player is not None and player.name else (line.player.name or "")
    return _clean_text(name.replace(",", " ")) or fallback


def _player_table_rows(
    analysis: GameAnalysis,
    game: Game,
    side: TeamSide,
    table: dict[str, Any],
    csv_cfg: dict[str, Any],
    roster: Roster | None,
) -> list[_PlayerRow]:
    box = _require_box(analysis, side, game)
    roster = _roster(game, side, roster)
    rows = []
    for line in box.players:
        if table["skip_dnp"] and not _played(line):
            continue
        player = _roster_player(line, roster)
        rows.append(
            _PlayerRow(
                line=line,
                jersey=(player.jersey if player else line.player.jersey) or "",
                name=_display_name(line, player, csv_cfg["unrostered_name"]),
                first_name=_clean_text(player.first_name.replace(",", " ")) if player else "",
                last_name=_clean_text(player.last_name.replace(",", " ")) if player else "",
                position=(player.position or "") if player else "",
            )
        )
    rows.sort(key=lambda r: (_jersey_key(r.jersey), r.name))
    if table["unattributed_row"] and _has_stats(box.team_unattributed):
        rows.append(_PlayerRow(line=box.team_unattributed, jersey="", name=csv_cfg["unattributed_label"]))
    if table["totals_row"]:
        rows.append(_PlayerRow(line=box.totals, jersey="", name=csv_cfg["totals_label"]))
    return rows


def _zone_shapes(analysis: GameAnalysis, side: TeamSide) -> str:
    """e.g. "2-3 (6), 1-3-1 (2)" from the zone-defense plays' ``zone_shape`` attribute."""
    shapes = Counter(
        str(play.attrs["zone_shape"])
        for play in analysis.plays
        if play.type == PlayType.ZONE_DEFENSE and play.side == side and play.attrs.get("zone_shape")
    )
    return ", ".join(f"{shape} ({count})" for shape, count in sorted(shapes.items(), key=lambda kv: (-kv[1], kv[0])))


def _play_table_rows(analysis: GameAnalysis, side: TeamSide, category: str, labels: dict[str, str]) -> list[_PlayRow]:
    shapes = _zone_shapes(analysis, side) if category == "defense" else ""
    rows = [
        _PlayRow(
            summary=summary,
            label=labels.get(summary.type.value, summary.type.value),
            zone_shapes=shapes if summary.type == PlayType.ZONE_DEFENSE else "",
        )
        for summary in analysis.play_summary
        if summary.side == side and summary.category == category
    ]
    return sorted(rows, key=lambda r: (-r.summary.count, r.label))


def build_custom_table_csv(
    analysis: GameAnalysis,
    game: Game,
    side: TeamSide = TeamSide.SCOUTED,
    table: str | None = None,
    config: dict[str, Any] | None = None,
    *,
    roster: Roster | None = None,
) -> str:
    """CSV for a FastScout Web Custom Table tile: row 1 = labels, every value pre-formatted.

    ``table`` is a name from ``list_custom_tables`` (default: ``csv.default_table``).
    """
    side = _side(side)
    cfg = _resolve_config(config)
    name = table or cfg["csv"]["default_table"]
    spec = cfg["custom_tables"].get(name)
    if spec is None:
        raise ScoutError(
            ErrorCode.VALIDATION_FAILED,
            f"There is no FastScout table called {name!r}. Available tables: {', '.join(cfg['custom_tables'])}.",
        )
    rows: list[Any]
    if spec["rows"] == "players":
        rows = _player_table_rows(analysis, game, side, spec, cfg["csv"], roster)
    else:
        category = "defense" if spec["rows"] == "defense" else "offense"
        rows = _play_table_rows(analysis, side, category, cfg["play_labels"])
    fields = ROW_SOURCES[spec["rows"]]
    header = [col["header"] for col in spec["columns"]]
    body = [[_cell(row, col, fields) for col in spec["columns"]] for row in rows]
    return _write_csv(header, body, cfg["csv"])


def _clock(seconds: float) -> str:
    """Video time as mm:ss (minutes keep counting past 59)."""
    total = max(0, int(seconds))
    return f"{total // 60:02d}:{total % 60:02d}"


def build_timeline_csv(analysis: GameAnalysis, config: dict[str, Any] | None = None) -> str:
    """One row per timeline event, for spreadsheets. Uses the ``csv`` section's delimiter / line ending / BOM."""
    csv_cfg = _resolve_config(config)["csv"]
    names = {side: _team_name(analysis, side) for side in TeamSide}
    score_headers = [_safe_cell(_clean_text(f"{names[side]} Score")) for side in TeamSide]  # data, unlike the rest
    header = [
        *("Time", "Seconds", "Type", "Event", "Team", "Player #", "Player", "Secondary Player"),
        *("Possession Team", "Possession #", "Points", "Zone", "Subzone", "X (ft)", "Y (ft)", "Confidence"),
        *score_headers,
        *("Play ID", "Description"),
    ]
    body = []
    for event in analysis.timeline:
        x, y = event.court_xy if event.court_xy else (None, None)
        body.append(
            [
                _clock(event.t),
                f"{event.t:.1f}",
                event.type.value,
                event.label,
                names[event.side] if event.side else "",
                (event.player.jersey or "") if event.player else "",
                (event.player.name or "") if event.player else "",
                event.secondary_player.label if event.secondary_player else "",
                names[event.possession_side] if event.possession_side else "",
                "" if event.possession_id is None else str(event.possession_id),
                str(event.points),
                event.zone.value if event.zone else "",
                event.subzone or "",
                _format_value(x, "dec1"),
                _format_value(y, "dec1"),
                f"{event.confidence:.2f}",
                str(event.score_scouted),
                str(event.score_other),
                event.play_id or "",
                event.description,
            ]
        )
    return _write_csv(header, body, csv_cfg)
