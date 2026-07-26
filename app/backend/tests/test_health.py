"""Regression guards for GET /api/health payload."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from health import build_health_payload  # noqa: E402


class TestBuildHealthPayload(unittest.TestCase):
    def test_healthy_when_livekit_configured(self) -> None:
        payload = build_health_payload(livekit_url="ws://127.0.0.1:7880")
        self.assertEqual(payload["status"], "healthy")
        self.assertEqual(payload["service"], "DoseLuma Backend")
        self.assertEqual(payload["livekit"], "configured")

    def test_reports_not_configured_without_url(self) -> None:
        payload = build_health_payload(livekit_url=None)
        self.assertEqual(payload["status"], "healthy")
        self.assertEqual(payload["livekit"], "not_configured")

    def test_empty_url_is_not_configured(self) -> None:
        payload = build_health_payload(livekit_url="")
        self.assertEqual(payload["livekit"], "not_configured")


if __name__ == "__main__":
    unittest.main()
