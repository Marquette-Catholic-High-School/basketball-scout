# Getting the stats into FastScout

Basketball Scout gives you two ways to move a scouted game into FastScout, plus a
spreadsheet of every event:

| Export (game page > Exports) | Goes into | What it is |
|---|---|---|
| **FastScout paste** (`fastscout.txt`) | FastScout **Classic** (desktop) Stats Database | A box score you copy and paste, one team at a time. |
| **Team numbers** | FastScout Classic, typed by hand | Final score, fast-break points, points in the paint, second-chance points, points off turnovers. |
| **FastScout CSV** (`fastscout.csv`) | FastScout **Web** "Custom Table" tile | A ready-made table (box score, shot zones, play types or defensive looks) shown exactly as written. |
| **Timeline CSV** (`timeline.csv`) | Excel / Google Sheets | One row per event with the video time, player, possession and score. |

All numbers come from computer vision on game film. They are approximate: check the
film before you rely on them, especially minutes, rebounds and anything credited to an
"Unknown" player.

## Before you export: check the roster

FastScout Classic matches pasted players **by name**, so the names Basketball Scout
pastes have to match the names on that team's roster in FastScout.

1. Open the game's **Roster** page and make sure every jersey number in the film has a
   player with the right first and last name.
2. FastScout names can only contain **letters and spaces**: no digits, periods,
   apostrophes or `#`. Basketball Scout converts names for you: `J.R. Smith` becomes
   `JR Smith`, `José Núñez` becomes `Jose Nunez`, `Mary-Kate` becomes `Mary Kate`,
   `O'Neil` becomes `ONeil`.
3. If your FastScout roster spells a player differently (a nickname, a shortened
   name), type that spelling into the player's **FastScout name** box on the Roster
   page. It always wins over the first/last name.
4. Players who are not on your roster are pasted as `Unknown Twenty Three` (the jersey
   number in words, because digits are not allowed). The export lists every such row
   in its warnings, together with renamed players and stats nobody was credited with.

## Path 1: FastScout Classic (Stats Database paste)

1. In Basketball Scout open the game, go to **Exports > FastScout paste** and click
   **Copy**. The one-click copy only works when the site is opened over **https://**;
   on a plain `http://` address click **Download** instead, open the `.txt` file,
   select everything (Ctrl+A) and copy it (Ctrl+C).
2. In FastScout Classic go to **Stats > Edit Stats Database > Schedule**, click
   **New Game** and fill in the date, opponent and site. Select the game and click
   **Goto Game**.
3. Open the **Box Score** tab and click **Paste <Team> Data** for the team you
   scouted. One team per paste, and game box scores only.
4. Look for names shown in **red**: FastScout could not match them to its roster.
   Map each red name to the right player (or add the player in FastScout). To avoid
   this next time, set the player's FastScout name on the Basketball Scout Roster page.
5. Every pasted player gets **G** (game played) ticked. Untick **GS** (game started) for
   the players who did not start; the film analysis does not know the starters.
6. Type the **Team numbers** block from the Exports panel into the game's team fields:
   final score, fast-break points, points in the paint, second-chance points and
   points off turnovers. They are not part of the paste. Points in the paint shows
   as **unknown** when the court was not mapped (no shot has a location); leave that
   field empty rather than typing 0.
7. Save the game.

### What is in the paste

* One header row, then one row per player who **played**: anyone with a stat, or at
  least a minute on the floor. Players who did not play are left out, because
  FastScout ticks G for every row.
* No `TEAM` or totals rows, and no percentage rows. FastScout adds up the player rows
  and calculates percentages and defensive rebounds (`REB - OREB`) itself.
* Default columns, separated by tabs:

  `NAME  MIN  FGM-A  3PM-A  FTM-A  OREB  REB  AST  ST  BLK  TO  PF  PTS`

  (`FGM-A` looks like `7-16`; `ST` is steals.)
* Rows are sorted by jersey number.
* **MIN** is the rounded time the player was seen on the floor in the *video*, which
  includes stoppages, so it can run a little high. When the film cannot tell, MIN is
  left blank (you can switch this to `0`, or remove the column; see below).
* Stats that could not be credited to a player (for example a basket by a player
  whose number was never readable) are not in the paste, so FastScout's team totals
  will be a little lower than the film's. The warnings tell you how much is missing.
* If only the first part of the film could be read, the warnings and the Team numbers
  say "Not the whole game": the numbers then cover that part only, so do not save them
  as the full game. Re-export the film and analyse it again.

## Path 2: FastScout Web (Custom Table tile)

