"""
Dynamic greeting line management for context-aware agent responses.

Greetings are volatile data that can be updated via API without restarting.
Supports multiple contexts: reminder_call, web_session, user_initiated.
"""

import random
from typing import Optional

import config


class GreetingManager:
    """Select greeting lines based on session context."""

    CONTEXTS = {"reminder_call", "web_session", "user_initiated"}

    @staticmethod
    def get_greeting(context: str) -> str:
        """Get a random greeting for the given context.

        Args:
            context: one of CONTEXTS or None (defaults to reminder_call)

        Returns:
            A greeting instruction string or fallback to ALI_GREETING
        """
        if context is None:
            context = "reminder_call"

        if context not in GreetingManager.CONTEXTS:
            raise ValueError(f"Unknown context {context!r}, must be one of {GreetingManager.CONTEXTS}")

        agent_cfg = config.get_agent_config()
        templates = agent_cfg.get("greeting_templates", {})

        if context in templates and templates[context]:
            return random.choice(templates[context])

        # Fallback: agent generates its own greeting
        from voice_agent import ALI_GREETING

        return ALI_GREETING

    @staticmethod
    def list_contexts() -> dict:
        """Return all configured greeting contexts and templates."""
        agent_cfg = config.get_agent_config()
        return agent_cfg.get("greeting_templates", {})

    @staticmethod
    def update_greeting(context: str, new_lines: list[str]) -> bool:
        """Update greeting templates for a context (would persist to DB in production)."""
        if context not in GreetingManager.CONTEXTS:
            raise ValueError(f"Unknown context {context!r}")

        agent_cfg = config.get_agent_config()
        templates = agent_cfg.get("greeting_templates", {})
        templates[context] = new_lines

        # TODO: Persist to database or config file
        # For now, this lives in memory until restart
        return True
