"""Roster import: realistic CSV/TSV/XLSX layouts, encodings, merge modes and errors."""

from __future__ import annotations

import codecs
import csv
import io
from datetime import datetime
from pathlib import Path

import pytest
from openpyxl import Workbook

from scout.errors import ErrorCode, ScoutError
from scout.roster.importer import MAX_PLAYERS, merge_players, parse_roster_file, split_name
from scout.schemas import Roster, RosterPlayer, TeamSide

FIXTURES = Path(__file__).parent / "fixtures"


def _csv(rows: list[list[object]], *, delimiter: str = ",") -> bytes:
    buffer = io.StringIO()
    csv.writer(buffer, delimiter=delimiter, lineterminator="\r\n").writerows(rows)
    return buffer.getvalue().encode("utf-8")


def _xlsx(sheets: dict[str, list[list[object]]], number_formats: dict[tuple[str, str], str] | None = None) -> bytes:
    """An in-memory workbook: ``{sheet title: rows}``; ``number_formats`` = ``{(sheet, "A5"): "00"}``."""
    workbook = Workbook()
    workbook.remove(workbook.active)
    for title, rows in sheets.items():
        sheet = workbook.create_sheet(title)
        for row in rows:
            sheet.append(row)
    for (title, cell), number_format in (number_formats or {}).items():
        workbook[title][cell].number_format = number_format
    buffer = io.BytesIO()
    workbook.save(buffer)
    return buffer.getvalue()


def _by_jersey(players: list[RosterPlayer]) -> dict[str, RosterPlayer]:
    return {player.jersey: player for player in players}


def _single(header: list[str], row: list[object]) -> RosterPlayer:
    result = parse_roster_file("roster.csv", _csv([header, row]))
    assert len(result.players) == 1
    return result.players[0]


def _parse_error(filename: str, content: bytes) -> ScoutError:
    with pytest.raises(ScoutError) as excinfo:
        parse_roster_file(filename, content)
    return excinfo.value


# ---------------------------------------------------------------------------
# Realistic exports
# ---------------------------------------------------------------------------


def test_maxpreps_export_with_title_rows_and_repeated_header():
    result = parse_roster_file("lakeview_roster.csv", (FIXTURES / "roster_maxpreps.csv").read_bytes())
    players = _by_jersey(result.players)

    assert list(players) == ["1", "3", "5", "00", "0", "12", "23", "33"]
    assert (players["3"].first_name, players["3"].last_name) == ("Kevin", "Van Dyke")
    assert (players["5"].first_name, players["5"].last_name) == ("Tyrell", "Williams Jr.")
    assert (players["12"].first_name, players["12"].last_name) == ("Juan Carlos", "De La Cruz")
    assert (players["23"].first_name, players["23"].last_name) == ("DeShawn", "O'Neil III")
    assert (players["33"].first_name, players["33"].last_name) == ("John", "Smith")
    assert [p.grade for p in result.players] == ["Sr", "Jr", "Sr", "So", "Fr", "Sr", "Sr", "Jr"]
    assert [players[j].height for j in ("1", "3", "5", "33")] == ["6-1", "5'11\"", "6'4\"", "74"]
    assert players["1"].position == "G"
    assert result.detected_columns == {
        "jersey": "#", "name": "Name", "position": "Pos.", "grade": "Gr.", "height": "Ht."
    }  # fmt: skip
    assert result.skipped_rows == [{"row": 15, "reason": "invalid jersey number 'Head Coach: Bob Smith'"}]
    assert result.warnings == []  # "0" and "00" are different numbers, not duplicates


def test_hudl_export_with_first_last_columns_and_extra_columns():
    result = parse_roster_file("hudl_export.csv", (FIXTURES / "roster_hudl.csv").read_bytes())
    players = _by_jersey(result.players)

    assert list(players) == ["1", "3", "05", "00", "0"]
    marcus = players["1"]
    assert (marcus.first_name, marcus.last_name, marcus.position) == ("Marcus", "Johnson", "PG")
    assert (marcus.height, marcus.grade, marcus.fastscout_name) == ("6'1\"", "2026", "M. Johnson")
    assert (players["3"].last_name, players["3"].height) == ("Van Dyke", "5' 11")
    assert players["05"].last_name == "Williams Jr."
    assert players["00"].fastscout_name is None
    assert result.detected_columns == {
        "first_name": "First Name",
        "last_name": "Last Name",
        "jersey": "Jersey",
        "position": "Position",
        "height": "Height",
        "grade": "Grad Year",
        "fastscout_name": "FastScout Name",
    }
    assert result.warnings == [] and result.skipped_rows == []


