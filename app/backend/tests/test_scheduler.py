"""Regression guards for the proactive scheduling engine."""

from __future__ import annotations

import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import db  # noqa: E402
import reminders  # noqa: E402
import scheduler  # noqa: E402


class TestPureHelpers(unittest.TestCase):
    def test_build_trigger_parses_hour_and_minute(self) -> None:
        trigger = scheduler.build_trigger("08:30")
        fields = {f.name: str(f) for f in trigger.fields}
        self.assertEqual(fields["hour"], "8")
        self.assertEqual(fields["minute"], "30")

    def test_compute_drift_seconds_positive_when_late(self) -> None:
        scheduled = datetime(2026, 7, 20, 8, 0, 0)
        fired = datetime(2026, 7, 20, 8, 0, 12)
        self.assertEqual(scheduler.compute_drift_seconds(scheduled, fired), 12.0)

    def test_compute_drift_seconds_negative_when_early(self) -> None:
        scheduled = datetime(2026, 7, 20, 8, 0, 20)
        fired = datetime(2026, 7, 20, 8, 0, 5)
        self.assertEqual(scheduler.compute_drift_seconds(scheduled, fired), -15.0)


class TestEventStore(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db_patch = mock.patch.object(db, "DB_PATH", Path(tmp.name) / "test.db")
        self.db_patch.start()
        db.init_db()
        self.addCleanup(self.db_patch.stop)

    def test_record_event_within_target(self) -> None:
        scheduled = datetime(2026, 7, 20, 8, 0, 0)
        fired = datetime(2026, 7, 20, 8, 0, 5)
        entry = scheduler.record_event("morning", "Metformin", "08:00", scheduled, fired, True)
        self.assertTrue(entry["within_target"])
        self.assertEqual(entry["drift_seconds"], 5.0)
        self.assertTrue(entry["agent_dispatched"])

    def test_record_event_outside_target(self) -> None:
        scheduled = datetime(2026, 7, 20, 8, 0, 0)
        fired = datetime(2026, 7, 20, 8, 1, 5)  # 65s late
        entry = scheduler.record_event("morning", "Metformin", "08:00", scheduled, fired, True)
        self.assertFalse(entry["within_target"])

    def test_recent_events_returns_persisted_entries_in_order(self) -> None:
        scheduled = datetime(2026, 7, 20, 8, 0, 0)
        scheduler.record_event("morning", "Metformin", "08:00", scheduled, scheduled, True)
        scheduler.record_event("evening", "Lisinopril", "20:00", scheduled, scheduled, False)
        events = scheduler.recent_events(limit=10)
        self.assertEqual([e["medication_id"] for e in events], ["morning", "evening"])

    def test_recent_events_respects_limit(self) -> None:
        scheduled = datetime(2026, 7, 20, 8, 0, 0)
        for i in range(5):
            scheduler.record_event(f"med{i}", f"Med {i}", "08:00", scheduled, scheduled, True)
        self.assertEqual(len(scheduler.recent_events(limit=2)), 2)


class TestMedicationScheduler(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db_patch = mock.patch.object(db, "DB_PATH", Path(tmp.name) / "test.db")
        self.db_patch.start()
        db.init_db()
        self.addCleanup(self.db_patch.stop)

        reminders.save_reminders(
            {
                "enabled": True,
                "medications": [
                    {"id": "morning", "name": "Metformin", "time": "08:00"},
                    {"id": "evening", "name": "Lisinopril", "time": "20:00"},
                ],
            }
        )

    async def _noop_dispatch(self, room_name: str) -> bool:
        return True

    def test_rebuild_jobs_creates_one_job_per_medication(self) -> None:
        sched = scheduler.MedicationScheduler(dispatch=self._noop_dispatch, room_name="test-room")
        sched.rebuild_jobs()
        job_ids = {job.id for job in sched._scheduler.get_jobs()}
        self.assertEqual(job_ids, {"med-morning", "med-evening"})

    def test_rebuild_jobs_is_idempotent(self) -> None:
        sched = scheduler.MedicationScheduler(dispatch=self._noop_dispatch, room_name="test-room")
        sched.rebuild_jobs()
        sched.rebuild_jobs()
        self.assertEqual(len(sched._scheduler.get_jobs()), 2)

    def test_rebuild_jobs_skips_when_reminders_disabled(self) -> None:
        reminders.save_reminders(
            {
                "enabled": False,
                "medications": [{"id": "morning", "name": "Metformin", "time": "08:00"}],
            }
        )
        sched = scheduler.MedicationScheduler(dispatch=self._noop_dispatch, room_name="test-room")
        sched.rebuild_jobs()
        self.assertEqual(sched._scheduler.get_jobs(), [])

    async def test_fire_dispatches_agent_and_records_event(self) -> None:
        dispatched_rooms: list[str] = []

        async def fake_dispatch(room_name: str) -> bool:
            dispatched_rooms.append(room_name)
            return True

        sched = scheduler.MedicationScheduler(dispatch=fake_dispatch, room_name="doseluma-room")

        # Fix "now" to 3s after the target time so drift is deterministic —
        # otherwise this test's pass/fail would depend on the wall-clock time
        # it happens to run at.
        fixed_now = datetime(2026, 7, 20, 8, 0, 3)
        with mock.patch.object(scheduler, "datetime") as mock_datetime:
            mock_datetime.now.return_value = fixed_now
            await sched._fire("morning", "Metformin", "08:00")

        self.assertEqual(dispatched_rooms, ["doseluma-room"])
        events = scheduler.recent_events(limit=1)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["medication_id"], "morning")
        self.assertEqual(events[0]["drift_seconds"], 3.0)
        self.assertTrue(events[0]["within_target"])


if __name__ == "__main__":
    unittest.main()
