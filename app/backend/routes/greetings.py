"""Voice agent greeting templates (context-aware, configurable at runtime)."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/api/greetings", tags=["greetings"])


@router.get("")
async def get_greetings():
    """Get all configured greeting templates by context.

    Contexts: reminder_call, web_session, user_initiated
    """
    from greeting_manager import GreetingManager

    return {
        "contexts": list(GreetingManager.CONTEXTS),
        "templates": GreetingManager.list_contexts(),
    }


class UpdateGreetingBody(BaseModel):
    context: str
    lines: list[str]


@router.put("/{context}")
async def put_greeting(context: str, body: UpdateGreetingBody):
    """Update greeting templates for a context (no restart needed).

    Args:
        context: one of reminder_call, web_session, user_initiated
        body.lines: list of greeting text lines to randomly select from
    """
    from greeting_manager import GreetingManager

    try:
        GreetingManager.update_greeting(context, body.lines)
        return {
            "context": context,
            "lines": body.lines,
            "status": "updated",
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