WINDOWS_ROSTER = "No.;Player;Pos;Yr\r\n4;Peña, José;G;Jr\r\n11;Søren Ørsted;F;So\r\n21;Zoë Brontë;C;Sr\r\n"


@pytest.mark.parametrize(
    "content",
    [
        pytest.param(WINDOWS_ROSTER.encode("cp1252"), id="excel-csv-cp1252"),
        pytest.param(codecs.BOM_UTF8 + WINDOWS_ROSTER.encode("cp1252"), id="cp1252-with-bom"),
        pytest.param(codecs.BOM_UTF8 + WINDOWS_ROSTER.encode("utf-8"), id="excel-csv-utf8-bom"),
        pytest.param(WINDOWS_ROSTER.encode("utf-8"), id="utf8"),
        pytest.param(WINDOWS_ROSTER.replace(";", "\t").encode("utf-16"), id="excel-unicode-text-utf16"),
    ],
)
def test_excel_saved_encodings(content):
    result = parse_roster_file("roster.csv", content)
    players = _by_jersey(result.players)

    assert list(players) == ["4", "11", "21"]
    assert (players["4"].first_name, players["4"].last_name) == ("José", "Peña")
    assert players["11"].name == "Søren Ørsted"
    assert (players["21"].name, players["21"].grade) == ("Zoë Brontë", "Sr")
    assert result.detected_columns["jersey"] == "No."  # the BOM must not stick to the first header


@pytest.mark.parametrize(
    ("filename", "delimiter"),
    [("roster.txt", "\t"), ("roster.tsv", "\t"), ("roster.csv", "|"), ("roster.txt", ";")],
)
def test_other_delimiters(filename, delimiter):
    rows = [["Jersey #", "Player Name", "Position"], ["4", "Smith, Andre", "G"], ["10", "Ty Brooks", "F/C"]]
    players = _by_jersey(parse_roster_file(filename, _csv(rows, delimiter=delimiter)).players)

    assert (players["4"].first_name, players["4"].last_name) == ("Andre", "Smith")
    assert players["10"].position == "F/C"


def test_hand_typed_pipe_table_with_padding():
    content = b"# | Name | Pos\n 3 | Kevin Van Dyke | G\n 22 | Eli Grant | F\n"
    players = _by_jersey(parse_roster_file("roster.txt", content).players)

    assert (players["3"].last_name, players["3"].position) == ("Van Dyke", "G")
    assert players["22"].name == "Eli Grant"


def test_headerless_file_with_position_column():
    result = parse_roster_file("roster.csv", (FIXTURES / "roster_headerless.csv").read_bytes())
    players = _by_jersey(result.players)

    assert list(players) == ["2", "4", "10", "15", "24"]
    assert (players["10"].first_name, players["10"].last_name, players["10"].position) == ("Andre", "Lopez", "C")
    assert players["15"].position == "G/F"
    assert result.detected_columns == {"jersey": "column 1", "name": "column 2", "position": "column 3"}
    assert result.warnings == ["No header row was found, so the columns were read as: jersey, name, position."]


def test_headerless_two_and_three_column_variants():
    two_columns = _by_jersey(parse_roster_file("r.csv", b"3,Kevin Van Dyke\n05,Tyrell Williams\n").players)
    assert (two_columns["3"].last_name, two_columns["05"].first_name) == ("Van Dyke", "Tyrell")

    first_last = _by_jersey(parse_roster_file("r.csv", b"10,John,Smith\n12,Mike,Jones\n").players)
    assert (first_last["10"].first_name, first_last["10"].last_name) == ("John", "Smith")

    grades = _by_jersey(parse_roster_file("r.csv", b"#21,Sam Ortiz,Sr\n#0,Eli Grant,Jr\n").players)
    assert (grades["21"].grade, grades["0"].grade, grades["0"].position) == ("Sr", "Jr", None)

    heights = _by_jersey(parse_roster_file("r.csv", b"5,Ty Brooks,6-2\n7,Sam Ortiz,5-11\n").players)
    assert heights["7"].height == "5-11"


