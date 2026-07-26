"""Medication adherence tracking, duplicate-dose safeguards, and alert merge.

Single-patient store backed by SQLite (see db.py) — same pattern as
reminders.py.

Safety layers:
  1. State lock — mark_taken refuses overwrite (duplicate=True)
  2. Duplicate Taken intent → overdose_risk alert (no second log)
  3. Distress/Confused intent → high-priority alert immediately
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any

import caregiver_notify
import db
from reminders import load_reminders

GRACE_MINUTES = 60


class DuplicateDoseError(Exception):
    """Raised when mark_taken is called for an already-locked dose (Layer 1)."""

    def __init__(self, medication_id: str, taken_at: str):
        self.medication_id = medication_id
        self.taken_at = taken_at
        super().__init__(f"Dose already taken for {medication_id} at {taken_at}")


def _today(now: datetime) -> str:
    return now.strftime("%Y-%m-%d")


def _key(date: str, medication_id: str) -> str:
    return f"{date}:{medication_id}"


def _load_taken() -> dict[str, str]:
    """Map of "date:medication_id" -> ISO taken_at timestamp (every date)."""
    conn = db.get_connection()
    try:
        return {
            _key(row["date"], row["medication_id"]): row["taken_at"]
            for row in conn.execute("SELECT date, medication_id, taken_at FROM adherence_taken")
        }
    finally:
        conn.close()


def _insert_taken(date: str, medication_id: str, taken_at: str) -> None:
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT INTO adherence_taken (date, medication_id, taken_at) VALUES (?, ?, ?)",
            (date, medication_id, taken_at),
        )
        conn.commit()
    finally:
        conn.close()


def _load_dismissed() -> set[str]:
    conn = db.get_connection()
    try:
        return {
            _key(row["date"], row["medication_id"])
            for row in conn.execute("SELECT date, medication_id FROM adherence_dismissed")
        }
    finally:
        conn.close()


def _add_dismissed(date: str, medication_id: str) -> None:
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT OR IGNORE INTO adherence_dismissed (date, medication_id) VALUES (?, ?)",
            (date, medication_id),
        )
        conn.commit()
    finally:
        conn.close()


def _load_missed_notified() -> set[str]:
    conn = db.get_connection()
    try:
        return {
            _key(row["date"], row["medication_id"])
            for row in conn.execute("SELECT date, medication_id FROM adherence_missed_notified")
        }
    finally:
        conn.close()


def _add_missed_notified(date: str, medication_id: str) -> None:
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT OR IGNORE INTO adherence_missed_notified (date, medication_id) VALUES (?, ?)",
            (date, medication_id),
        )
        conn.commit()
    finally:
        conn.close()


def _resolve_med(medication_id: str | None) -> dict[str, Any] | None:
    doc = load_reminders()
    meds = doc.get("medications") or []
    if medication_id:
        return next((m for m in meds if m["id"] == medication_id), None)
    # Default to the next pending / first med for voice sessions without an id.
    if meds:
        return meds[0]
    return None


def _status_for(med: dict[str, Any], date: str, taken: dict[str, str], now: datetime) -> dict[str, Any]:
    key = _key(date, med["id"])
    taken_at = taken.get(key)
    if taken_at is not None:
        status = "taken"
    else:
        hour, minute = (int(part) for part in med["time"].split(":"))
        year, month, day = (int(part) for part in date.split("-"))
        scheduled = datetime(year, month, day, hour, minute)
        status = "missed" if now >= scheduled + timedelta(minutes=GRACE_MINUTES) else "pending"
    return {
        "id": med["id"],
        "name": med["name"],
        "time": med["time"],
        "status": status,
        "taken_at": taken_at,
        "locked": taken_at is not None,
    }


def today_status(now: datetime | None = None) -> list[dict[str, Any]]:
    """Per-medication status (taken/missed/pending) for today."""
    now = now or datetime.now()
    date = _today(now)
    doc = load_reminders()
    taken = _load_taken()
    return [_status_for(med, date, taken, now) for med in doc["medications"]]


def history(days: int = 7, now: datetime | None = None) -> list[dict[str, Any]]:
    """Per-medication status for each of the last `days` days, most recent first."""
    now = now or datetime.now()
    doc = load_reminders()
    taken = _load_taken()
    result: list[dict[str, Any]] = []
    for offset in range(days):
        day = now - timedelta(days=offset)
        date = _today(day)
        result.append({
            "date": date,
            "medications": [_status_for(med, date, taken, now) for med in doc["medications"]],
        })
    return result


def is_locked(medication_id: str, now: datetime | None = None) -> bool:
    now = now or datetime.now()
    return _key(_today(now), medication_id) in _load_taken()


def mark_taken(medication_id: str, now: datetime | None = None) -> dict[str, Any]:
    """Record today's dose as taken (Layer 1 lock).

    Raises ValueError if unknown med, DuplicateDoseError if already taken.
    """
    now = now or datetime.now()
    date = _today(now)
    med = _resolve_med(medication_id)
    if med is None or med["id"] != medication_id:
        raise ValueError(f"Unknown medication id {medication_id!r}")

    taken = _load_taken()
    key = _key(date, medication_id)
    if key in taken:
        raise DuplicateDoseError(medication_id, taken[key])

    taken_at = now.isoformat()
    _insert_taken(date, medication_id, taken_at)
    taken[key] = taken_at

    # A newly-taken dose is no longer worth a missed alert.
    _add_dismissed(date, medication_id)

    record = _status_for(med, date, taken, now)
    record["duplicate"] = False
    record["ok"] = True
    return record


def apply_intent(
    state: str,
    *,
    medication_id: str | None = None,
    transcript: str = "",
    now: datetime | None = None,
) -> dict[str, Any]:
    """Apply a classified intent and create caregiver alerts when required."""
    now = now or datetime.now()
    med = _resolve_med(medication_id)
    if med is None:
        raise ValueError("No medication configured")

    mid = med["id"]
    name = med["name"]
    result: dict[str, Any] = {
        "state": state,
        "medication_id": mid,
        "name": name,
        "duplicate": False,
        "locked": is_locked(mid, now),
        "alert": None,
        "action": None,
        "agent_hint": "",
    }

    if state == "Taken":
        if is_locked(mid, now):
            # Layer 2 — duplicate dose attempt
            alert = caregiver_notify.create_alert(
                alert_type="overdose_risk",
                medication_id=mid,
                name=name,
                intent="Taken",
                message=(
                    f"Possible double dose: patient indicated taking {name} again "
                    f"after it was already logged. Transcript: {transcript!r}"
                ),
                priority="high",
                now=now,
            )
            result["duplicate"] = True
            result["action"] = "overdose_escalated"
            result["alert"] = alert
            result["agent_hint"] = (
                "Gently warn them this dose was already recorded earlier today, "
                "ask them not to take another, and say you are letting their caregiver know."
            )
            return result

        record = mark_taken(mid, now)
        result["locked"] = True
        result["action"] = "marked_taken"
        result["record"] = record
        result["agent_hint"] = (
            "Warmly acknowledge they took their medication, then keep the "
            "conversation going naturally with one brief, caring question "
            "about their day (e.g. how they're feeling, what they're up to "
            "today) — don't just end the call after confirming the dose."
        )
        return result

    if state == "Refused":
        alert = caregiver_notify.create_alert(
            alert_type="refused",
            medication_id=mid,
            name=name,
            intent="Refused",
            message=f"Patient refused {name}. Transcript: {transcript!r}",
            priority="high",
            now=now,
        )
        result["action"] = "alerted"
        result["alert"] = alert
        result["agent_hint"] = (
            "Respond gently, do not argue, and say you will let their caregiver know."
        )
        return result

    if state == "Delayed":
        alert = caregiver_notify.create_alert(
            alert_type="delayed",
            medication_id=mid,
            name=name,
            intent="Delayed",
            message=f"Patient delayed {name}. Transcript: {transcript!r}",
            priority="normal",
            now=now,
        )
        result["action"] = "alerted"
        result["alert"] = alert
        result["agent_hint"] = (
            "Acknowledge they will take it later and offer a brief gentle reminder later."
        )
        return result

    if state == "Confused":
        # Layer 3 — immediate caregiver visibility
        alert = caregiver_notify.create_alert(
            alert_type="confused",
            medication_id=mid,
            name=name,
            intent="Confused",
            message=f"Patient confused about {name}. Transcript: {transcript!r}",
            priority="high",
            now=now,
        )
        result["action"] = "alerted"
        result["alert"] = alert
        result["agent_hint"] = (
            "Speak slowly, reassure them, and say you are letting their caregiver know."
        )
        return result

    if state == "Distress":
        # Layer 3 — highest priority
        alert = caregiver_notify.create_alert(
            alert_type="distress",
            medication_id=mid,
            name=name,
            intent="Distress",
            message=f"Distress signal during {name} check-in. Transcript: {transcript!r}",
            priority="critical",
            now=now,
        )
        result["action"] = "alerted"
        result["alert"] = alert
        result["agent_hint"] = (
            "Stay very calm, reassure them help is on the way via their caregiver, "
            "and keep the reply short."
        )
        return result

    if state == "NoResponse":
        # Layer 3-equivalent — not something the patient said, the voice
        # agent reports this itself (SilenceWatchdog) after repeated
        # unanswered nudges. Nobody responding at all during a call is at
        # least as concerning as a distress signal, so it gets the same
        # "critical" priority: Tier 2/3 auto-call escalation kicks in if
        # unacknowledged (see caregiver_notify._escalate).
        alert = caregiver_notify.create_alert(
            alert_type="no_response",
            medication_id=mid,
            name=name,
            intent="NoResponse",
            message=f"No response from patient during a call. {transcript}".strip(),
            priority="critical",
            now=now,
        )
        result["action"] = "alerted"
        result["alert"] = alert
        result["agent_hint"] = "Nobody responded — end the call."
        return result

    result["action"] = "noop"
    result["agent_hint"] = "Continue the medication check-in gently."
    return result


def _missed_alert_id(date: str, medication_id: str) -> str:
    return f"missed:{date}:{medication_id}"


def sync_missed_alerts(now: datetime | None = None) -> list[dict[str, Any]]:
    """Create webhook alerts the first time a dose becomes missed (grace elapsed)."""
    now = now or datetime.now()
    date = _today(now)
    notified = _load_missed_notified()
    created: list[dict[str, Any]] = []
    for entry in today_status(now):
        if entry["status"] != "missed":
            continue
        key = _key(date, entry["id"])
        if key in notified:
            continue
        alert = caregiver_notify.create_alert(
            alert_type="missed",
            medication_id=entry["id"],
            name=entry["name"],
            intent=None,
            message=f"Missed dose: {entry['name']} scheduled at {entry['time']}",
            priority="high",
            now=now,
            alert_id=_missed_alert_id(date, entry["id"]),
        )
        _add_missed_notified(date, entry["id"])
        created.append(alert)
    return created


def list_alerts(now: datetime | None = None) -> list[dict[str, Any]]:
    """Merged caregiver alerts for *today*: stored intent/overdose/missed."""
    now = now or datetime.now()
    sync_missed_alerts(now)
    date = _today(now)
    dismissed_keys = _load_dismissed()

    alerts: list[dict[str, Any]] = []
    for alert in caregiver_notify.list_stored_alerts(include_dismissed=False):
        created = str(alert.get("created_at") or "")
        # Keep dashboard focused on today's events
        if created and not created.startswith(date):
            # Also allow stable missed ids that encode the date
            if not str(alert.get("id", "")).startswith(f"missed:{date}:"):
                continue
        mid = alert.get("medication_id") or ""
        if alert.get("type") == "missed" and _key(date, mid) in dismissed_keys:
            continue
        # Skip prior-day missed ids still undismissed in store
        aid = str(alert.get("id") or "")
        if aid.startswith("missed:") and not aid.startswith(f"missed:{date}:"):
            continue
        alerts.append({
            "id": alert["id"],
            "type": alert.get("type", "missed"),
            "medication_id": mid,
            "name": alert.get("name", ""),
            "time": next(
                (m["time"] for m in today_status(now) if m["id"] == mid),
                "",
            ),
            "status": "missed" if alert.get("type") == "missed" else alert.get("type", "alert"),
            "intent": alert.get("intent"),
            "message": alert.get("message", ""),
            "priority": alert.get("priority", "normal"),
            "created_at": alert.get("created_at"),
            "taken_at": None,
        })

    alerts.sort(key=lambda a: a.get("created_at") or "", reverse=True)
    return alerts


def dismiss_alert(alert_or_medication_id: str, now: datetime | None = None) -> None:
    """Dismiss by alert id, or by medication id (legacy missed path)."""
    now = now or datetime.now()
    date = _today(now)

    if caregiver_notify.dismiss_stored_alert(alert_or_medication_id):
        return

    # Legacy: treat as medication_id for missed alerts
    _add_dismissed(date, alert_or_medication_id)

    missed_id = _missed_alert_id(date, alert_or_medication_id)
    caregiver_notify.dismiss_stored_alert(missed_id)
