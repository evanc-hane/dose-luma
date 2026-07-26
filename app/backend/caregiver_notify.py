"""Caregiver alert persistence, notification, and escalation.

Tier 1 (immediate, <60s): webhook POST + SMS.
Tier 2/3: if a high/critical alert goes
unacknowledged, escalate to an automated phone call, then a secondary
contact — see _schedule_escalation / _escalate below.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from typing import Any

import db
import twilio_notify

logger = logging.getLogger(__name__)

_MAX_STORED_ALERTS = 200

# Unacknowledged high/critical alerts
# escalate to an automated call at T+5min, then a secondary contact at
# T+10min. Only alerts serious enough to warrant a phone call trigger this —
# "Delayed" (priority="normal") does not.
_ESCALATE_PRIORITIES = ("high", "critical")
_TIER2_DELAY_SECONDS = 300
_TIER3_DELAY_SECONDS = 600  # measured from alert creation, not from Tier 2


def _row_to_alert(row: Any) -> dict[str, Any]:
    return {
        "id": row["id"],
        "type": row["type"],
        "medication_id": row["medication_id"],
        "name": row["name"],
        "intent": row["intent"],
        "message": row["message"],
        "priority": row["priority"],
        "created_at": row["created_at"],
        "dismissed": bool(row["dismissed"]),
    }


def list_stored_alerts(*, include_dismissed: bool = False) -> list[dict[str, Any]]:
    conn = db.get_connection()
    try:
        query = "SELECT * FROM caregiver_alerts"
        if not include_dismissed:
            query += " WHERE dismissed = 0"
        query += " ORDER BY rowid"
        return [_row_to_alert(row) for row in conn.execute(query)]
    finally:
        conn.close()


def dismiss_stored_alert(alert_id: str) -> bool:
    conn = db.get_connection()
    try:
        cur = conn.execute(
            "UPDATE caregiver_alerts SET dismissed = 1 WHERE id = ?", (alert_id,)
        )
        conn.commit()
        return cur.rowcount > 0
    finally:
        conn.close()


def is_acknowledged(alert_id: str) -> bool:
    """The caregiver dashboard's dismiss action *is* the ACK — see
    routes/adherence.py POST /api/alerts/{id}/dismiss and /action. A
    missing alert (already deleted by the _MAX_STORED_ALERTS cap, or never
    existed) counts as acknowledged so escalation doesn't fire on stale ids.
    """
    conn = db.get_connection()
    try:
        row = conn.execute(
            "SELECT dismissed FROM caregiver_alerts WHERE id = ?", (alert_id,)
        ).fetchone()
        return bool(row["dismissed"]) if row else True
    finally:
        conn.close()


def create_alert(
    *,
    alert_type: str,
    medication_id: str,
    name: str,
    intent: str | None = None,
    message: str = "",
    priority: str = "normal",
    now: datetime | None = None,
    notify: bool = True,
    alert_id: str | None = None,
) -> dict[str, Any]:
    """Persist a caregiver alert and optionally POST to CAREGIVER_WEBHOOK_URL."""
    now = now or datetime.now()
    new_id = alert_id or str(uuid.uuid4())

    conn = db.get_connection()
    try:
        existing = conn.execute(
            "SELECT * FROM caregiver_alerts WHERE id = ?", (new_id,)
        ).fetchone()
        if existing is not None:
            return _row_to_alert(existing)

        alert = {
            "id": new_id,
            "type": alert_type,
            "medication_id": medication_id,
            "name": name,
            "intent": intent,
            "message": message,
            "priority": priority,
            "created_at": now.isoformat(),
        }
        conn.execute(
            "INSERT INTO caregiver_alerts "
            "(id, type, medication_id, name, intent, message, priority, created_at, dismissed) "
            "VALUES (:id, :type, :medication_id, :name, :intent, :message, :priority, :created_at, 0)",
            alert,
        )
        # Cap: keep only the most recently inserted _MAX_STORED_ALERTS rows.
        conn.execute(
            "DELETE FROM caregiver_alerts WHERE rowid IN ("
            "  SELECT rowid FROM caregiver_alerts ORDER BY rowid DESC LIMIT -1 OFFSET ?"
            ")",
            (_MAX_STORED_ALERTS,),
        )
        conn.commit()
        alert["dismissed"] = False
    finally:
        conn.close()

    if notify:
        post_webhook(alert)
        send_tier1_sms(alert)
        _schedule_escalation(alert)
    return alert


def send_tier1_sms(alert: dict[str, Any]) -> dict[str, Any]:
    """Send a Tier 1 SMS, or safely no-op when Twilio is not configured."""
    to_number = os.getenv("CAREGIVER_PHONE_NUMBER", "").strip()
    text = f"ALI alert ({alert.get('priority', 'normal')}): {alert.get('message') or alert.get('type')}"
    result = twilio_notify.send_sms(to_number, text)
    logger.info(
        "caregiver SMS type=%s delivered=%s configured=%s",
        alert.get("type"), result.get("delivered"), result.get("configured"),
    )
    return result


def _schedule_escalation(alert: dict[str, Any]) -> None:
    if alert.get("priority") not in _ESCALATE_PRIORITIES:
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        # No running event loop (e.g. a sync script/test calling create_alert
        # directly) — nothing to schedule the background wait on.
        logger.debug("No running event loop; skipping Tier 2/3 escalation scheduling")
        return
    loop.create_task(_escalate(alert["id"], alert.get("message") or alert.get("type", "")))


async def _escalate(alert_id: str, message: str) -> None:
    """Wait for caregiver acknowledgement, then escalate if none arrives."""
    caregiver_phone = os.getenv("CAREGIVER_PHONE_NUMBER", "").strip()
    secondary_phone = os.getenv("SECONDARY_CONTACT_PHONE_NUMBER", "").strip()

    await asyncio.sleep(_TIER2_DELAY_SECONDS)
    if is_acknowledged(alert_id):
        return
    logger.info("Tier 2 escalation: alert %s unacknowledged after %ds, calling caregiver", alert_id, _TIER2_DELAY_SECONDS)
    twilio_notify.place_call(
        caregiver_phone,
        f"This is an automated alert from ALI. {message} Please open the DoseLuma caregiver app.",
    )

    await asyncio.sleep(_TIER3_DELAY_SECONDS - _TIER2_DELAY_SECONDS)
    if is_acknowledged(alert_id):
        return
    logger.info("Tier 3 escalation: alert %s still unacknowledged after %ds, calling secondary contact", alert_id, _TIER3_DELAY_SECONDS)
    twilio_notify.place_call(
        secondary_phone,
        f"This is an automated alert from ALI for a secondary contact. {message}",
    )


def post_webhook(alert: dict[str, Any]) -> dict[str, Any]:
    """POST alert JSON to CAREGIVER_WEBHOOK_URL if configured. Returns delivery meta."""
    url = (os.getenv("CAREGIVER_WEBHOOK_URL") or "").strip()
    meta = {"delivered": False, "latency_ms": None, "error": None, "url_configured": bool(url)}
    if not url:
        return meta

    started = time.perf_counter()
    req = urllib.request.Request(
        url,
        data=json.dumps(alert).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5.0) as resp:
            resp.read()
        meta["delivered"] = True
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
        meta["error"] = str(exc)
        logger.warning("caregiver webhook failed: %s", exc)
    meta["latency_ms"] = round((time.perf_counter() - started) * 1000, 1)
    logger.info(
        "caregiver webhook type=%s delivered=%s latency_ms=%s",
        alert.get("type"),
        meta["delivered"],
        meta["latency_ms"],
    )
    return meta
