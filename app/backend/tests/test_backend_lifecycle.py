"""Regression: backend lifecycle decisions (avoid crash-loop / double-start)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from backend_lifecycle import should_start_backend  # noqa: E402


class TestShouldStartBackend(unittest.TestCase):
    def test_skip_when_already_healthy(self) -> None:
        self.assertFalse(should_start_backend(health_ok=True))

    def test_start_when_unhealthy(self) -> None:
        self.assertTrue(should_start_backend(health_ok=False))


if __name__ == "__main__":
    unittest.main()
