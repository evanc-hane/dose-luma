"""Caregiver's patient roster + per-patient adherence/medications.

There's no invite-code or QR pairing ceremony — every registered patient
account is visible to every caregiver account. That matches this app's
single-household "Walled Garden" model (see README): once you're inside,
everyone identifies by name with no granular access control.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Header, HTTPException

router = APIRouter(prefix="/api", tags=["links"])


def _authed_user(x_user_token: str | None) -> dict[str, Any]:
    import users as users_mod

    if not x_user_token:
        raise HTTPException(status_code=401, detail="Missing session token")
    user = users_mod.find_by_token(x_user_token)
    if not user:
        raise HTTPException(status_code=401, detail="Invalid or expired session")
    return user


@router.get("/link/patients")
async def list_patients(x_user_token: str | None = Header(default=None)):
    _authed_user(x_user_token)
    import users as users_mod

    patients = [u for u in users_mod.list_users() if u.get("role") in ("patient", "both")]
    return {
        "links": [
            {
                "link_id": u["id"],
                "user_id": u["id"],
                "display_name": u["display_name"],
                "phone": u.get("phone", ""),
                "linked_at": u.get("created_at", ""),
            }
            for u in patients
        ]
    }


@router.get("/patients/{patient_id}/adherence")
async def patient_adherence(patient_id: str, date: str = "", x_user_token: str | None = Header(default=None)):
    _authed_user(x_user_token)
    import mobile_sync as sync_mod

    snapshot = sync_mod.get_snapshot(patient_id)
    records = [
        {
            "medication_name": r.get("medicationName", ""),
            "dosage": r.get("dosage", ""),
            "window": r.get("window", ""),
            "status": r.get("status", ""),
            "taken_at": r.get("takenAt") or None,
        }
        for r in snapshot["adherence_records"]
    ]
    return {"records": records}


@router.get("/patients/{patient_id}/medications")
async def patient_medications(patient_id: str, x_user_token: str | None = Header(default=None)):
    _authed_user(x_user_token)
    import mobile_sync as sync_mod

    snapshot = sync_mod.get_snapshot(patient_id)
    medications = [
        {
            "id": m.get("id", ""),
            "name": m.get("name", ""),
            "dosage": m.get("dosage", ""),
            "time_windows": m.get("timeWindows", []),
            "is_active": m.get("isActive", True),
        }
        for m in snapshot["medications"]
    ]
    return {"medications": medications}
