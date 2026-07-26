"""Proactive medication-reminder scheduling engine.

Fires a job at each medication's scheduled time (daily, ±30s drift target)
that dispatches the LiveKit voice agent into the
standing room — the *system*-initiated call, independent of whether or
when the patient answers. Each firing is recorded (scheduled vs actual
time, drift) so scheduling precision can be measured directly, instead of
only being reachable via a user tapping
"Talk to ALI" in the app.
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, Awaitable, Callable

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger

import db
from reminders import load_reminders
from state_bus import state_bus

logger = logging.getLogger(__name__)

_MAX_STORED_EVENTS = 200
TARGET_DRIFT_SECONDS = 30

DispatchFn = Callable[[str], Awaitable[bool]]

# The live scheduler instance, so other modules (e.g. mobile_sync's route,
# after new app medications land in reminders.medications) can trigger a
# rebuild without importing index.py — which owns the actual instance and
# would create a circular import.
_current: "MedicationScheduler | None" = None


def _set_current(instance: "MedicationScheduler") -> None:
    global _current
    _current = instance


def rebuild_if_running() -> None:
    """No-op if the scheduler hasn't started yet (e.g. mid-test)."""
    if _current is not None:
        _current.rebuild_jobs()


def build_trigger(hhmm: str) -> CronTrigger:
    """Daily cron trigger for a medication time in HH:MM (24h) format."""
    hour, minute = (int(part) for part in hhmm.split(":"))
    return CronTrigger(hour=hour, minute=minute)


def compute_drift_seconds(scheduled_at: datetime, fired_at: datetime) -> float:
    return (fired_at - scheduled_at).total_seconds()


def record_event(
    medication_id: str,
    medication_name: str,
    scheduled_time: str,
    scheduled_at: datetime,
    fired_at: datetime,
    agent_dispatched: bool,
) -> dict[str, Any]:
    """Persist one scheduler-initiation event; returns the recorded entry."""
    drift = compute_drift_seconds(scheduled_at, fired_at)
    within_target = abs(drift) <= TARGET_DRIFT_SECONDS
    entry = {
        "medication_id": medication_id,
        "medication_name": medication_name,
        "scheduled_time": scheduled_time,
        "scheduled_at": scheduled_at.isoformat(),
        "fired_at": fired_at.isoformat(),
        "drift_seconds": drift,
        "within_target": within_target,
        "agent_dispatched": agent_dispatched,
    }
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT INTO scheduler_events "
            "(medication_id, medication_name, scheduled_time, scheduled_at, fired_at, "
            " drift_seconds, within_target, agent_dispatched) "
            "VALUES (:medication_id, :medication_name, :scheduled_time, :scheduled_at, "
            " :fired_at, :drift_seconds, :within_target, :agent_dispatched)",
            {
                **entry,
                "within_target": int(within_target),
                "agent_dispatched": int(agent_dispatched),
            },
        )
        # Cap: keep only the most recently inserted _MAX_STORED_EVENTS rows.
        conn.execute(
            "DELETE FROM scheduler_events WHERE seq IN ("
            "  SELECT seq FROM scheduler_events ORDER BY seq DESC LIMIT -1 OFFSET ?"
            ")",
            (_MAX_STORED_EVENTS,),
        )
        conn.commit()
    finally:
        conn.close()
    return entry


def recent_events(limit: int = 20) -> list[dict[str, Any]]:
    conn = db.get_connection()
    try:
        rows = conn.execute(
            "SELECT medication_id, medication_name, scheduled_time, scheduled_at, fired_at, "
            "drift_seconds, within_target, agent_dispatched FROM scheduler_events "
            "ORDER BY seq DESC LIMIT ?",
            (limit,),
        ).fetchall()
    finally:
        conn.close()
    events = [
        {
            "medication_id": r["medication_id"],
            "medication_name": r["medication_name"],
            "scheduled_time": r["scheduled_time"],
            "scheduled_at": r["scheduled_at"],
            "fired_at": r["fired_at"],
            "drift_seconds": r["drift_seconds"],
            "within_target": bool(r["within_target"]),
            "agent_dispatched": bool(r["agent_dispatched"]),
        }
        for r in rows
    ]
    events.reverse()  # oldest first, matching the old JSON list's insertion order
    return events


class MedicationScheduler:
    """Owns the AsyncIOScheduler instance and (re)builds jobs from the reminders table."""

    def __init__(self, dispatch: DispatchFn, room_name: str) -> None:
        self._scheduler = AsyncIOScheduler()
        self._dispatch = dispatch
        self._room_name = room_name

    def start(self) -> None:
        self.rebuild_jobs()
        if not self._scheduler.running:
            self._scheduler.start()
        _set_current(self)

    def shutdown(self) -> None:
        if self._scheduler.running:
            self._scheduler.shutdown(wait=False)

    def rebuild_jobs(self) -> None:
        """Recompute jobs from the current reminders doc — call after any edit
        to the medication schedule (e.g. after PUT /api/reminders) so the
        schedule always matches what the patient sees in the app."""
        self._scheduler.remove_all_jobs()
        doc = load_reminders()
        if not doc.get("enabled", True):
            logger.info("Reminders disabled — no medication-time jobs scheduled")
            return
        for med in doc["medications"]:
            self._scheduler.add_job(
                self._fire,
                trigger=build_trigger(med["time"]),
                args=[med["id"], med["name"], med["time"]],
                id=f"med-{med['id']}",
                replace_existing=True,
                misfire_grace_time=60,
            )
        logger.info("Scheduled %d medication-time job(s)", len(doc["medications"]))

    async def _fire(self, medication_id: str, medication_name: str, scheduled_time: str) -> None:
        now = datetime.now()
        hour, minute = (int(part) for part in scheduled_time.split(":"))
        scheduled_at = now.replace(hour=hour, minute=minute, second=0, microsecond=0)

        # Greeting context ("reminder_call") reaches the agent via the
        # LiveKit job dispatch's metadata field (see dispatch_agent), not an
        # env var — the agent worker is a separate OS process from this
        # backend, so os.environ writes here would never actually reach it.
        # dispatch_agent()'s default greeting_context is already
        # "reminder_call", matching this call site.
        dispatched = await self._dispatch(self._room_name)
        event = record_event(
            medication_id, medication_name, scheduled_time, scheduled_at, now, dispatched
        )
        logger.info(
            "scheduler.initiated med=%s drift_s=%.1f within_target=%s agent_dispatched=%s",
            medication_name,
            event["drift_seconds"],
            event["within_target"],
            dispatched,
        )

        # Tell any connected client it's check-in time so it can activate its
        # own voice UI — the agent joining server-side isn't enough on its
        # own, since nothing is listening on the LiveKit room until the
        # patient's device also joins. Pushed over the existing /ws/state
        # channel (see state_bus.py) rather than a real inbound webhook,
        # since a phone can't receive one.
        await state_bus.broadcast({
            "type": "checkin_ready",
            "room": self._room_name,
            "medication_id": medication_id,
            "medication_name": medication_name,
            "scheduled_time": scheduled_time,
            "agent_dispatched": dispatched,
        })
