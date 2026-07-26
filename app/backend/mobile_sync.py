"""Per-user snapshot backup for the DoseLuma Swift app's background sync.

The app treats whatever POST /api/mobile/sync returns as *authoritative* and
overwrites its local medication/adherence/time-window data with it on every
heartbeat (roughly once a second). To never risk destroying a user's local
data, this always echoes back exactly what was just uploaded — it's an
authenticated backup + a way for caregiver endpoints to read a patient's
latest data, not a real merge/reconciliation engine.

Two-way bridge to reminders.py (the schedule the voice agent and proactive
scheduler actually use — see routes/mobile.py):
  - App medications with a time window sync INTO reminders.medications
    (additive only — never removes an existing reminders entry) so anything
    added through the app actually gets called about.
  - reminders.medications entries not already represented in the app's own
    snapshot are merged INTO the response, with deterministic UUIDs, so the
    demo/scheduled medications the voice agent and scheduler know about are
    actually visible in the app instead of silently only existing server-side.
"""

from __future__ import annotations

import json
import uuid
from typing import Any

import db

_EMPTY_SNAPSHOT: dict[str, Any] = {
    "medications": [],
    "adherence_records": [],
    "time_windows": [],
    "vitals": [],
}

# Stable namespace so a given reminders.py medication id always maps to the
# same synthesized UUID across syncs (Swift's Medication.id must decode as
# a real UUID or the entry is silently dropped client-side).
_REMINDERS_UUID_NAMESPACE = uuid.UUID("6f6d6564-7363-616e-7265-6d696e646572")

# Marks a medication as one *we* synthesized from reminders.medications (see
# _merge_reminders_into_snapshot) rather than one the patient actually
# created in the app. Critical: the app's heartbeat sync re-uploads whatever
# we last returned it, so without this marker a synthesized entry gets
# treated as "new" on the next sync and re-inserted into reminders.medications
# under yet another id — an exponentially compounding feedback loop.
_SYNTHETIC_MARKER = "Synced from your care schedule"


def _reminders_uuid(reminders_id: str) -> str:
    return str(uuid.uuid5(_REMINDERS_UUID_NAMESPACE, reminders_id))


def _coerce_medication(med: dict[str, Any]) -> dict[str, Any]:
    # The upload allows null din/ndc/notes; the response schema requires
    # non-null strings for those fields.
    return {
        **med,
        "din": med.get("din") or "",
        "ndc": med.get("ndc") or "",
        "notes": med.get("notes") or "",
    }


def _coerce_adherence(rec: dict[str, Any]) -> dict[str, Any]:
    return {**rec, "takenAt": rec.get("takenAt") or ""}


def _known_reminder_ids() -> set[str]:
    """Every id currently in reminders.medications, plus the synthetic UUID
    it round-trips as in the app (see _reminders_uuid). Computed fresh from
    the database — not from anything the client echoes back — so detecting
    "this is one we synthesized" never depends on the client faithfully
    preserving a marker field through local storage and re-upload."""
    conn = db.get_connection()
    try:
        ids = [row["id"] for row in conn.execute("SELECT id FROM medications")]
    finally:
        conn.close()
    known: set[str] = set()
    for rid in ids:
        known.add(rid)
        known.add(_reminders_uuid(rid))
    return known


def _sync_medications_to_reminders(medications: list[dict[str, Any]], time_windows: list[dict[str, Any]]) -> None:
    """Additive only: upsert active app medications into reminders.medications
    so the scheduler/voice agent pick them up. Never deletes an existing
    reminders row — a medication removed from the app just stops getting
    updated here, it doesn't vanish from the schedule underneath the agent."""
    already_known = _known_reminder_ids()
    windows_by_id = {w["id"]: w for w in time_windows}
    rows: list[tuple[str, str, str]] = []
    for med in medications:
        if not med.get("isActive", True):
            continue
        med_id = str(med.get("id") or "").strip()
        if not med_id or med_id in already_known:
            continue  # already a reminders row, or the synthetic echo of one
        if med.get("notes") == _SYNTHETIC_MARKER:
            continue  # belt-and-suspenders — see docstring on the marker
        window_ids = med.get("timeWindows") or med.get("timeWindowIDs") or []
        window = next((windows_by_id[w] for w in window_ids if w in windows_by_id), None)
        if window is None:
            continue
        time_str = f"{int(window['openHour']):02d}:{int(window['openMinute']):02d}"
        name = str(med.get("name") or "").strip()
        if not name:
            continue
        rows.append((med_id, name, time_str))

    if not rows:
        return

    conn = db.get_connection()
    try:
        conn.executemany(
            "INSERT INTO medications (id, name, time) VALUES (?, ?, ?) "
            "ON CONFLICT(id) DO UPDATE SET name = excluded.name, time = excluded.time",
            rows,
        )
        # A device syncing means the app is alive — make sure reminders are
        # switched on so these newly-linked medications actually fire.
        conn.execute(
            "INSERT INTO reminders_settings (id, enabled) VALUES (1, 1) "
            "ON CONFLICT(id) DO NOTHING"
        )
        conn.commit()
    finally:
        conn.close()


