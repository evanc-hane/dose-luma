"""Persistent registry of LiveKit rooms/sessions the backend has issued.

The backend — not the client, and not an in-memory dict that resets on
every restart — is the source of truth for which room a device is in and
whether an agent has already been dispatched to a room. Every issued
session and dispatch is written to SQLite (see db.py) immediately so a
backend restart doesn't lose track of active sessions or cause a
duplicate agent dispatch into a room that already has one.
"""

from __future__ import annotations

import time
from typing import Any

import db

# Every minted token is appended here (identity, room, issued_at, expires_at)
# so the backend can answer "what rooms/tokens have we ever issued, and are
# they still live" without relying on the client's memory of its own calls.
# Capped so the log doesn't grow without bound.
_TOKEN_LOG_LIMIT = 1000


def get_session(user_identity: str) -> dict[str, Any] | None:
    """The room the backend most recently issued to this identity, if any."""
    conn = db.get_connection()
    try:
        row = conn.execute(
            "SELECT room, url, dispatched_at FROM voice_sessions WHERE user_identity = ?",
            (user_identity,),
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def record_session(user_identity: str, room: str, url: str) -> None:
    """Remember that this identity was issued a token for this room."""
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT INTO voice_sessions (user_identity, room, url, dispatched_at) "
            "VALUES (?, ?, ?, ?) "
            "ON CONFLICT(user_identity) DO UPDATE SET "
            "room = excluded.room, url = excluded.url, dispatched_at = excluded.dispatched_at",
            (user_identity, room, url, time.time()),
        )
        conn.commit()
    finally:
        conn.close()


def clear_session(user_identity: str) -> None:
    conn = db.get_connection()
    try:
        conn.execute("DELETE FROM voice_sessions WHERE user_identity = ?", (user_identity,))
        conn.commit()
    finally:
        conn.close()


def all_sessions() -> dict[str, Any]:
    """Every room currently issued, keyed by user_identity."""
    conn = db.get_connection()
    try:
        return {
            row["user_identity"]: {
                "room": row["room"], "url": row["url"], "dispatched_at": row["dispatched_at"],
            }
            for row in conn.execute(
                "SELECT user_identity, room, url, dispatched_at FROM voice_sessions"
            )
        }
    finally:
        conn.close()


def get_last_dispatch(room: str) -> float | None:
    """Epoch seconds of the last agent dispatch into this room, if any."""
    conn = db.get_connection()
    try:
        row = conn.execute(
            "SELECT last_dispatch_at FROM voice_dispatches WHERE room = ?", (room,)
        ).fetchone()
        return row["last_dispatch_at"] if row else None
    finally:
        conn.close()


def record_dispatch(room: str) -> None:
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT INTO voice_dispatches (room, last_dispatch_at) VALUES (?, ?) "
            "ON CONFLICT(room) DO UPDATE SET last_dispatch_at = excluded.last_dispatch_at",
            (room, time.time()),
        )
        conn.commit()
    finally:
        conn.close()


def log_token_mint(user_identity: str, room: str, issued_at: float, expires_at: float) -> None:
    """Record every token the backend mints, and when it expires.

    Append-only audit trail of everything the backend has ever handed out —
    independent of the reusable-session table above, which only tracks the
    *current* session per identity.
    """
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT INTO voice_token_log (user_identity, room, issued_at, expires_at) "
            "VALUES (?, ?, ?, ?)",
            (user_identity, room, issued_at, expires_at),
        )
        # Cap: keep only the most recently inserted _TOKEN_LOG_LIMIT rows.
        conn.execute(
            "DELETE FROM voice_token_log WHERE seq IN ("
            "  SELECT seq FROM voice_token_log ORDER BY seq DESC LIMIT -1 OFFSET ?"
            ")",
            (_TOKEN_LOG_LIMIT,),
        )
        conn.commit()
    finally:
        conn.close()


def token_log() -> list[dict[str, Any]]:
    """Every minted token this backend has logged, oldest first."""
    conn = db.get_connection()
    try:
        rows = conn.execute(
            "SELECT user_identity, room, issued_at, expires_at FROM voice_token_log ORDER BY seq"
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def active_tokens() -> list[dict[str, Any]]:
    """Minted tokens whose expiry hasn't passed yet."""
    now = time.time()
    return [entry for entry in token_log() if entry.get("expires_at", 0) > now]
