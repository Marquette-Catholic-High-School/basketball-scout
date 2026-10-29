"""Map pipeline team clusters (team_id 0/1) onto TeamSide (scouted / other).

The GPU pipeline only knows "team 0" and "team 1" (jersey colour clusters). The coach
tells us which one is the opponent being scouted, either explicitly (the UI's
"which team is the opponent?" switch -> ``game.team_id_map``) or with a colour hint
typed when the game was created (``game.scouted_color``: "dark", "white", "#1a2b3c",
"navy", ...).
"""

from __future__ import annotations

import logging
import re

from scout.schemas import Game, TeamInfo, TeamSide, TrackingResult

logger = logging.getLogger(__name__)

RGB = tuple[int, int, int]

# Typical high-school uniform colours. Multi-word names are listed so that
# "royal blue" or "light blue" do not fall back to plain "blue".
NAMED_COLORS: dict[str, RGB] = {
    "white": (245, 245, 245),
    "black": (25, 25, 25),
    "navy": (25, 35, 80),
    "navy blue": (25, 35, 80),
    "blue": (30, 80, 190),
    "royal": (35, 70, 200),
    "royal blue": (35, 70, 200),
    "light blue": (125, 175, 230),
    "sky blue": (125, 185, 235),
    "carolina blue": (120, 170, 225),
    "columbia blue": (150, 190, 230),
    "teal": (0, 128, 128),
    "red": (200, 30, 35),
    "scarlet": (200, 25, 30),
    "maroon": (115, 25, 40),
    "cardinal": (150, 30, 45),
    "crimson": (160, 20, 50),
    "burgundy": (120, 20, 45),
    "green": (30, 130, 60),
    "kelly": (40, 160, 70),
    "kelly green": (40, 160, 70),
    "forest": (30, 75, 45),
    "forest green": (30, 75, 45),
    "dark green": (25, 70, 40),
    "gold": (210, 170, 40),
    "vegas gold": (195, 175, 115),
    "old gold": (205, 165, 80),
    "yellow": (240, 215, 50),
    "orange": (240, 120, 30),
    "purple": (95, 40, 140),
    "gray": (128, 128, 128),
    "grey": (128, 128, 128),
    "silver": (190, 190, 195),
    "brown": (110, 70, 40),
    "pink": (235, 130, 170),
}

# Hints/labels that only say "light" or "dark" (the GPU pipeline labels clusters
# "light"/"dark" in TeamInfo.color_name, sometimes without an RGB value).
LIGHT_WORDS = frozenset({"light", "white"})
DARK_WORDS = frozenset({"dark", "black"})
_LUMINANCE_ONLY_RGB: dict[str, RGB] = {"light": (235, 235, 235), "dark": (40, 40, 40)}
_HEX_RE = re.compile(r"^#?([0-9a-f]{6}|[0-9a-f]{3})$")


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
    team_ids = _team_ids(tracking)
    if not team_ids:
        return {}
    explicit = _from_explicit_map(game.team_id_map, team_ids)
    if explicit is not None:
        return explicit
    scouted_id = _scouted_id_from_hint(game.scouted_color, tracking.teams, team_ids)
    if scouted_id is None:
        scouted_id = team_ids[0]
    return {tid: TeamSide.SCOUTED if tid == scouted_id else TeamSide.OTHER for tid in team_ids}


def side_of(team_map: dict[int, TeamSide], team_id: int | None) -> TeamSide | None:
    """``team_map.get(team_id)``, tolerating ``None``."""
    return None if team_id is None else team_map.get(team_id)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _team_ids(tracking: TrackingResult) -> list[int]:
    """Every pipeline team id mentioned by teams, tracks or events (sorted)."""
    ids = {t.team_id for t in tracking.teams}
    ids.update(t.team_id for t in tracking.tracks if t.team_id is not None)
    ids.update(e.team_id for e in tracking.events if e.team_id is not None)
    return sorted(ids)