# ---------------------------------------------------------------------------
# Excel workbooks (built in the test; no binaries in the repo)
# ---------------------------------------------------------------------------


def test_xlsx_prefers_roster_sheet_and_converts_excel_values():
    content = _xlsx(
        {
            "Cover": [["Scouting packet - Lakeview"]],
            "JV": [["#", "Name"], [40, "Not Varsity"]],
            "Varsity Roster": [
                ["Lakeview Eagles 2025-26"],
                [],
                ["No.", "Player", "Position", "Class", "Height", "FastScout Name", "Notes"],
                [5, "Kevin Van Dyke", "G", "Senior", datetime(2025, 6, 2), "K. Van Dyke", "Lefty, attacks closeouts"],
                [0, "Andre Smith", "F", 12, 74, None, None],
                [0, "Chris Lee", "C", "Jr", "6'7\"", None, None],
                ["TBD", "New Transfer", None, None, None, None, None],
            ],
        },
        number_formats={("Varsity Roster", "A5"): "00"},  # how Excel shows jersey 00 stored as a number
    )
    result = parse_roster_file("Lakeview.XLSX", content)
    players = _by_jersey(result.players)

    assert list(players) == ["5", "00", "0"]
    kevin = players["5"]
    assert (kevin.last_name, kevin.grade, kevin.fastscout_name) == ("Van Dyke", "Sr", "K. Van Dyke")
    assert kevin.height == "6-2"  # Excel had turned 6-2 into the date 2-Jun
    assert kevin.notes == "Lefty, attacks closeouts"
    assert (players["00"].height, players["00"].grade) == ("74", "Sr")
    assert players["0"].height == "6'7\""
    assert result.skipped_rows == [{"row": 7, "reason": "invalid jersey number 'TBD'"}]
    assert result.warnings == ["Row 7: 'TBD' is not a jersey number (0-99), so New Transfer was skipped."]


def test_xlsx_uses_first_non_empty_sheet():
    content = _xlsx({"Sheet1": [], "Sheet2": [["Name", "#"], ["Ty Brooks", 11.0]], "Sheet3": [["#", "Name"], [9, "X"]]})
    assert [(p.jersey, p.name) for p in parse_roster_file("roster.xlsx", content).players] == [("11", "Ty Brooks")]


def test_workbook_with_a_csv_name_is_read_as_excel():
    content = _xlsx({"Roster": [["#", "Name"], [3, "Kevin Van Dyke"]]})
    assert parse_roster_file("roster.csv", content).players[0].name == "Kevin Van Dyke"


# ---------------------------------------------------------------------------
# Field cleaning
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "jersey"),
    [("#5", "5"), ("05", "05"), ("0", "0"), ("00", "00"), ("5.0", "5"), ("12.00", "12"), (" 23 ", "23"), ("# 4", "4")],
)
def test_jersey_cells(raw, jersey):
    assert _single(["#", "Name"], [raw, "Ty Brooks"]).jersey == jersey


@pytest.mark.parametrize(
    ("raw", "grade"),
    [
        ("Sr", "Sr"), ("Sr.", "Sr"), ("SR", "Sr"), ("12", "Sr"), ("12th", "Sr"), ("Senior", "Sr"), ("Gr 12", "Sr"),
        ("11", "Jr"), ("Soph", "So"), ("9th", "Fr"), ("2026", "2026"), ("RS-Jr", "RS-Jr"), ("", None),
    ],
)  # fmt: skip
def test_grade_values(raw, grade):
    assert _single(["#", "Name", "Class"], ["4", "Ty Brooks", raw]).grade == grade


@pytest.mark.parametrize(
    ("raw", "height"),
    [
        ("6-2", "6-2"), ("6'2\"", "6'2\""), ("74", "74"), ("  6' 2\"  ", "6' 2\""),
        ("2-Jun", "6-2"), ("11-Jun", "6-11"), ("May-10", "5-10"), ("", None),
    ],
)  # fmt: skip
def test_height_values(raw, height):
    assert _single(["#", "Name", "Ht"], ["4", "Ty Brooks", raw]).height == height


