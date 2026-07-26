"""Shared helpers for LiveKit session initiation (web + mobile)."""

from __future__ import annotations


def resolve_room_name(requested: str | None, default_room: str) -> str:
    """Use the client room when provided; otherwise fall back to config default.

    Web (talk.html) and mobile both call POST /api/livekit/connect. Either may
    omit room_name and get config.json → agent.room.
    """
    name = (requested or "").strip()
    if name:
        return name
    fallback = (default_room or "").strip()
    if not fallback:
        raise ValueError("room_name is required when config agent.room is empty")
    return fallback
