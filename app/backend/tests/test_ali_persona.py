"""Regression: ALI spoken persona must stay human and hide the stack."""

from __future__ import annotations

import unittest
from pathlib import Path

AGENT_FILE = Path(__file__).resolve().parents[2] / "agent" / "voice_agent.py"


class TestAliPersonaPrompt(unittest.TestCase):
    def setUp(self) -> None:
        self.source = AGENT_FILE.read_text(encoding="utf-8")

    def test_instructions_forbid_provider_leak(self) -> None:
        self.assertIn("ALI_INSTRUCTIONS", self.source)
        self.assertIn("Never mention", self.source)
        self.assertIn("provider", self.source.lower())
        self.assertIn("Ollama", self.source)
        self.assertIn("Qwythos", self.source)
        self.assertIn("warm", self.source.lower())
        self.assertIn("friendly", self.source.lower())
        self.assertIn("report_medication_status", self.source)

    def test_greeting_stays_human(self) -> None:
        # ALI_GREETING is spoken directly via session.say() (see entrypoint),
        # not routed through the LLM as an instruction — so it must be a
        # plain, human-sounding line rather than meta-instructions, and it
        # must carry a {name} placeholder so the greeting can address the
        # patient by name (see _resolve_patient_name / _select_greeting_template).
        import re

        match = re.search(r'ALI_GREETING = \(\s*"([^"]*)"', self.source)
        self.assertIsNotNone(match, "ALI_GREETING definition not found")
        greeting = match.group(1)
        self.assertIn("{name}", greeting)
        for leaked_term in ("AI", "model", "provider", "Ollama", "Qwythos"):
            self.assertNotIn(leaked_term.lower(), greeting.lower())


if __name__ == "__main__":
    unittest.main()
