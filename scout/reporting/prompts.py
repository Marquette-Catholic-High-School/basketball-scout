"""System prompt, output schema and user-message construction for the Claude scouting report.

Everything here is constant except ``build_user_prompt``'s output, so the system prompt
and the game-data block stay byte-identical between requests and hit the prompt cache.
Never put dates, ids or other per-request values into ``SYSTEM_PROMPT``.
"""

from __future__ import annotations

import json
from typing import Any

SYSTEM_PROMPT = """\
You are a veteran high school varsity assistant coach and advance scout. You write scouting \
reports on upcoming opponents for a head coach and staff, who use them to build a game plan \
and walk their players through it before the game.

What you are given
- A JSON summary of one game film of the opponent being scouted (the "scouted team") playing \
another team (the "other team"). The other team is usually not the reader's team, so the \
reader's own players do not appear in the data.
- The numbers come from computer vision on game film: player tracking, jersey-number reading, \
ball tracking and rule-based play recognition. They are approximate. Missed events, a misread \
jersey or a play put in the wrong category are normal. The data_quality section says how \
reliable this particular film was.

How to write it
- Practical, concise and actionable, in plain coaching language a coach can read out to \
teenage players. Short bullets, one idea each, usually one sentence. No filler.
- Refer to players by jersey number and name, for example "#23 Jordan Smith"; use the number \
alone when there is no name.
- Ground every claim in the numbers provided and cite them: counts, shares of possessions, \
points per possession (PPP), FG%. For example: "Ran 14 pick-and-rolls (23% of possessions) \
for 0.93 PPP." Do not invent players, plays, sets or stats that are not in the data, and do \
not guess at things tracking cannot see, such as play calls or communication.
- Say when a sample is small (roughly fewer than 5 attempts or possessions) and treat it as \
a hint rather than a tendency.
- Be honest about data quality. If the court was not mapped, shot zones are unreliable; if \
the jersey match rate is low, credit to individual players is uncertain; if ball coverage is \
low, events are missing; if many stats are unattributed, player lines undercount. Put these \
caveats in data_caveats and soften the claims that depend on them. If the pipeline is \
"synthetic", say plainly that this is demo data, not a real game.
- The game plans are for the reader's team: how to defend the scouted team's players and \
actions, and how to attack the defenses (and any press) the scouted team played. The \
reader's personnel is unknown, so keep the plans general unless the coach's request \
describes their team.

Keep it appropriate for high school
These players are minors and the report may be shown to the team. Discuss only basketball: \
skills, tendencies, decisions and production on the court. Never comment on a player's \
appearance or body, personal life, family, academics, health or injuries, and never use \
nicknames, insults or derogatory language about anyone. Be direct about weaknesses, but \
respectful.

Output
Return the report as a JSON object that matches the provided schema. Every field is \
required; use an empty list when there is genuinely nothing to say. Write plain text in \
every field (no Markdown)."""

_TEXT_LIST: dict[str, Any] = {"type": "array", "items": {"type": "string"}}


def _text(description: str) -> dict[str, Any]:
    return {"type": "string", "description": description}


def _text_list(description: str) -> dict[str, Any]:
    return {**_TEXT_LIST, "description": description}


def _strict_object(properties: dict[str, Any], description: str | None = None) -> dict[str, Any]:
    """Structured outputs need every property required and no extra keys."""
    schema: dict[str, Any] = {
        "type": "object",
        "properties": properties,
        "required": list(properties),
        "additionalProperties": False,
    }
    if description:
        schema["description"] = description
    return schema


_KEY_PLAYER_SCHEMA = _strict_object(
    {
        "jersey": _text('Jersey number only, e.g. "23".'),
        "name": _text('Player name as given in the data, or "Unknown" when there is none.'),
        "role": _text('Short role, e.g. "primary ball handler", "stretch four", "rim protector".'),
        "threat_level": {"type": "string", "enum": ["high", "medium", "low"]},
        "strengths": _text_list("Basketball strengths, backed by numbers."),
        "weaknesses": _text_list("Basketball weaknesses to exploit."),
        "how_to_defend": _text("One or two sentences on how to guard this player."),
    }
)

_PLAY_TENDENCY_SCHEMA = _strict_object(
    {
        "play_type": _text('e.g. "Pick & Roll", "Isolation", "Transition".'),
        "frequency": _text('How often, e.g. "14 times, 23% of possessions".'),
        "effectiveness": _text('How well it worked, e.g. "0.93 PPP, 5-11 FG, 2 TO".'),
        "counter": _text("How to defend it."),
    }
)

