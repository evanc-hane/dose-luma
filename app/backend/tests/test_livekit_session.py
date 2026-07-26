"""Regression guards for LiveKit session initiation helpers."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from livekit_integration.session import resolve_room_name  # noqa: E402


class TestResolveRoomName(unittest.TestCase):
    def test_uses_requested_when_present(self) -> None:
        self.assertEqual(
            resolve_room_name("my-room", "doseluma-room"),
            "my-room",
        )

    def test_falls_back_to_default(self) -> None:
        self.assertEqual(
            resolve_room_name("", "doseluma-room"),
            "doseluma-room",
        )
        self.assertEqual(
            resolve_room_name(None, "doseluma-room"),
            "doseluma-room",
        )
        self.assertEqual(
            resolve_room_name("   ", "doseluma-room"),
            "doseluma-room",
        )

    def test_raises_when_both_empty(self) -> None:
        with self.assertRaises(ValueError):
            resolve_room_name("", "")


if __name__ == "__main__":
    unittest.main()
