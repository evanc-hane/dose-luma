"""Regression guards for root config.json model routing."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest import mock

BACKEND_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = BACKEND_DIR.parents[1]  # app/backend → repo root
ROOT_CONFIG = REPO_ROOT / "config.json"

if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))


class TestRootConfigJson(unittest.TestCase):
    def test_root_config_exists(self) -> None:
        self.assertTrue(ROOT_CONFIG.is_file(), f"missing {ROOT_CONFIG}")

    def test_required_sections_and_routing(self) -> None:
        with ROOT_CONFIG.open(encoding="utf-8") as f:
            cfg = json.load(f)

        for section in ("agent", "services", "stt", "llm", "tts", "vad", "reminders"):
            self.assertIn(section, cfg)

        self.assertTrue(cfg["reminders"]["enabled"])
        self.assertEqual(
            cfg["reminders"]["times"],
            ["08:00", "08:05", "08:10", "08:15", "08:20", "08:25"],
        )

        # Cerebras Cloud (fast-inference, OpenAI-compatible) for the LLM leg.
        self.assertIn("llm", cfg["services"])
        self.assertIn("speech", cfg["services"])
        self.assertEqual(cfg["services"]["llm"]["provider"], "cerebras")
        self.assertIn("base_url", cfg["services"]["llm"])
        self.assertNotIn("ollama", cfg["services"])
        self.assertNotIn("ollama_base_url", cfg["services"])

        # Single LLM only — no language routing (switching is hard / avoided).
        self.assertNotIn("routing", cfg["llm"])
        self.assertNotIn("provider", cfg["llm"])
        self.assertEqual(cfg["llm"]["model"], "gpt-oss-120b")

        # ElevenLabs for both STT and TTS.
        self.assertEqual(cfg["stt"]["provider"], "elevenlabs")
        self.assertEqual(cfg["stt"]["model_id"], "scribe_v1")
        self.assertEqual(cfg["tts"]["provider"], "elevenlabs")
        self.assertIn("voice_id", cfg["tts"])


class TestConfigModule(unittest.TestCase):
    def setUp(self) -> None:
        # Keep the shared module object intact so mocks held by other test
        # modules continue to target the same config instance.
        import config as config_module

        self.config = config_module
        self.config.load_config.cache_clear()

    def tearDown(self) -> None:
        self.config.load_config.cache_clear()

    def test_loads_from_repo_root(self) -> None:
        self.assertEqual(self.config.CONFIG_PATH.resolve(), ROOT_CONFIG.resolve())
        loaded = self.config.load_config()
        self.assertEqual(loaded["agent"]["name"], "AI-LiveKit-Agent")

    def test_llm_and_tts_accessors(self) -> None:
        self.assertEqual(self.config.llm_model(), "gpt-oss-120b")
        self.assertEqual(self.config.llm_fallback_contains(), "Qwythos")
        self.assertEqual(self.config.llm_provider(), "cerebras")
        self.assertTrue(self.config.llm_base_url().endswith("/v1"))

    def test_unknown_tts_route_raises(self) -> None:
        # tts.routing was only used by the (now retired) speaches provider —
        # with no routing table at all, any language lookup is "unknown".
        with self.assertRaises(KeyError):
            self.config.tts_route("en")

    def test_missing_section_raises(self) -> None:
        fake = {"agent": {"name": "x"}}
        with mock.patch.object(self.config, "load_config", return_value=fake):
            with self.assertRaises(KeyError):
                self.config.stt_model()


if __name__ == "__main__":
    unittest.main()