@pytest.mark.parametrize(
    ("full", "expected"),
    [
        ("Kevin Van Dyke", ("Kevin", "Van Dyke")),
        ("Van Dyke, Kevin", ("Kevin", "Van Dyke")),
        ("John Smith Jr.", ("John", "Smith Jr.")),
        ("Smith Jr., John", ("John", "Smith Jr.")),
        ("Smith, John Jr.", ("John", "Smith Jr.")),
        ("Smith, Jr., John", ("John", "Smith Jr.")),
        ("John Smith, Jr.", ("John", "Smith Jr.")),
        ("DeShawn O'Neil III", ("DeShawn", "O'Neil III")),
        ("Juan Carlos De La Cruz", ("Juan Carlos", "De La Cruz")),
        ("Marcus St. John", ("Marcus", "St. John")),
        ("  Mary   Jo  Smith ", ("Mary Jo", "Smith")),
        ("Smith", ("", "Smith")),
        ("Wilson III", ("", "Wilson III")),
        ("", ("", "")),
    ],
)
def test_split_name(full, expected):
    assert split_name(full) == expected


def test_separate_name_columns_win_and_suffix_column_joins_last_name():
    player = _single(["Jersey", "Name", "First", "Last", "Suffix"], ["2", "ignored", "Ron", "Hartley", "Jr."])
    assert (player.first_name, player.last_name) == ("Ron", "Hartley Jr.")


# ---------------------------------------------------------------------------
# Warnings and skipped rows
# ---------------------------------------------------------------------------


def test_duplicate_jerseys_are_kept_with_a_warning():
    rows = [
        ["#", "Name"], ["5", "Kevin Van Dyke"], ["5", "Ty Brooks"], ["05", "Sam Ortiz"],
        ["0", "Eli Grant"], ["00", "Andre Smith"],
    ]  # fmt: skip
    result = parse_roster_file("roster.csv", _csv(rows))

    assert [p.jersey for p in result.players] == ["5", "5", "05", "0", "00"]
    assert len({p.id for p in result.players}) == 5
    assert len(result.warnings) == 1
    assert "#5 / #05" in result.warnings[0] and "rows 2, 3, 4" in result.warnings[0]


def test_missing_names_and_invalid_jerseys():
    rows = [
        ["#", "Name"], ["7", ""], ["TBD", "New Transfer"], ["100", "Too Many Digits"],
        ["", "Team Manager"], ["9", "Eli Grant"],
    ]  # fmt: skip
    result = parse_roster_file("roster.csv", _csv(rows))

    assert [p.jersey for p in result.players] == ["7", "9"]
    assert result.skipped_rows == [
        {"row": 3, "reason": "invalid jersey number 'TBD'"},
        {"row": 4, "reason": "invalid jersey number '100'"},
        {"row": 5, "reason": "missing jersey number"},
    ]
    assert "Row 2: #7 has no name." in result.warnings
    assert sum("is not a jersey number" in warning for warning in result.warnings) == 2


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("filename", ["roster.pdf", "roster.xls", "roster.docx", "roster"])
def test_unsupported_extensions(filename):
    assert _parse_error(filename, b"#,Name\n1,Ty Brooks\n").code == ErrorCode.ROSTER_UNSUPPORTED_FILE


