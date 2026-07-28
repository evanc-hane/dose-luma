"""Regression guards for configurable SQLite persistence."""

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


class TestDatabasePath(unittest.TestCase):
    def test_init_db_creates_configured_parent_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "nested" / "doseluma.db"
            with mock.patch.object(db, "DB_PATH", path):
                db.init_db()

            self.assertTrue(path.is_file())