def _from_explicit_map(team_id_map: dict[int, TeamSide], team_ids: list[int]) -> dict[int, TeamSide] | None:
    """Use the coach's explicit map; ids it does not mention get the remaining side."""
    known = {tid: TeamSide(side) for tid, side in team_id_map.items() if tid in team_ids}
    if not known:
        return None
    if len(team_ids) == 2 and len(known) == 2 and len(set(known.values())) == 1:
        logger.warning("team_id_map puts both teams on %s; ignoring it", next(iter(known.values())))
        return None
    result = dict(known)
    for tid in team_ids:
        if tid not in result:
            used = set(result.values())
            result[tid] = TeamSide.SCOUTED if TeamSide.SCOUTED not in used else TeamSide.OTHER
    return result


def _scouted_id_from_hint(hint: str | None, teams: list[TeamInfo], team_ids: list[int]) -> int | None:
    """Team id whose jersey best matches the scouted-colour hint, or None if undecidable."""
    if not hint or not hint.strip():
        return None
    word = " ".join(hint.strip().lower().split())
    colours = {t.team_id: c for t in teams if t.team_id in team_ids and (c := _team_colour(t)) is not None}
    if not colours:
        logger.info("No team colours from the pipeline; cannot use colour hint %r", hint)
        return None
    if word in LIGHT_WORDS or word in DARK_WORDS:
        return _pick_by_luminance(word in LIGHT_WORDS, colours, team_ids)
    target = parse_colour(word)
    if target is None:
        logger.warning("Unrecognised team colour hint %r; using team 0 as the scouted team", hint)
        return None
    if any(luminance_only for _, luminance_only in colours.values()):
        # Pipeline only said "light"/"dark": compare brightness classes instead.
        return _pick_by_luminance(luminance(target) >= 0.5, colours, team_ids)
    distances = {tid: _rgb_distance(rgb, target) for tid, (rgb, _) in colours.items()}
    return _unique_best(distances, smallest=True)


def parse_colour(text: str) -> RGB | None:
    """RGB for "#rrggbb", "#rgb" or a colour name ("navy", "royal blue", "dark green")."""
    word = " ".join(text.strip().lower().split())
    match = _HEX_RE.match(word)
    if match:
        digits = match.group(1)
        if len(digits) == 3:
            digits = "".join(ch * 2 for ch in digits)
        return (int(digits[0:2], 16), int(digits[2:4], 16), int(digits[4:6], 16))
    if word in NAMED_COLORS:
        return NAMED_COLORS[word]
    for token in word.replace("-", " ").split():  # "maroon and gold" -> maroon
        if token in NAMED_COLORS:
            return NAMED_COLORS[token]
    return None


def luminance(rgb: RGB) -> float:
    """Perceived brightness 0 (black) .. 1 (white), Rec. 709 weights."""
    r, g, b = rgb
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0


def _team_colour(team: TeamInfo) -> tuple[RGB, bool] | None:
    """(rgb, luminance_only) for a pipeline team; luminance_only when only "light"/"dark" is known."""
    if team.color_rgb is not None:
        return tuple(int(v) for v in team.color_rgb), False  # type: ignore[return-value]
    name = (team.color_name or "").strip().lower()
    if name in _LUMINANCE_ONLY_RGB:
        return _LUMINANCE_ONLY_RGB[name], True
    rgb = parse_colour(name) if name else None
    return (rgb, False) if rgb is not None else None


def _pick_by_luminance(want_light: bool, colours: dict[int, tuple[RGB, bool]], team_ids: list[int]) -> int | None:
    lum = {tid: luminance(rgb) for tid, (rgb, _) in colours.items()}
    if len(lum) >= 2:
        return _unique_best(lum, smallest=not want_light)
    # Only one team has a colour: decide by which side of mid-grey it falls on.
    tid, value = next(iter(lum.items()))
    if (value >= 0.5) == want_light:
        return tid
    others = [t for t in team_ids if t != tid]
    return others[0] if len(others) == 1 else None


def _unique_best(scores: dict[int, float], *, smallest: bool) -> int | None:
    """Id with the best score, or None when the top two tie (no basis to choose)."""
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=not smallest)
    if len(ranked) >= 2 and abs(ranked[0][1] - ranked[1][1]) < 1e-6:
        return None
    return ranked[0][0]


def _rgb_distance(a: RGB, b: RGB) -> float:
    return sum((x - y) ** 2 for x, y in zip(a, b, strict=True)) ** 0.5