def test_old_excel_file_gets_a_save_as_hint():
    error = _parse_error("roster.txt", b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\x00" * 64)
    assert error.code == ErrorCode.ROSTER_UNSUPPORTED_FILE
    assert "Save As" in (error.hint or "")


@pytest.mark.parametrize(
    ("content", "message"),
    [
        (b"", "empty"),
        (b"  \r\n ", "empty"),
        (codecs.BOM_UTF8, "empty"),
        (b"Name,Position\nKevin Van Dyke,G\n", "Could not find the jersey number and name columns"),
        (b"just some notes about their press", "Could not find the jersey number and name columns"),
        (b"#,Name,Pos\n", "no rows under them have a jersey number"),
        (b"#,Name\n,Kevin Van Dyke\n", "no rows under them have a jersey number"),
    ],
)
def test_files_without_players(content, message):
    error = _parse_error("roster.csv", content)
    assert error.code == ErrorCode.ROSTER_PARSE_FAILED
    assert message in error.message


def test_file_size_limit():
    content = b"#,Name\n" + b"1,Ty Brooks\n" * 200_000
    error = _parse_error("roster.csv", content)
    assert error.code == ErrorCode.ROSTER_PARSE_FAILED and "2 MB" in error.message


def test_player_limit():
    rows = [["#", "Name"]] + [[str(i % 100), f"Player {i}"] for i in range(MAX_PLAYERS + 1)]
    error = _parse_error("roster.csv", _csv(rows))
    assert error.code == ErrorCode.ROSTER_PARSE_FAILED and str(MAX_PLAYERS) in error.message

    assert len(parse_roster_file("roster.csv", _csv(rows[:-1])).players) == MAX_PLAYERS


def test_damaged_or_empty_workbooks():
    damaged = _parse_error("roster.xlsx", b"PK\x03\x04 this is not really a workbook")
    assert damaged.code == ErrorCode.ROSTER_PARSE_FAILED and "could not be opened" in damaged.message

    no_roster = _parse_error("roster.xlsx", _xlsx({"Notes": [["Watch #3 on the left block"]]}))
    assert no_roster.code == ErrorCode.ROSTER_PARSE_FAILED

    empty = _parse_error("roster.xlsx", _xlsx({"Sheet1": []}))
    assert empty.code == ErrorCode.ROSTER_PARSE_FAILED and "empty" in empty.message


# ---------------------------------------------------------------------------
# merge_players
# ---------------------------------------------------------------------------


def _existing_roster() -> Roster:
    return Roster(
        game_id="g_test",
        side=TeamSide.SCOUTED,
        team_name="Lakeview",
        players=[
            RosterPlayer(id="p_five", jersey="5", first_name="Kevin", last_name="Dyke", fastscout_name="K. Dyke"),
            RosterPlayer(id="p_ten", jersey="10", first_name="Old", last_name="Player", height="6-0"),
        ],
    )


def _incoming() -> list[RosterPlayer]:
    return [
        RosterPlayer(jersey="5", first_name="Kevin", last_name="Van Dyke", height="6-2"),
        RosterPlayer(jersey="12", first_name="New", last_name="Guard"),
    ]


def test_merge_updates_same_jersey_keeping_ids_and_appends_new():
    existing = _existing_roster()
    incoming = _incoming()
    merged = merge_players(existing, incoming, mode="merge")

    assert [(p.id, p.jersey) for p in merged.players] == [("p_five", "5"), ("p_ten", "10"), (incoming[1].id, "12")]
    five = merged.players[0]
    assert (five.last_name, five.height, five.fastscout_name) == ("Van Dyke", "6-2", "K. Dyke")  # empty fields kept
    assert merged.team_name == "Lakeview" and merged.side == TeamSide.SCOUTED
    assert existing.players[0].last_name == "Dyke"  # input not modified


def test_replace_keeps_ids_for_same_jersey_and_drops_the_rest():
    existing = _existing_roster()
    incoming = _incoming()
    replaced = merge_players(existing, incoming)  # replace is the default

    assert [(p.id, p.jersey) for p in replaced.players] == [("p_five", "5"), (incoming[1].id, "12")]
    assert replaced.players[0].fastscout_name is None  # replace takes the new data as-is
    assert replaced.players[0].last_name == "Van Dyke"


def test_duplicate_jerseys_take_existing_ids_in_order():
    existing = Roster(
        game_id="g", side=TeamSide.OTHER, players=[RosterPlayer(id="a", jersey="5"), RosterPlayer(id="b", jersey="5")]
    )
    incoming = [
        RosterPlayer(jersey="5", last_name="One"), RosterPlayer(jersey="5", last_name="Two"), RosterPlayer(jersey="5"),
    ]  # fmt: skip
    replaced = merge_players(existing, incoming, mode="replace")
    assert [p.id for p in replaced.players][:2] == ["a", "b"] and replaced.players[2].id not in {"a", "b"}

    merged = merge_players(existing, incoming, mode="merge")
    assert [(p.id, p.last_name) for p in merged.players][:2] == [("a", "One"), ("b", "Two")]
    assert len(merged.players) == 3


def test_import_then_merge_round_trip():
    parsed = parse_roster_file("roster.csv", (FIXTURES / "roster_hudl.csv").read_bytes())
    roster = merge_players(Roster(game_id="g", side=TeamSide.SCOUTED), parsed.players, mode="merge")
    assert [p.jersey for p in roster.players] == ["1", "3", "05", "00", "0"]


def test_unknown_merge_mode():
    with pytest.raises(ValueError):
        merge_players(_existing_roster(), [], mode="append")  # type: ignore[arg-type]
