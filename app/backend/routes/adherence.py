"""Adherence status + caregiver alerts + intent classification.

Every mutation (mark taken, classify intent, dismiss alert) broadcasts the
new state over /ws/state — see routes/state.py.
"""

from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from routes.state import broadcast_adherence_state

router = APIRouter(prefix="/api", tags=["adherence"])


@router.get("/adherence")
async def get_adherence():
    """Today's per-medication status: taken / missed / pending."""
    import adherence

    return {"medications": adherence.today_status()}


@router.get("/adherence/history")
async def get_adherence_history(days: int = 7):
    """Per-medication status for each of the last `days` days, most recent first."""
    import adherence

    return {"days": adherence.history(days=days)}


@router.post("/adherence/{medication_id}/taken")
async def post_adherence_taken(medication_id: str):
    """Patient marks today's dose of `medication_id` as taken (Layer 1 lock)."""
    import adherence

    try:
        record = adherence.mark_taken(medication_id)
        await broadcast_adherence_state()
        return record
    except adherence.DuplicateDoseError as exc:
        raise HTTPException(
            status_code=409,
            detail={
                "error": "duplicate_dose",
                "medication_id": exc.medication_id,
                "taken_at": exc.taken_at,
            },
        ) from exc
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


class IntentClassifyBody(BaseModel):
    transcript: str
    medication_id: str | None = None
    use_llm: bool = True


@router.post("/intent/classify")
async def post_intent_classify(body: IntentClassifyBody):
    """Classify adherence intent and apply safety or alert side effects."""
    import adherence
    import intent as intent_mod

    result = intent_mod.classify_utterance(body.transcript, use_llm=body.use_llm)
    intent_mod.log_classification(
        transcript=body.transcript,
        result=result,
        medication_id=body.medication_id,
    )
    try:
        applied = adherence.apply_intent(
            result["state"],
            medication_id=body.medication_id,
            transcript=body.transcript,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    await broadcast_adherence_state()

    return {
        "state": result["state"],
        "confidence": result["confidence"],
        "rationale": result.get("rationale", ""),
        "method": result.get("method", ""),
        "applied": applied,
    }


class ReportStateBody(BaseModel):
    state: str  # Taken | Refused | Delayed | Confused | Distress
    medication_id: str | None = None
    transcript: str = ""


@router.post("/adherence/report")
async def post_adherence_report(body: ReportStateBody):
    """Atomic adherence-state action, called directly by the voice agent's
    per-state tools (mark_medication_taken, report_medication_refused, ...).

    Unlike /api/intent/classify, this skips re-classification entirely —
    the conversational LLM already determined the state from context, so
    there's no need for a second, separate classification LLM call. Still
    logged to intent_log for auditing and benchmarking, with
    method="agent_direct" instead of "llm"/"heuristic".
    """
    import adherence
    import intent as intent_mod

    if body.state not in intent_mod.INTENT_STATES:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown state {body.state!r}; must be one of {intent_mod.INTENT_STATES}",
        )

    result = {"state": body.state, "confidence": 1.0, "rationale": "Reported directly by voice agent", "method": "agent_direct"}
    intent_mod.log_classification(
        transcript=body.transcript,
        result=result,
        medication_id=body.medication_id,
    )
    try:
        applied = adherence.apply_intent(
            body.state,
            medication_id=body.medication_id,
            transcript=body.transcript,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    await broadcast_adherence_state()

    return {
        "state": body.state,
        "confidence": 1.0,
        "method": "agent_direct",
        "applied": applied,
    }


def _as_missed_alert(alert: dict, patient: dict | None) -> dict:
    """Reshape an internal alert into the DoseLuma Swift app's MissedAlert
    JSON shape. There's only one shared medication list in this backend
    (see routes/links.py), so every alert is attributed to the first
    registered patient account rather than a specific one."""
    created = alert.get("created_at") or ""
    scheduled_date = created.split("T")[0] if created else ""
    return {
        "id": alert["id"],
        "patient_id": patient["id"] if patient else "",
        "patient_name": patient["display_name"] if patient else "Patient",
        "medication_name": alert.get("name", ""),
        "window_name": alert.get("time", ""),
        "scheduled_date": scheduled_date,
        "alerted_at": created,
        "action": None,
        "action_by": None,
        "action_at": None,
    }


@router.get("/alerts")
async def get_alerts(x_user_token: str | None = Header(default=None)):
    """Return missed-dose, intent, duplicate-dose, and distress alerts.

    Returns the legacy flat shape for unauthenticated dashboard/voice
    consumers, or the DoseLuma Swift app's MissedAlert shape when a valid
    x-user-token is presented (its caregiver tab always sends one).
    """
    import adherence

    alerts = adherence.list_alerts()

    if x_user_token:
        import users as users_mod

        user = users_mod.find_by_token(x_user_token)
        if user:
            patient = next(
                (u for u in users_mod.list_users() if u.get("role") in ("patient", "both")),
                None,
            )
            return {"alerts": [_as_missed_alert(a, patient) for a in alerts]}

    return {"alerts": alerts}


@router.post("/alerts/{alert_id}/dismiss")
async def post_alert_dismiss(alert_id: str):
    """Caregiver acknowledges an alert (by alert id or medication id)."""
    import adherence

    adherence.dismiss_alert(alert_id)
    await broadcast_adherence_state()
    return {"status": "dismissed", "id": alert_id}


@router.post("/alerts/{alert_id}/action")
async def post_alert_action(alert_id: str, body: dict):
    """DoseLuma Swift app's caregiver alert action (any action dismisses it —
    there's no per-action state machine on the backend today)."""
    import adherence

    adherence.dismiss_alert(alert_id)
    await broadcast_adherence_state()
    return {}
