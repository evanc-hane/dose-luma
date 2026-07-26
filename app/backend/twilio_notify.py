"""Twilio SMS + automated voice call integration.

Tier 1 sends an automated SMS. Tier 2 places an automated TTS phone call
when a caregiver alert goes unacknowledged for 5 minutes, Tier 3 calls a
secondary contact after 10 minutes.

Configured entirely via environment variables. Every function is a safe
no-op (delivered=False, configured=False) when credentials aren't set —
As with CAREGIVER_WEBHOOK_URL in caregiver_notify.py, the system
still runs end-to-end in dev without a paid Twilio account.
"""

from __future__ import annotations

import base64
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

logger = logging.getLogger(__name__)

_API_BASE = "https://api.twilio.com/2010-04-01/Accounts"


def _credentials() -> tuple[str, str, str] | None:
    sid = os.getenv("TWILIO_ACCOUNT_SID", "").strip()
    token = os.getenv("TWILIO_AUTH_TOKEN", "").strip()
    from_number = os.getenv("TWILIO_FROM_NUMBER", "").strip()
    if not (sid and token and from_number):
        return None
    return sid, token, from_number


def _post(sid: str, token: str, path: str, data: dict[str, str]) -> dict[str, Any]:
    url = f"{_API_BASE}/{sid}/{path}"
    body = urllib.parse.urlencode(data).encode("utf-8")
    auth = base64.b64encode(f"{sid}:{token}".encode()).decode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=8.0) as resp:
            resp.read()
        return {"delivered": True, "error": None}
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
        logger.warning("Twilio request to %s failed: %s", path, exc)
        return {"delivered": False, "error": str(exc)}


def send_sms(to_number: str, message: str) -> dict[str, Any]:
    creds = _credentials()
    if not creds or not to_number:
        return {"delivered": False, "error": None, "configured": bool(creds)}
    sid, token, from_number = creds
    result = _post(sid, token, "Messages.json", {"To": to_number, "From": from_number, "Body": message})
    result["configured"] = True
    return result


def place_call(to_number: str, say_text: str) -> dict[str, Any]:
    """Places an automated call that reads `say_text` aloud via inline TwiML."""
    creds = _credentials()
    if not creds or not to_number:
        return {"delivered": False, "error": None, "configured": bool(creds)}
    sid, token, from_number = creds
    twiml = f"<Response><Say>{say_text}</Say></Response>"
    result = _post(sid, token, "Calls.json", {"To": to_number, "From": from_number, "Twiml": twiml})
    result["configured"] = True
    return result
