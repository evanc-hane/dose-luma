"""Regression guards for LiveKit URL advertising (mobile LAN access)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from livekit_integration.advertise import advertise_livekit_url  # noqa: E402


class TestAdvertiseLivekitUrl(unittest.TestCase):
    def test_rewrites_localhost_for_lan_client(self) -> None:
        self.assertEqual(
            advertise_livekit_url("ws://localhost:7880", "10.39.35.111:8801"),
            "ws://10.39.35.111:7880",
        )

    def test_normalizes_localhost_to_ipv4_loopback(self) -> None:
        # Simulator prefers ::1 for "localhost"; uvicorn is IPv4-only on 0.0.0.0.
        self.assertEqual(
            advertise_livekit_url("ws://localhost:7880", "localhost:8801"),
            "ws://127.0.0.1:7880",
        )
        self.assertEqual(
            advertise_livekit_url("ws://localhost:7880", "127.0.0.1:8801"),
            "ws://127.0.0.1:7880",
        )

    def test_leaves_non_local_url_alone(self) -> None:
        self.assertEqual(
            advertise_livekit_url("wss://lk.example.com", "10.0.0.2:8801"),
            "wss://lk.example.com",
        )

    def test_handles_missing_host(self) -> None:
        self.assertEqual(
            advertise_livekit_url("ws://localhost:7880", None),
            "ws://127.0.0.1:7880",
        )


if __name__ == "__main__":
    unittest.main()
