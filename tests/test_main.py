"""main モジュールのヘルパー単体テスト。"""

from __future__ import annotations

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
