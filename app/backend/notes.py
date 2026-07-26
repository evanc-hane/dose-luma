"""CRUD data layer for ALI's persistent markdown notes — the agent's own
long-term memory about the patient across calls (preferences, things they
mentioned, context worth recalling next time), separate from the clinical
adherence record.

Every SQL statement for this capability lives here — routes/agent_tools.py
and the voice agent's manage_notes tool only call these functions.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

import db


def _row_to_note(row: Any) -> dict[str, Any]:
    return {
        "id": row["id"],
        "title": row["title"],
        "content_markdown": row["content_markdown"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def create_note(title: str, content_markdown: str) -> dict[str, Any]:
    title = title.strip() or "Untitled note"
    note_id = uuid.uuid4().hex[:8]
    now = datetime.now(timezone.utc).isoformat()
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT INTO agent_notes (id, title, content_markdown, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (note_id, title, content_markdown, now, now),
        )
        conn.commit()
    finally:
        conn.close()
    return {"id": note_id, "title": title, "content_markdown": content_markdown, "created_at": now, "updated_at": now}


def list_notes() -> list[dict[str, Any]]:
    conn = db.get_connection()
    try:
        rows = conn.execute("SELECT * FROM agent_notes ORDER BY updated_at DESC").fetchall()
    finally:
        conn.close()
    return [_row_to_note(r) for r in rows]


def get_note(note_id: str) -> dict[str, Any] | None:
    conn = db.get_connection()
    try:
        row = conn.execute("SELECT * FROM agent_notes WHERE id = ?", (note_id,)).fetchone()
    finally:
        conn.close()
    return _row_to_note(row) if row else None


def update_note(note_id: str, *, title: str | None = None, content_markdown: str | None = None) -> dict[str, Any]:
    conn = db.get_connection()
    try:
        row = conn.execute("SELECT * FROM agent_notes WHERE id = ?", (note_id,)).fetchone()
        if row is None:
            raise ValueError(f"Unknown note id {note_id!r}")
        new_title = title.strip() if title else row["title"]
        new_content = content_markdown if content_markdown is not None else row["content_markdown"]
        now = datetime.now(timezone.utc).isoformat()
        conn.execute(
            "UPDATE agent_notes SET title = ?, content_markdown = ?, updated_at = ? WHERE id = ?",
            (new_title, new_content, now, note_id),
        )
        conn.commit()
    finally:
        conn.close()
    return {"id": note_id, "title": new_title, "content_markdown": new_content, "updated_at": now}


def delete_note(note_id: str) -> bool:
    conn = db.get_connection()
    try:
        cur = conn.execute("DELETE FROM agent_notes WHERE id = ?", (note_id,))
        conn.commit()
        return cur.rowcount > 0
    finally:
        conn.close()
