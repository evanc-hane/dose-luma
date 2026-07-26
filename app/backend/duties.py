"""The agent's single context/state check: is it near medication time, and
for which medication — IDLE (companion mode) vs MEDICATION_ALERT.

One function, called from one tool (see voice_agent.py's check_duty) —
the agent calls this at conversation start and periodically during a
longer companion chat, so a medication time arriving *mid-conversation*
gets noticed and naturally raised rather than only checked once at
greeting.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

NEAR_MINUTES_BEFORE = 30  # start alerting up to 30 min before scheduled time


def compute_duty(now: datetime | None = None) -> dict[str, Any]:
    import adherence

    now = now or datetime.now()
    statuses = adherence.today_status(now)

    candidates: list[tuple[float, dict[str, Any], float]] = []
    for m in statuses:
        if m["status"] == "taken":
            continue
        hour, minute = (int(p) for p in m["time"].split(":"))
        scheduled = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        minutes_until = (scheduled - now).total_seconds() / 60
        if m["status"] == "missed":
            # Already overdue (past adherence.GRACE_MINUTES) — still needs
            # attention regardless of how far past the window it is.
            candidates.append((abs(minutes_until), m, minutes_until))
        elif m["status"] == "pending" and minutes_until <= NEAR_MINUTES_BEFORE:
            candidates.append((abs(minutes_until), m, minutes_until))

    if not candidates:
        return {"duty": "IDLE", "medication": None, "minutes_until": None}

    candidates.sort(key=lambda c: c[0])
    _, med, minutes_until = candidates[0]
    return {
        "duty": "MEDICATION_ALERT",
        "medication": {
            "id": med["id"],
            "name": med["name"],
            "time": med["time"],
            "status": med["status"],
        },
        "minutes_until": round(minutes_until, 1),
    }
