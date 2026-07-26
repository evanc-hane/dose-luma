"""Regression guards for the named-medication reminder schedule."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import db  # noqa: E402
import reminders  # noqa: E402


class TestReminders(unittest.TestCase):
    def test_normalize_defaults(self) -> None:
        doc = reminders.normalize_reminders(None)
        self.assertTrue(doc["enabled"])
        times = [m["time"] for m in doc["medications"]]
        self.assertEqual(
            times,
            ["08:00", "08:05", "08:10", "08:15", "08:20", "08:25"],
        )
        # Five-minute gaps between the six defaults.
        minutes = [int(t[:2]) * 60 + int(t[3:]) for t in times]
        gaps = [b - a for a, b in zip(minutes, minutes[1:])]
        self.assertEqual(gaps, [5, 5, 5, 5, 5])

    def test_rejects_bad_time(self) -> None:
        with self.assertRaises(ValueError):
            reminders.normalize_reminders(
                {"medications": [{"name": "Aspirin", "time": "25:99"}]}
            )

    def test_rejects_missing_name(self) -> None:
        with self.assertRaises(ValueError):
            reminders.normalize_reminders(
                {"medications": [{"name": "  ", "time": "08:00"}]}
            )

    def test_assigns_id_when_missing(self) -> None:
        doc = reminders.normalize_reminders(
            {"medications": [{"name": "Aspirin", "time": "08:00"}]}
        )
        self.assertTrue(doc["medications"][0]["id"])

    def test_sorts_by_time(self) -> None:
        doc = reminders.normalize_reminders(
            {
                "medications": [
                    {"name": "Evening pill", "time": "20:00"},
                    {"name": "Morning pill", "time": "08:00"},
                ]
            }
        )
        self.assertEqual(
            [m["name"] for m in doc["medications"]],
            ["Morning pill", "Evening pill"],
        )

    def test_save_and_load_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "test.db"
            with mock.patch.object(db, "DB_PATH", store):
                db.init_db()
                saved = reminders.save_reminders(
                    {
                        "enabled": True,
                        "medications": [
                            {"id": "m1", "name": "Metformin", "time": "09:30"},
                            {"id": "m2", "name": "Lisinopril", "time": "21:00"},
                        ],
                    }
                )
                self.assertEqual(len(saved["medications"]), 2)
                loaded = reminders.load_reminders()
                self.assertEqual(loaded, saved)


if __name__ == "__main__":
    unittest.main()
