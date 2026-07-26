"""In-process pub/sub for pushing backend state changes to connected clients.

Frontends (iOS, web) open a WebSocket at /ws/state instead of polling
/api/adherence + /api/alerts. Route handlers that mutate adherence/alert/
session state call `state_bus.broadcast(...)` after the mutation so every
connected client gets the update immediately.
"""

from __future__ import annotations

import logging

from fastapi import WebSocket

logger = logging.getLogger(__name__)


class StateBus:
    def __init__(self) -> None:
        self._connections: set[WebSocket] = set()

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        self._connections.add(websocket)
        logger.info(f"[StateBus] client connected ({len(self._connections)} total)")

    def disconnect(self, websocket: WebSocket) -> None:
        self._connections.discard(websocket)
        logger.info(f"[StateBus] client disconnected ({len(self._connections)} total)")

    async def broadcast(self, message: dict) -> None:
        """Send `message` as JSON to every connected client, dropping dead ones."""
        dead: list[WebSocket] = []
        for connection in self._connections:
            try:
                await connection.send_json(message)
            except Exception:
                dead.append(connection)
        for connection in dead:
            self.disconnect(connection)


# Singleton — imported by index.py route handlers and the /ws/state endpoint.
state_bus = StateBus()
