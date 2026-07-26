"""Regression tests for multi-tier caregiver escalation:
Tier 1 SMS, Tier 2 automated call, Tier 3 secondary-contact call."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import caregiver_notify  # noqa: E402
import db  # noqa: E402


class TestTwilioNoOpWithoutCredentials(unittest.TestCase):
    """No TWILIO_* env vars set anywhere in this suite (see backend_lifecycle
    tests for the pattern) — every Twilio call must no-op safely."""

    def test_send_sms_without_credentials_is_safe_noop(self) -> None:
        import twilio_notify

        with mock.patch.dict("os.environ", {}, clear=True):
            result = twilio_notify.send_sms("+15550001111", "hello")
        self.assertFalse(result["delivered"])
        self.assertFalse(result["configured"])

    def test_place_call_without_credentials_is_safe_noop(self) -> None:
        import twilio_notify

        with mock.patch.dict("os.environ", {}, clear=True):
            result = twilio_notify.place_call("+15550001111", "hello")
        self.assertFalse(result["delivered"])
        self.assertFalse(result["configured"])


class TestAcknowledgmentAndEscalation(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db_patch = mock.patch.object(db, "DB_PATH", Path(tmp.name) / "test.db")
        self.db_patch.start()
        db.init_db()
        self.addCleanup(self.db_patch.stop)
        self.env_patch = mock.patch.dict(
            "os.environ",
            {"CAREGIVER_WEBHOOK_URL": "", "CAREGIVER_PHONE_NUMBER": "", "SECONDARY_CONTACT_PHONE_NUMBER": ""},
            clear=False,
        )
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

    def test_missing_alert_counts_as_acknowledged(self) -> None:
        self.assertTrue(caregiver_notify.is_acknowledged("does-not-exist"))

    def test_undismissed_alert_is_not_acknowledged(self) -> None:
        alert = caregiver_notify.create_alert(
            alert_type="distress", medication_id="m1", name="Metformin",
            priority="critical", notify=False,
        )
        self.assertFalse(caregiver_notify.is_acknowledged(alert["id"]))

    def test_dismissing_marks_acknowledged(self) -> None:
        alert = caregiver_notify.create_alert(
            alert_type="distress", medication_id="m1", name="Metformin",
            priority="critical", notify=False,
        )
        caregiver_notify.dismiss_stored_alert(alert["id"])
        self.assertTrue(caregiver_notify.is_acknowledged(alert["id"]))

    async def test_escalation_skips_low_priority_alerts(self) -> None:
        with mock.patch("caregiver_notify.asyncio.get_running_loop") as mock_loop:
            caregiver_notify.create_alert(
                alert_type="delayed", medication_id="m1", name="Metformin",
                priority="normal", notify=True,
            )
            mock_loop.assert_not_called()

    async def test_escalation_schedules_task_for_high_priority(self) -> None:
        with mock.patch("caregiver_notify.asyncio.get_running_loop") as mock_loop:
            caregiver_notify.create_alert(
                alert_type="distress", medication_id="m1", name="Metformin",
                priority="critical", notify=True,
            )
            mock_loop.return_value.create_task.assert_called_once()
            # The loop itself is mocked, so the coroutine passed to
            # create_task() never actually runs — close it to avoid an
            # "unawaited coroutine" warning from the real event loop.
            mock_loop.return_value.create_task.call_args[0][0].close()

    async def test_tier2_and_tier3_fire_when_unacknowledged(self) -> None:
        alert = caregiver_notify.create_alert(
            alert_type="distress", medication_id="m1", name="Metformin",
            message="Distress signal", priority="critical", notify=False,
        )
        calls: list[tuple[str, str]] = []

        async def fake_sleep(_seconds: float) -> None:
            return None

        def fake_place_call(to_number: str, say_text: str):
            calls.append((to_number, say_text))
            return {"delivered": False, "configured": False, "error": None}

        with mock.patch("caregiver_notify.asyncio.sleep", fake_sleep), \
             mock.patch("twilio_notify.place_call", side_effect=fake_place_call):
            await caregiver_notify._escalate(alert["id"], "Distress signal")

        self.assertEqual(len(calls), 2)  # Tier 2 (caregiver) + Tier 3 (secondary)

    async def test_no_escalation_calls_once_acknowledged(self) -> None:
        alert = caregiver_notify.create_alert(
            alert_type="distress", medication_id="m1", name="Metformin",
            message="Distress signal", priority="critical", notify=False,
        )
        caregiver_notify.dismiss_stored_alert(alert["id"])
        calls: list[tuple[str, str]] = []

        async def fake_sleep(_seconds: float) -> None:
            return None

        def fake_place_call(to_number: str, say_text: str):
            calls.append((to_number, say_text))
            return {"delivered": False, "configured": False, "error": None}

        with mock.patch("caregiver_notify.asyncio.sleep", fake_sleep), \
             mock.patch("twilio_notify.place_call", side_effect=fake_place_call):
            await caregiver_notify._escalate(alert["id"], "Distress signal")

        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