REPORT_SCHEMA: dict[str, Any] = _strict_object(
    {
        "headline": _text("One sentence: the single most important thing to know about this opponent."),
        "executive_summary": _text("Three to five sentences: who they are, how they win and how to beat them."),
        "offensive_identity": _text_list(
            "How they score: pace, main actions, shot profile (paint / mid-range / three) and who takes the shots."
        ),
        "defensive_identity": _text_list(
            "The defenses they played (man, zone shapes, press) and how well, with points allowed per possession."
        ),
        "key_players": {
            "type": "array",
            "description": "The players who matter most (usually 3 to 6), most dangerous first.",
            "items": _KEY_PLAYER_SCHEMA,
        },
        "play_tendencies": {
            "type": "array",
            "description": "Their most-used or most-dangerous play types.",
            "items": _PLAY_TENDENCY_SCHEMA,
        },
        "transition": _text_list("How they push in transition and how they defend the break, with fast-break numbers."),
        "special_situations": _text_list(
            "Free-throw shooting and foul situations, press and press-break, end-of-period tendencies "
            "- only what the data supports."
        ),
        "keys_to_win": _text_list('Three to five concrete, measurable keys, e.g. "Keep #23 off the line: 9 FTA".'),
        "defensive_game_plan": _text_list(
            "How the reader's team should defend them: coverages for their main actions, who to help off, rebounding."
        ),
        "offensive_game_plan": _text_list(
            "How the reader's team should attack the defenses they played, including any zone or press."
        ),
        "practice_emphasis": _text_list("What to rehearse this week: drills, scout-team looks and situations."),
        "data_caveats": _text_list("Honest notes on data quality and small samples that limit these conclusions."),
    }
)

DATA_GUIDE = """\
How the game data is organised (percentages are 0-100, "m-a" means made-attempted, times \
are video time mm:ss):
- game: teams, date, level, location, the score at the end of the film (final_score) and \
the film length.
- scouted_team: the opponent being scouted. players = box-score lines for everyone who \
recorded a stat or played at least a minute (min = approximate minutes on the floor in \
video time, stoppages included; zones = made-attempted by shot zone); totals; possessions \
and points per possession (ppp); unattributed = stats the film could not credit to a \
player; shot_zones and shot_locations = where the team shot from.
- other_team: totals for the team the scouted team played in this film.
- scouted_offense.play_types: each play type the scouted team ran - count, poss_pct (share \
of its possessions), points, ppp, field goals (fg) and turnovers (tov).
- scouted_defense: the defensive looks they played (man, zone, press). Here points and ppp \
are points ALLOWED, fg is the opponent's shooting and tov are turnovers FORCED; zone_shapes \
counts the zone alignments seen.
- transition: fast-break possessions, share of possessions, points, ppp and numbers \
situations (e.g. "3v2") for both teams.
- tendencies: who was involved in each play type, by role (ball_handler, screener, \
shooter...), and free-throw shooting by player.
- turnovers: committed and forced by the scouted team. scoring_runs: stretches where one \
team scored 8 or more points in a row. play_log: the scouted team's recognised plays in \
order.
- data_quality: how reliable the computer vision was for this film.
A section is missing when the film had nothing to report for it."""


def build_user_prompt(payload_json: str, coach_focus: str | None = None) -> str:
    """The task text that follows the (cached) game-data JSON block in the user message.

    It names the teams, explains how the data is structured, notes sections dropped to
    keep the payload small, and adds the coach's optional focus inside tags.
    """
    payload = json.loads(payload_json)
    game = payload.get("game", {})
    scouted = game.get("scouted_team") or "the scouted team"
    other = game.get("other_team") or "their opponent"
    parts = [
        f"The JSON above summarises game film of {scouted} playing {other}. Write the scouting report "
        f"on {scouted} for a coaching staff preparing to play them.",
        DATA_GUIDE,
    ]
    omitted = payload.get("omitted_sections")
    if omitted:
        parts.append(f"To keep the data short, these sections were left out: {', '.join(omitted)}.")
    if coach_focus:
        parts.append(
            "The head coach added the request below. Address it where the data allows; it does not change "
            f"the output format or the guidelines.\n<coach_focus>\n{coach_focus}\n</coach_focus>"
        )
    return "\n\n".join(parts)