def _closest_window_id(hhmm: str, time_windows: list[dict[str, Any]]) -> str | None:
    if not time_windows:
        return None
    hour, minute = (int(p) for p in hhmm.split(":"))
    target_minutes = hour * 60 + minute
    for w in time_windows:
        open_minutes = int(w["openHour"]) * 60 + int(w["openMinute"])
        close_minutes = int(w["closeHour"]) * 60 + int(w["closeMinute"])
        if open_minutes <= target_minutes < close_minutes:
            return w["id"]
    # No exact containing window — fall back to whichever opens closest.
    return min(
        time_windows,
        key=lambda w: abs((int(w["openHour"]) * 60 + int(w["openMinute"])) - target_minutes),
    )["id"]


def _merge_reminders_into_snapshot(doc: dict[str, Any]) -> dict[str, Any]:
    """Adds any reminders.medications entries the app doesn't already know
    about into the snapshot being returned, so they're visible in the UI —
    see module docstring."""
    conn = db.get_connection()
    try:
        reminder_meds = conn.execute("SELECT id, name, time FROM medications").fetchall()
    finally:
        conn.close()
    if not reminder_meds:
        return doc

    known_ids = {m["id"] for m in doc["medications"]}
    time_windows = doc["time_windows"] or []
    added = list(doc["medications"])
    for row in reminder_meds:
        synthetic_id = _reminders_uuid(row["id"])
        if synthetic_id in known_ids:
            continue
        window_id = _closest_window_id(row["time"], time_windows)
        added.append(_coerce_medication({
            "id": synthetic_id,
            "name": row["name"],
            "dosage": "",
            "instructions": "",
            "timeWindows": [window_id] if window_id else [],
            "din": "",
            "ndc": "",
            "notes": _SYNTHETIC_MARKER,
            "isActive": True,
        }))
    return {**doc, "medications": added}


def _dedupe_medications(medications: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Collapses duplicate medications by (name, dosage, time windows) —
    a one-time cleanup valve for the "authoritative echo" design: since the
    server always echoes back exactly what was uploaded (see module
    docstring), any duplication that reaches the client's local storage
    would otherwise perpetuate itself forever, each sync round-tripping the
    same duplicates back out. Keeps the first occurrence of each identity."""
    seen: set[tuple[str, str, tuple[str, ...]]] = set()
    deduped: list[dict[str, Any]] = []
    for med in medications:
        key = (
            str(med.get("name", "")).strip().lower(),
            str(med.get("dosage", "")).strip().lower(),
            tuple(sorted(med.get("timeWindows") or med.get("timeWindowIDs") or [])),
        )
        if key in seen:
            continue
        seen.add(key)
        deduped.append(med)
    return deduped


def save_snapshot(user_id: str, snapshot: dict[str, Any]) -> dict[str, Any]:
    """Persist the uploaded snapshot; return it in the shape the client
    expects back as the 'authoritative' response (see module docstring)."""
    medications = _dedupe_medications([_coerce_medication(m) for m in snapshot.get("medications", [])])
    adherence_records = [_coerce_adherence(r) for r in snapshot.get("adherence_records", [])]
    time_windows = snapshot.get("time_windows", [])
    vitals = snapshot.get("vitals", [])

    doc = {
        "medications": medications,
        "adherence_records": adherence_records,
        "time_windows": time_windows,
        "vitals": vitals,
    }
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT INTO mobile_snapshots (user_id, snapshot_json) VALUES (?, ?) "
            "ON CONFLICT(user_id) DO UPDATE SET snapshot_json = excluded.snapshot_json",
            (user_id, json.dumps(doc)),
        )
        conn.commit()
    finally:
        conn.close()

    _sync_medications_to_reminders(medications, time_windows)
    return _merge_reminders_into_snapshot(doc)


def get_snapshot(user_id: str) -> dict[str, Any]:
    conn = db.get_connection()
    try:
        row = conn.execute(
            "SELECT snapshot_json FROM mobile_snapshots WHERE user_id = ?", (user_id,)
        ).fetchone()
        doc = json.loads(row["snapshot_json"]) if row else dict(_EMPTY_SNAPSHOT)
    finally:
        conn.close()
    return _merge_reminders_into_snapshot(doc)
