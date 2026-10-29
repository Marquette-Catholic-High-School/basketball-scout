"""Video processors (Modal GPU, local, mock)."""

from __future__ import annotations

from scout.config import Settings, get_settings
from scout.processing.base import PollResult, Processor, ProcessorOutput, VideoSource

__all__ = ["PollResult", "Processor", "ProcessorOutput", "VideoSource", "get_processor"]


def get_processor(settings: Settings | None = None, name: str | None = None) -> Processor:
    """Instantiate the configured processor (``SCOUT_PROCESSOR``) or ``name``."""
    settings = settings or get_settings()
    choice = name or settings.processor
    if choice == "modal":
        from scout.processing.modal_client import ModalProcessor

        return ModalProcessor(settings)
    if choice == "mock":
        from scout.processing.mock import MockProcessor

        return MockProcessor(settings)
    if choice == "local":
        from scout.processing.local import LocalProcessor

        return LocalProcessor(settings)
    raise ValueError(f"unknown processor {choice!r}")
