"""Render a ScoutingReport as Markdown (download / print / paste into a doc)."""

from __future__ import annotations

from scout.schemas import Game, ScoutingReport


def report_to_markdown(report: ScoutingReport, game: Game, *, model: str | None = None) -> str:
    raise NotImplementedError
