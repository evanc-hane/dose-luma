"""Backend health payload builders (pure; safe for unit tests)."""

from __future__ import annotations

from typing import Any


def build_health_payload(*, livekit_url: str | None) -> dict[str, Any]:
    """Return the /api/health JSON body."""
    return {
        "status": "healthy",
        "service": "DoseLuma Backend",
        "livekit": "configured" if livekit_url else "not_configured",
    }
