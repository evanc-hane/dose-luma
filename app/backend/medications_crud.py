"""CRUD data layer for individual medications (reminders.medications rows).

Every SQL statement for this capability lives here — routes/agent_tools.py
and the voice agent's manage_medications tool only call these functions,
they never write SQL themselves. Distinct from reminders.py's
load_reminders/save_reminders, which replace the *entire* schedule document
at once (used by the app's settings screen); this operates on one row at a
time, which is what "add/change/remove a medication" via voice needs.
"""

from __future__ import annotations

import re
import uuid
from typing import Any

import db

_TIME_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")


def _validate_time(time: str) -> str:
    time = time.strip()
    if not _TIME_RE.match(time):
        raise ValueError(f"Invalid time {time!r}; use 24-hour HH:MM")
    return time


def create_medication(name: str, time: str) -> dict[str, Any]:
    name = name.strip()
    if not name:
        raise ValueError("Medication name is required")
    time = _validate_time(time)
    med_id = uuid.uuid4().hex[:8]

    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT INTO medications (id, name, time) VALUES (?, ?, ?)",
            (med_id, name, time),
        )
        conn.execute(
            "INSERT INTO reminders_settings (id, enabled) VALUES (1, 1) ON CONFLICT(id) DO NOTHING"
        )
        conn.commit()
    finally:
        conn.close()
    return {"id": med_id, "name": name, "time": time}


def read_medications() -> list[dict[str, Any]]:
    conn = db.get_connection()
    try:
        rows = conn.execute("SELECT id, name, time FROM medications ORDER BY time").fetchall()
    finally:
        conn.close()
    return [dict(r) for r in rows]


def update_medication(medication_id: str, *, name: str | None = None, time: str | None = None) -> dict[str, Any]:
    conn = db.get_connection()
    try:
        row = conn.execute(
            "SELECT id, name, time FROM medications WHERE id = ?", (medication_id,)
        ).fetchone()
        if row is None:
            raise ValueError(f"Unknown medication id {medication_id!r}")
        new_name = name.strip() if name else row["name"]
        new_time = _validate_time(time) if time else row["time"]
        conn.execute(
            "UPDATE medications SET name = ?, time = ? WHERE id = ?",
            (new_name, new_time, medication_id),
        )
        conn.commit()
    finally:
        conn.close()
    return {"id": medication_id, "name": new_name, "time": new_time}


def delete_medication(medication_id: str) -> bool:
    conn = db.get_connection()
    try:
        cur = conn.execute("DELETE FROM medications WHERE id = ?", (medication_id,))
        conn.commit()
        return cur.rowcount > 0
    finally:
        conn.close()
