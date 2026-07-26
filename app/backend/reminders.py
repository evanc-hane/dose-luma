"""Medication schedule (named medications + times) for mobile local notifications."""

from __future__ import annotations

import re
import uuid
from typing import Any

import db

_TIME_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")

_DEFAULT: dict[str, Any] = {
    "enabled": True,
    # Six check-ins, five minutes apart — dense enough for demo / failsafe
    # observation without waiting for a full AM/PM day cycle.
    "medications": [
        {"id": "default-r1", "name": "Reminder 1", "time": "08:00"},
        {"id": "default-r2", "name": "Reminder 2", "time": "08:05"},
        {"id": "default-r3", "name": "Reminder 3", "time": "08:10"},
        {"id": "default-r4", "name": "Reminder 4", "time": "08:15"},
        {"id": "default-r5", "name": "Reminder 5", "time": "08:20"},
        {"id": "default-r6", "name": "Reminder 6", "time": "08:25"},
    ],
}


def _validate_medications(medications: list[Any]) -> list[dict[str, str]]:
    cleaned: list[dict[str, str]] = []
    for entry in medications:
        if not isinstance(entry, dict):
            raise ValueError(f"Invalid medication entry {entry!r}")
        name = str(entry.get("name") or "").strip()
        if not name:
            raise ValueError("Medication name is required")
        time = str(entry.get("time") or "").strip()
        if not _TIME_RE.match(time):
            raise ValueError(f"Invalid medication time {time!r}; use HH:MM (24h)")
        med_id = str(entry.get("id") or "").strip() or uuid.uuid4().hex[:8]
        cleaned.append({"id": med_id, "name": name, "time": time})
    cleaned.sort(key=lambda m: (m["time"], m["name"]))
    return cleaned


def normalize_reminders(payload: dict[str, Any] | None) -> dict[str, Any]:
    """Return a validated reminders document."""
    base = {
        "enabled": _DEFAULT["enabled"],
        "medications": [dict(m) for m in _DEFAULT["medications"]],
    }
    if not payload:
        return base
    enabled = bool(payload.get("enabled", base["enabled"]))
    medications_raw = payload.get("medications", base["medications"])
    if not isinstance(medications_raw, list):
        raise ValueError("medications must be a list of {id, name, time} entries")
    medications = _validate_medications(medications_raw)
    return {"enabled": enabled, "medications": medications}


def load_reminders() -> dict[str, Any]:
    conn = db.get_connection()
    try:
        settings_row = conn.execute(
            "SELECT enabled FROM reminders_settings WHERE id = 1"
        ).fetchone()
        if settings_row is None:
            # Never saved — same as the old "no reminders.json on disk" default.
            return normalize_reminders(None)
        medications = [
            {"id": row["id"], "name": row["name"], "time": row["time"]}
            for row in conn.execute(
                "SELECT id, name, time FROM medications ORDER BY time, name"
            )
        ]
        return normalize_reminders({
            "enabled": bool(settings_row["enabled"]),
            "medications": medications,
        })
    finally:
        conn.close()


def save_reminders(payload: dict[str, Any]) -> dict[str, Any]:
    doc = normalize_reminders(payload)
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT INTO reminders_settings (id, enabled) VALUES (1, ?) "
            "ON CONFLICT(id) DO UPDATE SET enabled = excluded.enabled",
            (int(doc["enabled"]),),
        )
        conn.execute("DELETE FROM medications")
        conn.executemany(
            "INSERT INTO medications (id, name, time) VALUES (?, ?, ?)",
            [(m["id"], m["name"], m["time"]) for m in doc["medications"]],
        )
        conn.commit()
    finally:
        conn.close()
    return doc
