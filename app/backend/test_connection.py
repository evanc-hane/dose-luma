"""
Mock LiveKit connection test (CLI).

Verifies the shared credentials work end-to-end against the local LiveKit
server: reachable server + valid API key/secret + whether the agent has joined
the room. Uses the same .env the backend and agent read, so it exercises the
exact creds everything else uses.

Run (from the app/backend/ dir, in the project venv):
    uv run python test_connection.py
    # or: python test_connection.py
"""

import asyncio
import os

from dotenv import load_dotenv
from livekit import api

load_dotenv()

ROOM = os.getenv("LIVEKIT_ROOM", "doseluma-room")


def to_http(ws_url: str) -> str:
    """The server API (twirp/HTTP) lives on the same host:port as the ws URL."""
    return ws_url.replace("wss://", "https://").replace("ws://", "http://")


async def main() -> None:
    ws_url = os.getenv("LIVEKIT_URL", "ws://localhost:7880")
    url = to_http(ws_url)
    key = os.getenv("LIVEKIT_API_KEY", "devkey")
    secret = os.getenv("LIVEKIT_API_SECRET", "secret")

    print(f"LiveKit URL : {ws_url}  (API: {url})")
    print(f"API key     : {key}")
    print(f"Room        : {ROOM}\n")

    lk = api.LiveKitAPI(url, key, secret)
    try:
        rooms = await lk.room.list_rooms(api.ListRoomsRequest())
        print("✓ Server reachable and credentials valid.")
        print(f"  Active rooms: {[r.name for r in rooms.rooms] or '(none)'}")

        try:
            res = await lk.room.list_participants(
                api.ListParticipantsRequest(room=ROOM)
            )
            names = [p.identity for p in res.participants]
            print(f"  Participants in '{ROOM}': {names or '(none)'}")
            agent = [n for n in names if "agent" in n.lower() or n.startswith("AI")]
            if agent:
                print(f"✓ Agent is in the room: {agent}")
            else:
                print("… No agent in the room yet — start it: "
                      "uv run python voice_agent.py dev")
        except Exception as e:  # room may not exist until someone joins
            print(f"  (Room '{ROOM}' not active yet: {e})")

        print("\nRESULT: connection OK ✅")
    except Exception as e:
        print(f"✗ FAILED to reach server / validate creds: {e}")
        print("  Is the LiveKit server running? (docker compose up -d livekit)")
        print("  Do LIVEKIT_API_KEY/SECRET match livekit.yaml (devkey/secret)?")
        print("\nRESULT: connection FAILED ❌")
    finally:
        await lk.aclose()


if __name__ == "__main__":
    asyncio.run(main())
