"""db モジュールの単体テスト。"""
from __future__ import annotations

import importlib
from pathlib import Path

import pytest


@pytest.fixture
def db_mod(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    from src import config, db

    monkeypatch.setattr(config, "DB_PATH", tmp_path / "test.db")
    importlib.reload(db)
    db.init_db()
    return db


def test_upsert_and_delete(db_mod) -> None:
    db_mod.upsert_event("gid1", "タイトル", "2026-04-20T15:00:00", None, None)
    db_mod.upsert_event("gid1", "更新後", "2026-04-20T16:00:00", None, "備考")
    with db_mod.connect() as conn:
        row = conn.execute(
            "SELECT title, start_at, description FROM events WHERE google_event_id=?",
            ("gid1",),
        ).fetchone()
    assert row["title"] == "更新後"
    assert row["start_at"] == "2026-04-20T16:00:00"
    assert row["description"] == "備考"

    db_mod.delete_event("gid1")
    with db_mod.connect() as conn:
        assert (
            conn.execute(
                "SELECT 1 FROM events WHERE google_event_id=?", ("gid1",)
            ).fetchone()
            is None
        )


def test_latest_event(db_mod) -> None:
    assert db_mod.latest_event() is None
    db_mod.upsert_event("gid1", "古い予定", "2026-04-20T15:00:00", None, None)
    db_mod.upsert_event("gid2", "新しい予定", "2026-04-21T10:00:00", None, None)
    latest = db_mod.latest_event()
    assert latest is not None
    assert latest["google_event_id"] == "gid2"
    assert latest["title"] == "新しい予定"


def test_notification_log(db_mod) -> None:
    assert db_mod.already_notified("daily", "2026-04-20") is False
    db_mod.mark_notified("daily", "2026-04-20")
    assert db_mod.already_notified("daily", "2026-04-20") is True
    db_mod.mark_notified("daily", "2026-04-20")  # 冪等
    assert db_mod.already_notified("daily", "2026-04-20") is True
