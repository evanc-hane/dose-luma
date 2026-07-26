"""HTTP surface for the voice agent's tools — duty check, medications CRUD,
notes CRUD. Thin dispatch only; every SQL statement lives in duties.py /
medications_crud.py / notes.py, not here.
"""

from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from routes.state import broadcast_adherence_state

router = APIRouter(prefix="/api", tags=["agent"])


@router.get("/agent/duty")
async def get_duty():
    """IDLE (companion mode) vs MEDICATION_ALERT — see duties.py."""
    import duties

    return duties.compute_duty()


CrudAction = Literal["create", "read", "update", "delete"]


class MedicationCrudBody(BaseModel):
    action: CrudAction
    medication_id: str = ""
    name: str = ""
    time: str = ""


@router.post("/medications/crud")
async def medications_crud(body: MedicationCrudBody):
    import medications_crud as crud
    import scheduler

    try:
        if body.action == "create":
            result = crud.create_medication(body.name, body.time)
        elif body.action == "read":
            result = crud.read_medications()
        elif body.action == "update":
            result = crud.update_medication(body.medication_id, name=body.name or None, time=body.time or None)
        elif body.action == "delete":
            result = {"deleted": crud.delete_medication(body.medication_id)}
        else:
            raise HTTPException(status_code=400, detail=f"Unknown action {body.action!r}")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    if body.action in ("create", "update", "delete"):
        scheduler.rebuild_if_running()
        await broadcast_adherence_state()
    return {"action": body.action, "result": result}


class NoteCrudBody(BaseModel):
    action: CrudAction
    note_id: str = ""
    title: str = ""
    content_markdown: str = ""


@router.post("/notes/crud")
async def notes_crud(body: NoteCrudBody):
    import notes

    try:
        if body.action == "create":
            result = notes.create_note(body.title, body.content_markdown)
        elif body.action == "read":
            result = notes.get_note(body.note_id) if body.note_id else notes.list_notes()
        elif body.action == "update":
            result = notes.update_note(
                body.note_id, title=body.title or None, content_markdown=body.content_markdown or None
            )
        elif body.action == "delete":
            result = {"deleted": notes.delete_note(body.note_id)}
        else:
            raise HTTPException(status_code=400, detail=f"Unknown action {body.action!r}")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return {"action": body.action, "result": result}
