"""Name-based user accounts — no passwords.

Matches the DoseLuma app's "Walled Garden" philosophy: security lives at the
network boundary, not inside it. Registering with a name that already
exists (case-insensitive) signs back into that same account instead of
creating a duplicate.
"""

from __future__ import annotations

import secrets
import uuid
from datetime import datetime, timezone
from typing import Any

import db


def _row_to_user(row: Any) -> dict[str, Any]:
    return {
        "id": row["id"],
        "username": row["username"],
        "display_name": row["display_name"],
        "phone": row["phone"],
        "role": row["role"],
        "token": row["token"],
        "created_at": row["created_at"],
        "push_token": row["push_token"],
    }


def register_or_login(*, username: str, display_name: str, phone: str, role: str) -> dict[str, Any]:
    """Find-or-create a user by name and issue a fresh session token."""
    username = username.strip()
    if not username:
        raise ValueError("Name is required")

    token = secrets.token_hex(32)
    conn = db.get_connection()
    try:
        existing = conn.execute(
            "SELECT * FROM users WHERE username = ? COLLATE NOCASE", (username,)
        ).fetchone()

        if existing is not None:
            new_display_name = display_name.strip() or existing["display_name"]
            new_phone = phone.strip() or existing["phone"] or ""
            new_role = role or existing["role"] or "patient"
            conn.execute(
                "UPDATE users SET display_name = ?, phone = ?, role = ?, token = ? WHERE id = ?",
                (new_display_name, new_phone, new_role, token, existing["id"]),
            )
            conn.commit()
            return {
                "id": existing["id"],
                "username": existing["username"],
                "display_name": new_display_name,
                "phone": new_phone,
                "role": new_role,
                "token": token,
                "created_at": existing["created_at"],
                "push_token": existing["push_token"],
            }

        user = {
            "id": uuid.uuid4().hex,
            "username": username,
            "display_name": display_name.strip() or username,
            "phone": phone.strip(),
            "role": role or "patient",
            "token": token,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "push_token": None,
        }
        conn.execute(
            "INSERT INTO users (id, username, display_name, phone, role, token, created_at, push_token) "
            "VALUES (:id, :username, :display_name, :phone, :role, :token, :created_at, :push_token)",
            user,
        )
        conn.commit()
        return user
    finally:
        conn.close()


def find_by_token(token: str) -> dict[str, Any] | None:
    if not token:
        return None
    conn = db.get_connection()
    try:
        row = conn.execute("SELECT * FROM users WHERE token = ?", (token,)).fetchone()
        return _row_to_user(row) if row else None
    finally:
        conn.close()


def find_by_id(user_id: str) -> dict[str, Any] | None:
    conn = db.get_connection()
    try:
        row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
        return _row_to_user(row) if row else None
    finally:
        conn.close()


def list_users(role: str | None = None) -> list[dict[str, Any]]:
    conn = db.get_connection()
    try:
        if role:
            rows = conn.execute("SELECT * FROM users WHERE role = ?", (role,)).fetchall()
        else:
            rows = conn.execute("SELECT * FROM users").fetchall()
        return [_row_to_user(r) for r in rows]
    finally:
        conn.close()


def update_phone(user_id: str, phone: str) -> None:
    conn = db.get_connection()
    try:
        conn.execute("UPDATE users SET phone = ? WHERE id = ?", (phone.strip(), user_id))
        conn.commit()
    finally:
        conn.close()


def update_push_token(user_id: str, push_token: str) -> None:
    conn = db.get_connection()
    try:
        conn.execute("UPDATE users SET push_token = ? WHERE id = ?", (push_token, user_id))
        conn.commit()
    finally:
        conn.close()
