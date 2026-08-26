"""main モジュールのヘルパー単体テスト。"""

from __future__ import annotations

import pytest

from src import main
from src.main import _recurrence_label


def test_recurrence_daily() -> None:
    assert _recurrence_label("FREQ=DAILY") == "毎日"


def test_recurrence_weekly() -> None:
    assert _recurrence_label("FREQ=WEEKLY;BYDAY=MO") == "毎週月曜"


def test_recurrence_weekly_multi() -> None:
    assert _recurrence_label("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR") == "毎週月火水木金曜"


def test_recurrence_monthly_byday_num() -> None:
    assert _recurrence_label("FREQ=MONTHLY;BYMONTHDAY=15") == "毎月15日"


def test_recurrence_monthly_last() -> None:
    assert _recurrence_label("FREQ=MONTHLY;BYMONTHDAY=-1") == "毎月末"


def test_recurrence_monthly_nth_weekday() -> None:
    assert _recurrence_label("FREQ=MONTHLY;BYDAY=2TU") == "毎月 2TU"


def test_recurrence_with_count() -> None:
    assert _recurrence_label("FREQ=DAILY;COUNT=10") == "毎日（10回）"


def test_recurrence_with_until() -> None:
    label = _recurrence_label("FREQ=MONTHLY;BYMONTHDAY=1;UNTIL=20261231T000000Z")
    assert label == "毎月1日（20261231まで）"


def test_recurrence_with_rrule_prefix() -> None:
    assert _recurrence_label("RRULE:FREQ=YEARLY") == "毎年"


# --- 送信者チェック（公式アカウントIDを知られても第三者に書かせない）---


def _event(user_id: str | None) -> dict:
    src = {} if user_id is None else {"userId": user_id}
    return {
        "type": "message",
        "message": {"type": "text", "text": "明日10時"},
        "source": src,
    }


def test_owner_is_allowed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(main, "LINE_USER_ID", "U" + "a" * 32)
    assert main._is_authorized(_event("U" + "a" * 32)) is True


def test_stranger_is_blocked(monkeypatch: pytest.MonkeyPatch) -> None:
    """IDを知って友だち追加した第三者は無視する（返信もしない）。"""
    monkeypatch.setattr(main, "LINE_USER_ID", "U" + "a" * 32)
    assert main._is_authorized(_event("U" + "b" * 32)) is False


def test_missing_sender_is_blocked(monkeypatch: pytest.MonkeyPatch) -> None:
    """source.userId が無いイベント（グループ等）も、設定済みなら通さない。"""
    monkeypatch.setattr(main, "LINE_USER_ID", "U" + "a" * 32)
    assert main._is_authorized(_event(None)) is False


def test_unset_user_id_allows_anyone(monkeypatch: pytest.MonkeyPatch) -> None:
    """未設定のうちは通す。初回セットアップの1通目を処理してログに userId を出すため。"""
    monkeypatch.setattr(main, "LINE_USER_ID", "")
    assert main._is_authorized(_event("U" + "c" * 32)) is True
