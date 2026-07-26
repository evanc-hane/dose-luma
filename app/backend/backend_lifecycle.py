"""Pure helpers for FastAPI process lifecycle (LaunchAgent / ensure scripts)."""

from __future__ import annotations


def should_start_backend(*, health_ok: bool) -> bool:
    """Return True only when a new uvicorn process should be started.

    Prevents competing supervisors (Cursor shell + launchd) from fighting
    over :8801, which looked like a crash loop.
    """
    return not health_ok
