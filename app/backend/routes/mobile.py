"""Mobile app background sync + pill-scan logging.

See mobile_sync.py for why /mobile/sync always echoes back what it's given
instead of doing real server-side merge — the client treats the response as
authoritative and would otherwise risk wiping local data.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/api", tags=["mobile"])


def _authed_user(x_user_token: str | None) -> dict[str, Any]:
    import users as users_mod

    if not x_user_token:
        raise HTTPException(status_code=401, detail="Missing session token")
    user = users_mod.find_by_token(x_user_token)
    if not user:
        raise HTTPException(status_code=401, detail="Invalid or expired session")
    return user


class MobileSyncRequest(BaseModel):
    device_id: str
    current_screen: str = ""
    snapshot: dict[str, Any]


@router.post("/mobile/sync")
async def mobile_sync(body: MobileSyncRequest, x_user_token: str | None = Header(default=None)):
    import mobile_sync as sync_mod
    import scheduler

    user = _authed_user(x_user_token)
    echoed = sync_mod.save_snapshot(user["id"], body.snapshot)
    # Any active app medications with a time window were just upserted into
    # reminders.medications (see mobile_sync.save_snapshot) — make sure the
    # live scheduler actually knows about them.
    scheduler.rebuild_if_running()

    return {
        "server_time": datetime.now(timezone.utc).isoformat(),
        "patient": {
            "id": user["id"],
            "display_name": user["display_name"],
            "phone": user.get("phone", ""),
            "role": user.get("role", "patient"),
        },
        "time_windows": echoed["time_windows"],
        "medications": echoed["medications"],
        "adherence_records": echoed["adherence_records"],
        "vitals": echoed["vitals"],
    }


class ScanLogRequest(BaseModel):
    device_id: str
    medication_id: str | None = None
    scan_type: str
    pill_analysis: dict[str, Any] | None = None
    matches: list[dict[str, Any]] = []
    scanned_at: str


@router.post("/scans")
async def log_scan(body: ScanLogRequest):
    """Fire-and-forget scan analytics — accepted, not persisted."""
    return {"accepted": 1, "synced": 1, "conflicts": []}
