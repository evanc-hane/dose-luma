"""Single SQLite database for all backend persistence.

Medication schedules, adherence logs, alerts, and session state share this
schema and connection helper.

Each module keeps its own table(s) and its own small data-access functions
(mirroring the old per-file load/save split) rather than one god-object, but
they all share this one on-disk database file.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent / "doseluma.db"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS reminders_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    enabled INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS medications (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    time TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS adherence_taken (
    date TEXT NOT NULL,
    medication_id TEXT NOT NULL,
    taken_at TEXT NOT NULL,
    PRIMARY KEY (date, medication_id)
);

CREATE TABLE IF NOT EXISTS adherence_dismissed (
    date TEXT NOT NULL,
    medication_id TEXT NOT NULL,
    PRIMARY KEY (date, medication_id)
);

CREATE TABLE IF NOT EXISTS adherence_missed_notified (
    date TEXT NOT NULL,
    medication_id TEXT NOT NULL,
    PRIMARY KEY (date, medication_id)
);

CREATE TABLE IF NOT EXISTS caregiver_alerts (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    medication_id TEXT,
    name TEXT,
    intent TEXT,
    message TEXT,
    priority TEXT,
    created_at TEXT NOT NULL,
    dismissed INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS scheduler_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    medication_id TEXT NOT NULL,
    medication_name TEXT NOT NULL,
    scheduled_time TEXT NOT NULL,
    scheduled_at TEXT NOT NULL,
    fired_at TEXT NOT NULL,
    drift_seconds REAL NOT NULL,
    within_target INTEGER NOT NULL,
    agent_dispatched INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS intent_log (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    date TEXT NOT NULL,
    medication_id TEXT,
    transcript TEXT,
    state TEXT,
    confidence REAL,
    rationale TEXT,
    method TEXT
);

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    display_name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '',
    role TEXT NOT NULL,
    token TEXT NOT NULL,
    created_at TEXT,
    push_token TEXT
);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_users_token ON users(token);

CREATE TABLE IF NOT EXISTS mobile_snapshots (
    user_id TEXT PRIMARY KEY,
    snapshot_json TEXT NOT NULL
);

-- Voice-session state and the caregiver acknowledgement lookup target.
CREATE TABLE IF NOT EXISTS voice_sessions (
    user_identity TEXT PRIMARY KEY,
    room TEXT NOT NULL,
    url TEXT NOT NULL,
    dispatched_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS voice_dispatches (
    room TEXT PRIMARY KEY,
    last_dispatch_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS voice_token_log (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    user_identity TEXT NOT NULL,
    room TEXT NOT NULL,
    issued_at REAL NOT NULL,
    expires_at REAL NOT NULL
);

-- Persistent agent memory: markdown notes ALI writes about the patient
-- (preferences, things they mentioned, context worth remembering next call)
-- so companion conversation can adapt across calls instead of starting fresh.
CREATE TABLE IF NOT EXISTS agent_notes (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    content_markdown TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
"""


def get_connection() -> sqlite3.Connection:
    """A fresh connection against the current DB_PATH.

    Reads DB_PATH at call time (not import time) so tests can
    `mock.patch.object(db, "DB_PATH", tmp_path)` the same way they used to
    patch each module's old `_STORE_PATH`.
    """
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db() -> None:
    """Create every table if it doesn't exist yet. Idempotent."""
    conn = get_connection()
    try:
        conn.executescript(_SCHEMA)
        conn.commit()
    finally:
        conn.close()


init_db()
