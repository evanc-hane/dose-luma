"""Regression tests for duplicate-dose safeguards and alert merging."""

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

import adherence  # noqa: E402
import db  # noqa: E402
import reminders  # noqa: E402


class TestFailSafeAndAlerts(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        tmp_dir = Path(tmp.name)

        self.db_patch = mock.patch.object(db, "DB_PATH", tmp_dir / "test.db")
        self.db_patch.start()
        db.init_db()
        self.addCleanup(self.db_patch.stop)

        # Blank every outbound-notification credential so a developer's real
        # Twilio/webhook config (if any is set in their shell) can never leak
        # into a test run and dispatch a real SMS/call/webhook POST.
        self.env_patch = mock.patch.dict(
            "os.environ",
            {
                "CAREGIVER_WEBHOOK_URL": "",
                "TWILIO_ACCOUNT_SID": "",
                "TWILIO_AUTH_TOKEN": "",
                "TWILIO_FROM_NUMBER": "",
                "CAREGIVER_PHONE_NUMBER": "",
                "SECONDARY_CONTACT_PHONE_NUMBER": "",
            },
            clear=False,
        )
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

        reminders.save_reminders(
            {
                "enabled": True,
                "medications": [
                    {"id": "morning", "name": "Metformin", "time": "08:00"},
                ],
            }
        )

    def test_mark_taken_locks_second_call(self) -> None:
        now = datetime(2026, 7, 20, 8, 5)
        first = adherence.mark_taken("morning", now)
        self.assertTrue(first["locked"])
        with self.assertRaises(adherence.DuplicateDoseError):
            adherence.mark_taken("morning", now)

    def test_apply_taken_then_duplicate_escalates_overdose(self) -> None:
        now = datetime(2026, 7, 20, 8, 5)
        first = adherence.apply_intent("Taken", medication_id="morning", now=now)
        self.assertEqual(first["action"], "marked_taken")

        second = adherence.apply_intent(
            "Taken",
            medication_id="morning",
            transcript="I took another one",
            now=now,
        )
        self.assertTrue(second["duplicate"])
        self.assertEqual(second["action"], "overdose_escalated")
        self.assertEqual(second["alert"]["type"], "overdose_risk")

    def test_distress_creates_critical_alert(self) -> None:
        now = datetime(2026, 7, 20, 8, 5)
        result = adherence.apply_intent(
            "Distress",
            medication_id="morning",
            transcript="I'm scared help",
            now=now,
        )
        self.assertEqual(result["alert"]["type"], "distress")
        self.assertEqual(result["alert"]["priority"], "critical")
        alerts = adherence.list_alerts(now)
        self.assertTrue(any(a["type"] == "distress" for a in alerts))

    def test_missed_sync_creates_alert_once(self) -> None:
        now = datetime(2026, 7, 20, 9, 30)
        created = adherence.sync_missed_alerts(now)
        self.assertEqual(len(created), 1)
        created2 = adherence.sync_missed_alerts(now)
        self.assertEqual(created2, [])


if __name__ == "__main__":
    unittest.main()
