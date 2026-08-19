"""SQLite による予定・通知状態の永続化。"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime

from src.config import DB_PATH

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    google_event_id TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    start_at TEXT NOT NULL,
    end_at TEXT,
    description TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS notification_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    date TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(kind, date)
);
"""


@contextmanager
def connect() -> Iterator[sqlite3.Connection]:
    """DB 接続コンテキスト。"""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db() -> None:
    """スキーマ初期化（未作成時のみテーブル作成）。"""
    with connect() as conn:
        conn.executescript(SCHEMA)


def upsert_event(
    google_event_id: str,
    title: str,
    start_at: str,
    end_at: str | None,
    description: str | None,
) -> None:
    """予定レコードを UPSERT する。"""
    now = datetime.now().isoformat()
    with connect() as conn:
        conn.execute(
            """
            INSERT INTO events
                (google_event_id, title, start_at, end_at, description, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(google_event_id) DO UPDATE SET
                title=excluded.title,
                start_at=excluded.start_at,
                end_at=excluded.end_at,
                description=excluded.description,
                updated_at=excluded.updated_at
            """,
            (google_event_id, title, start_at, end_at, description, now, now),
        )


def delete_event(google_event_id: str) -> None:
    """予定レコードを削除する。"""
    with connect() as conn:
        conn.execute("DELETE FROM events WHERE google_event_id = ?", (google_event_id,))


def latest_event() -> sqlite3.Row | None:
    """直近で作成/更新した予定を1件返す（「先ほどの予定」参照用）。"""
    with connect() as conn:
        row: sqlite3.Row | None = conn.execute(
            "SELECT * FROM events ORDER BY updated_at DESC, id DESC LIMIT 1"
        ).fetchone()
        return row


def already_notified(kind: str, date: str) -> bool:
    """当日（週次/日次）通知済みかを返す。"""
    with connect() as conn:
        row = conn.execute(
            "SELECT 1 FROM notification_log WHERE kind = ? AND date = ?",
            (kind, date),
        ).fetchone()
        return row is not None


def mark_notified(kind: str, date: str) -> None:
    """通知送信済みを記録する。"""
    now = datetime.now().isoformat()
    with connect() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO notification_log (kind, date, created_at) VALUES (?, ?, ?)",
            (kind, date, now),
        )
