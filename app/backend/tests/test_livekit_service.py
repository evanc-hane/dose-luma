"""Regression guard for the agent-dispatch cooldown (avoids double-dispatch
when the proactive scheduler and a device's /api/livekit/connect race)."""

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
from livekit_integration.service import LiveKitService  # noqa: E402


class TestDispatchCooldown(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        # Dispatch cooldown now lives in voice_sessions' SQLite-persisted
        # store (see voice_sessions.py) instead of an in-memory dict on the
        # service instance, so backend restarts don't forget a dispatch.
        # Point it at a throwaway DB for the test instead of the real
        # doseluma.db the running backend uses.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db_patch = mock.patch.object(db, "DB_PATH", Path(tmp.name) / "test.db")
        self.db_patch.start()
        db.init_db()
        self.addCleanup(self.db_patch.stop)

        self.service = LiveKitService()
        self.service.api_url = "http://localhost:7880"
        self.service.api_key = "devkey"
        self.service.api_secret = "secret"
        self.service.agent_name = "AI-LiveKit-Agent"

    def _mock_lk_api(self):
        mock_lk = mock.AsyncMock()
        mock_lk_api_module = mock.MagicMock()
        mock_lk_api_module.LiveKitAPI.return_value = mock_lk
        mock_lk_api_module.CreateAgentDispatchRequest = mock.MagicMock()
        return mock_lk, mock_lk_api_module

    async def test_second_dispatch_within_cooldown_is_skipped(self) -> None:
        mock_lk, mock_lk_api_module = self._mock_lk_api()
        with mock.patch.dict(sys.modules, {"livekit.api": mock_lk_api_module}):
            first = await self.service.dispatch_agent("room-a")
            second = await self.service.dispatch_agent("room-a")

        self.assertTrue(first)
        self.assertTrue(second)
        self.assertEqual(mock_lk.agent_dispatch.create_dispatch.call_count, 1)

    async def test_different_rooms_both_dispatch(self) -> None:
        mock_lk, mock_lk_api_module = self._mock_lk_api()
        with mock.patch.dict(sys.modules, {"livekit.api": mock_lk_api_module}):
            await self.service.dispatch_agent("room-a")
            await self.service.dispatch_agent("room-b")

        self.assertEqual(mock_lk.agent_dispatch.create_dispatch.call_count, 2)

    async def test_dispatch_again_after_cooldown_expires(self) -> None:
        mock_lk, mock_lk_api_module = self._mock_lk_api()
        with mock.patch.dict(sys.modules, {"livekit.api": mock_lk_api_module}):
            await self.service.dispatch_agent("room-a")
            # Simulate the cooldown window having already elapsed.
            conn = db.get_connection()
            conn.execute(
                "UPDATE voice_dispatches SET last_dispatch_at = last_dispatch_at - ? "
                "WHERE room = 'room-a'",
                (self.service._DISPATCH_COOLDOWN_SECONDS + 1,),
            )
            conn.commit()
            conn.close()
            await self.service.dispatch_agent("room-a")

        self.assertEqual(mock_lk.agent_dispatch.create_dispatch.call_count, 2)


if __name__ == "__main__":
    unittest.main()
