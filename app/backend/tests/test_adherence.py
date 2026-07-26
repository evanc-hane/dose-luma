"""Regression guards for medication adherence status + caregiver alerts."""

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


class TestAdherence(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        tmp_dir = Path(tmp.name)

        self.db_patch = mock.patch.object(db, "DB_PATH", tmp_dir / "test.db")
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
        self.db_patch.start()
        db.init_db()
        self.env_patch.start()
        self.addCleanup(self.db_patch.stop)
        self.addCleanup(self.env_patch.stop)

        reminders.save_reminders(
            {
                "enabled": True,
                "medications": [
                    {"id": "morning", "name": "Metformin", "time": "08:00"},
                    {"id": "evening", "name": "Lisinopril", "time": "20:00"},
                ],
            }
        )

    def test_pending_before_scheduled_time(self) -> None:
        now = datetime(2026, 7, 20, 7, 0)
        statuses = {s["id"]: s["status"] for s in adherence.today_status(now)}
        self.assertEqual(statuses["morning"], "pending")
        self.assertEqual(statuses["evening"], "pending")

    def test_pending_within_grace_period(self) -> None:
        now = datetime(2026, 7, 20, 8, 30)
        statuses = {s["id"]: s["status"] for s in adherence.today_status(now)}
        self.assertEqual(statuses["morning"], "pending")

    def test_missed_after_grace_period(self) -> None:
        now = datetime(2026, 7, 20, 9, 30)
        statuses = {s["id"]: s["status"] for s in adherence.today_status(now)}
        self.assertEqual(statuses["morning"], "missed")
        self.assertEqual(statuses["evening"], "pending")

    def test_mark_taken(self) -> None:
        now = datetime(2026, 7, 20, 8, 5)
        record = adherence.mark_taken("morning", now)
        self.assertEqual(record["status"], "taken")
        self.assertIsNotNone(record["taken_at"])

        statuses = {s["id"]: s["status"] for s in adherence.today_status(now)}
        self.assertEqual(statuses["morning"], "taken")

    def test_mark_taken_unknown_medication_raises(self) -> None:
        with self.assertRaises(ValueError):
            adherence.mark_taken("does-not-exist", datetime(2026, 7, 20, 8, 5))

    def test_alerts_only_missed_and_undismissed(self) -> None:
        now = datetime(2026, 7, 20, 9, 30)
        alerts = adherence.list_alerts(now)
        self.assertEqual([a["medication_id"] for a in alerts], ["morning"])
        self.assertEqual(alerts[0]["type"], "missed")

    def test_dismiss_alert_clears_it(self) -> None:
        now = datetime(2026, 7, 20, 9, 30)
        alerts = adherence.list_alerts(now)
        adherence.dismiss_alert(alerts[0]["id"], now)
        self.assertEqual(adherence.list_alerts(now), [])

    def test_taking_dose_clears_any_pending_alert(self) -> None:
        now = datetime(2026, 7, 20, 9, 30)
        self.assertEqual(len(adherence.list_alerts(now)), 1)
        adherence.mark_taken("morning", now)
        # Missed alert should be filtered via dismiss key after mark_taken
        self.assertEqual(
            [a for a in adherence.list_alerts(now) if a["type"] == "missed"],
            [],
        )

    def test_alerts_reset_on_a_new_day(self) -> None:
        day1 = datetime(2026, 7, 20, 9, 30)
        adherence.dismiss_alert("morning", day1)
        self.assertEqual(adherence.list_alerts(day1), [])

        day2 = datetime(2026, 7, 21, 9, 30)
        self.assertEqual(
            [a["medication_id"] for a in adherence.list_alerts(day2)],
            ["morning"],
        )

    def test_history_length_and_order(self) -> None:
        now = datetime(2026, 7, 20, 9, 30)
        days = adherence.history(days=3, now=now)
        self.assertEqual(len(days), 3)
        self.assertEqual(
            [d["date"] for d in days],
            ["2026-07-20", "2026-07-19", "2026-07-18"],
        )

    def test_history_past_day_is_missed_not_pending(self) -> None:
        # Evening dose (20:00) on a past day must read "missed", not "pending",
        # even though "now" is in the early morning (a bug in an earlier version
        # reconstructed the scheduled time on *today's* date instead of the
        # historical day's date).
        now = datetime(2026, 7, 20, 7, 0)
        days = adherence.history(days=2, now=now)
        yesterday = next(d for d in days if d["date"] == "2026-07-19")
        statuses = {m["id"]: m["status"] for m in yesterday["medications"]}
        self.assertEqual(statuses["morning"], "missed")
        self.assertEqual(statuses["evening"], "missed")

    def test_history_reflects_taken_dose_on_that_day(self) -> None:
        yesterday = datetime(2026, 7, 19, 8, 5)
        adherence.mark_taken("morning", yesterday)

        now = datetime(2026, 7, 20, 7, 0)
        days = adherence.history(days=2, now=now)
        y = next(d for d in days if d["date"] == "2026-07-19")
        statuses = {m["id"]: m["status"] for m in y["medications"]}
        self.assertEqual(statuses["morning"], "taken")
        self.assertEqual(statuses["evening"], "missed")


if __name__ == "__main__":
    unittest.main()
