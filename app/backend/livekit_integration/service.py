"""
LiveKit Agent Integration Service
Handles WebRTC connections and real-time voice chat with Ollama agent
"""

import os
import json
import logging
from dotenv import load_dotenv
from typing import Optional
import jwt
import time

import config
from livekit_integration import voice_sessions

load_dotenv()

logger = logging.getLogger(__name__)

class LiveKitService:
    """Service for managing LiveKit agent connections and token generation"""

    # How long a dispatched agent is assumed to still be sitting in the room.
    # Prevents a second dispatch when the proactive scheduler
    # already put an agent in the room and the patient's device then calls
    # /api/livekit/connect a few seconds/minutes later to join it.
    _DISPATCH_COOLDOWN_SECONDS = 180

    def __init__(self):
        # Two URLs: one advertised to clients (must be reachable from device),
        # one used internally for server-to-server API calls (Docker network).
        self.livekit_url = os.getenv("LIVEKIT_URL")
        self.internal_url = os.getenv("LIVEKIT_INTERNAL_URL", self.livekit_url)
        # Convert ws:// to http:// for the API endpoint (used by dispatch_agent)
        self.api_url = (self.internal_url or "").replace("ws://", "http://").replace("wss://", "https://")
        self.api_key = os.getenv("LIVEKIT_API_KEY")
        self.api_secret = os.getenv("LIVEKIT_API_SECRET")
        self.agent_name = config.agent_name()

        if not all([self.livekit_url, self.api_key, self.api_secret]):
            logger.warning("LiveKit credentials not fully configured")
        else:
            logger.info(f"LiveKit service initialized: advertised={self.livekit_url} internal={self.api_url}")

    def generate_access_token(self, room_name: str, user_name: str, identity: str) -> Optional[str]:
        """
        Generate a LiveKit access token for joining a room

        Args:
            room_name: The room to join
            user_name: Display name for the user
            identity: Unique identifier for the user

        Returns:
            JWT token string or None if configuration is incomplete
        """
        try:
            # Create JWT token with LiveKit grants
            now = int(time.time())
            expiration = now + 3600  # 1 hour token lifetime

            # LiveKit requires camelCase grant field names
            grants = {
                "canPublish": True,
                "canPublishData": True,
                "canSubscribe": True,
                "room": room_name,
                "roomJoin": True,
            }

            payload = {
                "iss": self.api_key,
                "sub": identity,
                "name": user_name,
                "iat": now,
                "exp": expiration,
                "nbf": now,
                "video": grants,
            }

            token_str = jwt.encode(payload, self.api_secret, algorithm="HS256")
            voice_sessions.log_token_mint(identity, room_name, issued_at=now, expires_at=expiration)

            logger.info(f"Generated token for user {identity} in room {room_name}")
            return token_str

        except Exception as e:
            logger.error(f"Error generating token: {e}")
            return None

    def get_connection_details(self, room_name: str, user_identity: str, user_name: str = "User") -> Optional[dict]:
        """
        Get the complete connection details for a LiveKit room

        Args:
            room_name: The room to join
            user_identity: Unique identifier for the user
            user_name: Display name for the user

        Returns:
            Dictionary with connection details or None if configuration is incomplete
        """
        token = self.generate_access_token(room_name, user_name, user_identity)

        if token:
            return {
                "url": self.livekit_url,
                "token": token,
                "room": room_name,
                "user": user_identity,
                "agent_name": self.agent_name,
            }
        return None

    async def dispatch_agent(self, room_name: str, *, greeting_context: str = "reminder_call") -> bool:
        """Dispatch the named agent to the room via LiveKit server API.

        No-ops (returns True) if an agent was already dispatched to this room
        within the cooldown window — see _DISPATCH_COOLDOWN_SECONDS. This is
        tracked in voice_sessions.py (disk-persisted), not an in-memory dict,
        so a backend restart doesn't forget a dispatch and double-join the
        agent into a room that's already occupied.

        `greeting_context` is passed via the LiveKit job's `metadata` field,
        not an env var — the agent worker is a separate OS process from this
        backend, so os.environ writes here never reach it. The agent reads
        ctx.job.metadata to pick which greeting template to speak.
        """
        last = voice_sessions.get_last_dispatch(room_name)
        if last is not None and (time.time() - last) < self._DISPATCH_COOLDOWN_SECONDS:
            logger.info(f"Skipping dispatch to room {room_name} — agent already dispatched {time.time() - last:.0f}s ago")
            return True
        try:
            from livekit import api as lk_api
            # Use internal URL for server-to-server API call
            lk = lk_api.LiveKitAPI(self.api_url, self.api_key, self.api_secret)
            await lk.agent_dispatch.create_dispatch(
                lk_api.CreateAgentDispatchRequest(
                    agent_name=self.agent_name,
                    room=room_name,
                    metadata=json.dumps({"greeting_context": greeting_context}),
                )
            )
            await lk.aclose()
            voice_sessions.record_dispatch(room_name)
            logger.info(f"Dispatched agent {self.agent_name} to room {room_name}")
            return True
        except Exception as e:
            logger.warning(f"Agent dispatch failed (agent may not be running): {e}")
            return False


# Singleton instance
livekit_service = LiveKitService()
