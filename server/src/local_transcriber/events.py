from __future__ import annotations

import asyncio
from collections import defaultdict

from fastapi import WebSocket


class EventBroker:
    def __init__(self) -> None:
        self._subscribers: dict[str, set[WebSocket]] = defaultdict(set)
        self._lock = asyncio.Lock()

    async def subscribe(self, session_id: str, websocket: WebSocket) -> None:
        async with self._lock:
            self._subscribers[session_id].add(websocket)

    async def unsubscribe(self, session_id: str, websocket: WebSocket) -> None:
        async with self._lock:
            self._subscribers[session_id].discard(websocket)

    async def publish(self, session_id: str, message: dict) -> None:
        async with self._lock:
            targets = list(self._subscribers[session_id])
        dead: list[WebSocket] = []
        for websocket in targets:
            try:
                await websocket.send_json(message)
            except RuntimeError:
                dead.append(websocket)
        if dead:
            async with self._lock:
                for websocket in dead:
                    self._subscribers[session_id].discard(websocket)


event_broker = EventBroker()
