"""LiveKit token issuance + agent dispatch.

This is how a frontend (iOS phone, mac, web) gets on a call:

  1. POST /api/livekit/connect — resolve the room, mint a participant JWT,
     dispatch the named agent worker into that room (once per device
     session), return {url, token, room, agent_name, agent_dispatched}.
  2. The client connects to LiveKit directly with url+token; the agent
     joins the same room server-side (see app/agent/voice_agent.py).
  3. POST /api/livekit/disconnect — clear the cached device session.
  4. POST /api/livekit/token — cheap token refresh without re-dispatching.

One agent per device: if the same user_identity reconnects to the same
room within _SESSION_TTL_SECONDS, /connect reuses the session instead of
dispatching a second agent. Session state lives in voice_sessions.py
(disk-persisted) — the backend is the source of truth for which rooms
it has issued, not the client, and not memory that a restart wipes.
"""

from __future__ import annotations

import logging
import time

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

import config
from livekit_integration import voice_sessions
from livekit_integration.advertise import advertise_livekit_url
from livekit_integration.service import livekit_service
from livekit_integration.session import resolve_room_name
from state_bus import state_bus

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/livekit", tags=["livekit"])


class LiveKitConnectRequest(BaseModel):
    """Request body for LiveKit connection (web + mobile share this)."""

    # Optional: defaults to config.json → agent.room when omitted/blank.
    room_name: str = ""
    user_identity: str
    user_name: str = "User"


class LiveKitConnectResponse(BaseModel):
    """Response with LiveKit connection details."""

    url: str
    token: str
    room: str
    user: str
    agent_name: str
    agent_dispatched: bool = False


_SESSION_TTL_SECONDS = 300  # 5 minutes


@router.post("/connect", response_model=LiveKitConnectResponse)
async def connect(request: LiveKitConnectRequest, http_request: Request):
    """Start a voice session (same path for web and mobile)."""
    room_name = resolve_room_name(request.room_name, config.default_room())
    logger.info(f"[Connect] Request from device: {request.user_identity} for room: {room_name}")

    now = time.time()
    existing = voice_sessions.get_session(request.user_identity)
    reuse_existing = (
        existing is not None
        and existing["room"] == room_name
        and (now - existing["dispatched_at"]) < _SESSION_TTL_SECONDS
    )

    if reuse_existing:
        logger.info(f"[Connect] Reusing session for {request.user_identity} — no new agent dispatch")
    else:
        logger.info(f"[Connect] New session for {request.user_identity}")

    logger.info(f"[Connect] Generating JWT for identity={request.user_identity}")
    connection_details = livekit_service.get_connection_details(
        room_name=room_name,
        user_identity=request.user_identity,
        user_name=request.user_name,
    )

    if not connection_details:
        logger.error(f"[Connect] Failed to generate token for {request.user_identity}")
        raise HTTPException(status_code=500, detail="Failed to generate LiveKit connection token")

    # Physical devices call the API via LAN IP — advertise LiveKit on that host.
    advertised = advertise_livekit_url(
        connection_details["url"],
        http_request.headers.get("host"),
    )
    connection_details["url"] = advertised
    logger.info(f"[Connect] Token generated, advertising URL: {advertised}")

    agent_dispatched = False
    if not reuse_existing:
        logger.info(f"[Connect] Dispatching agent to room {room_name}")
        # The patient pressed "Talk to ALI" themselves — a warm, welcoming
        # greeting ("how can I help you today?"), not the scheduled
        # reminder-call script ("checking in about your medication").
        agent_dispatched = await livekit_service.dispatch_agent(
            room_name, greeting_context="user_initiated"
        )
        if agent_dispatched:
            logger.info("[Connect] Agent dispatched successfully")
        else:
            logger.warning("[Connect] Agent dispatch failed or agent not running")

        voice_sessions.record_session(request.user_identity, room_name, connection_details["url"])

        await state_bus.broadcast({
            "type": "session_update",
            "user_identity": request.user_identity,
            "room": room_name,
            "connected": True,
        })

    return LiveKitConnectResponse(
        **connection_details,
        agent_dispatched=agent_dispatched or reuse_existing,
    )


@router.post("/disconnect")
async def disconnect(request: LiveKitConnectRequest):
    """Explicit disconnect: clears the device's cached session."""
    if voice_sessions.get_session(request.user_identity) is not None:
        voice_sessions.clear_session(request.user_identity)
        logger.info(f"[Disconnect] Cleared session for {request.user_identity}")
        await state_bus.broadcast({
            "type": "session_update",
            "user_identity": request.user_identity,
            "connected": False,
        })
    return {"status": "disconnected", "user_identity": request.user_identity}


@router.post("/token")
async def token(request: LiveKitConnectRequest):
    """Get only the LiveKit access token (for quick token refresh)."""
    access_token = livekit_service.generate_access_token(
        room_name=request.room_name,
        user_name=request.user_name,
        identity=request.user_identity,
    )

    if not access_token:
        raise HTTPException(status_code=500, detail="Failed to generate LiveKit token")

    return {
        "token": access_token,
        "url": livekit_service.livekit_url,
        "room": request.room_name,
    }
