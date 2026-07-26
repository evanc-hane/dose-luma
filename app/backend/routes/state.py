"""Real-time state push (WebSocket) — alternative to polling
/api/adherence + /api/alerts.

Connect once, get a snapshot, then get pushed a fresh one every time
adherence/alert state changes on the backend (dose marked taken, intent
classified, alert dismissed — from *any* connected client). iOS phone and
mac both use this instead of polling.
"""

from __future__ import annotations

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from state_bus import state_bus

router = APIRouter(tags=["state"])


async def broadcast_adherence_state() -> None:
    """Push the current adherence + alerts snapshot to every connected client.

    Called by routes/adherence.py after every mutation.
    """
    import adherence

    await state_bus.broadcast({
        "type": "adherence_update",
        "medications": adherence.today_status(),
        "alerts": adherence.list_alerts(),
    })


@router.websocket("/ws/state")
async def ws_state(websocket: WebSocket):
    import adherence

    await state_bus.connect(websocket)
    try:
        await websocket.send_json({
            "type": "snapshot",
            "medications": adherence.today_status(),
            "alerts": adherence.list_alerts(),
        })
        while True:
            # Clients don't need to send anything; this just detects disconnects.
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        state_bus.disconnect(websocket)