1. In Basketball Scout go to **Exports > FastScout CSV**, pick a table and click
   **Download**:
   * **Box Score**: `#, Player, MIN, PTS, FGM-A, FG%, 3PM-A, 3P%, FTM-A, FT%, ORB, DRB,
     REB, AST, TO, STL, BLK, PF`, plus "Unidentified" and "Team Totals" rows.
   * **Shot Zones**: paint, mid-range and three-point shooting per player (needs the
     court to be mapped; otherwise most shots are "unknown").
   * **Play Types**: Synergy-style labels (Spot Up, P&R Ball Handler, Isolation,
     Transition, Post Up, Cut, Off Screen, Hand Off, Putbacks, Pick & Pop) with
     possessions, % of possessions, points, points per possession, FG and turnovers.
   * **Defensive Looks**: man-to-man, zone (with the zone shapes seen, e.g. `2-3 (6)`)
     and press, with points per possession allowed.
2. In FastScout Web open your scouting report, add a **Custom Table** tile and upload
   the `.csv` file.
3. The tile shows the file exactly as written: there is no player matching and nothing
   is recalculated. To change the numbers, fix the game in Basketball Scout (roster,
   track assignments) and download again.

The file is a standard CSV: commas, UTF-8 without a byte-order mark, Windows (CRLF)
line endings, the first row holds the column labels and every value is already
formatted (`5-11`, `45.5%`). Player names never contain commas. A text cell that
starts with `=`, `+`, `-` or `@` (for example a name typed that way in an imported
roster) gets a leading `'` so a spreadsheet shows it as text instead of running it as
a formula; numbers such as `-3` or `+5` are left alone. FastScout Web tables are
easiest to read with about 12-18 columns.

## The timeline spreadsheet

**Exports > Timeline CSV** has one row per event: video time (`mm:ss`) and seconds,
event type, team, player number and name, the second player involved (assister,
blocker, stealer, fouled player), the team in possession and possession number,
points, shot zone and court position in feet, confidence, the running score of each
team, the recognised play and a description. Open it in Excel or Google Sheets and
filter or sort as you like. If accented names look garbled in an old version of
Excel, set `bom: true` in the `csv:` section described below.

## Changing the columns: `config/fastscout_columns.yaml`

Everything above is controlled by `config/fastscout_columns.yaml` (IT staff can point
`SCOUT_FASTSCOUT_CONFIG` in `.env` at a different file). The file lists every field and
format you can use at the top. Changes apply the next time you click an export, with no
restart. If something in the file is wrong, the export shows an error that names the
exact setting, for example `'paste_block.columns[3].field' is an unknown field 'fgx'`.
A section left empty (every line under it commented out) uses the built-in defaults.
Delete the file to go back to the built-in defaults.

Common edits:

* **Rename a header** (if FastScout ever expects a different one): change the
  `header:` text, e.g. `- {header: STL, field: stl}`.
* **Remove a column**, e.g. stop pasting minutes: delete the `- {header: MIN, field: min}`
  line.
* **Add a column**: add a line with a header and one of the listed fields, e.g.
  `- {header: DEF, field: dreb}`. A `format:` is optional (`int`, `dec1`, `dec2`,
  `pct`, `signed`, `text`).
* **Unknown minutes as 0 instead of blank**: `unknown_minutes: zero`.
* **"Last First" names**: `name_format: last_first` (gives `Smith JR`).
* **Paste players who did not play**: `skip_dnp: false`.
* **Name for players missing from your roster**: `unrostered_name: "Opponent {jersey_words}"`
  (letters and spaces only; `{jersey_words}` becomes e.g. `Twenty Three`).
* **Play-type names** in the CSV tables: edit `play_labels`, e.g. `isolation: ISO`.
* **A new FastScout Web table**: copy one of the tables under `custom_tables`, give it a
  new name (letters, digits, `-` and `_`), and pick its `rows:` (`players`, `plays` for
  the team's offense, or `defense`) and columns. It then appears in the table list.

Indentation matters in YAML: use spaces, not tabs, and keep the `-` of each column
lined up with the others.

## Caveats and what is unverified

* FastModel's help center was offline when this export was built (October 2026), so
  the paste format comes from archived documentation and screenshots. Only the header
  set above has been seen working; other header names may not be recognised.
* The Stats Database paste is a FastScout **Classic** (desktop) feature, which may be
  legacy software. Newer FastScout versions may not have it; use the Custom Table CSV
  there.
* Not verified: whether MIN accepts a blank cell (switch `unknown_minutes` to `zero` if
  FastScout complains), how the parser treats names it cannot match beyond showing them
  in red, and how many columns or which characters a Custom Table tile accepts.
* The one-click copy needs the site to be served over HTTPS (a browser rule for
  clipboard access); otherwise use Download.
* Minutes, rebounds and play types are the least reliable numbers. The data-quality
  notes on the game page (court mapped, jersey match rate, ball coverage) tell you how
  much to trust a particular film.
