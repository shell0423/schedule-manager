"""notifier モジュールの単体テスト。"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import httplib2
import pytest

from src import notifier
from src.notifier import format_events, format_range_label, period_range

JST = ZoneInfo("Asia/Tokyo")


def test_period_range_today() -> None:
    start, end, label = period_range("today")
    assert label == "本日"
    assert (end - start).days == 1


def test_period_range_this_week_starts_on_monday() -> None:
    start, _, label = period_range("this_week")
    assert label == "今週"
    assert start.weekday() == 0


def test_period_range_next_week() -> None:
    start, end, label = period_range("next_week")
    assert label == "来週"
    assert start.weekday() == 0
    assert (end - start).days == 7


def test_period_range_this_month_covers_whole_month() -> None:
    start, end, label = period_range("this_month")
    assert label == "今月"
    assert start.day == 1
    assert end.day == 1
    assert 28 <= (end - start).days <= 31


def test_period_range_next_month() -> None:
    start, end, label = period_range("next_month")
    assert label == "来月"
    assert start.day == 1
    assert 28 <= (end - start).days <= 31


def test_period_range_specific_month() -> None:
    start, end, label = period_range("month", None, "2026-08")
    assert (start.year, start.month, start.day) == (2026, 8, 1)
    assert (end.year, end.month, end.day) == (2026, 9, 1)
    assert label in ("8月", "2026年8月")


def test_period_range_specific_month_december_rolls_over() -> None:
    start, end, _ = period_range("month", None, "2026-12")
    assert (end.year, end.month) == (2027, 1)
    assert (end - start).days == 31


def test_period_range_month_other_year_label() -> None:
    _, _, label = period_range("month", None, "2099-03")
    assert label == "2099年3月"


def test_period_range_month_without_value_falls_back() -> None:
    _, _, label = period_range("month", None, None)
    assert label == "本日"


def test_format_events_empty() -> None:
    assert format_events([], "本日") == "📅 本日の予定はありません"


def test_format_events_with_items() -> None:
    events = [
        {
            "start": {"dateTime": "2026-04-20T15:00:00+09:00"},
            "summary": "田中さんと打ち合わせ",
        },
    ]
    text = format_events(events, "本日")
    assert "📅 本日の予定" in text
    assert "田中さんと打ち合わせ" in text
    assert "15:00" in text


def test_format_events_all_day() -> None:
    events = [{"start": {"date": "2026-04-20"}, "summary": "終日イベント"}]
    text = format_events(events, "本日")
    assert "終日" in text
    assert "終日イベント" in text


def test_format_events_all_day_multi_day_shows_range() -> None:
    """終日の期間予定は「12/4(金)〜12/5(土) 終日」と両端を出す（end は exclusive）。"""
    events = [
        {
            "start": {"date": "2026-12-04"},
            "end": {"date": "2026-12-06"},
            "summary": "名証IR EXPO 2026",
        }
    ]
    text = format_events(events, "12月")
    assert "・12/4(金)〜12/5(土) 終日 名証IR EXPO 2026" in text


def test_format_events_all_day_single_day_has_no_range() -> None:
    events = [
        {
            "start": {"date": "2026-08-11"},
            "end": {"date": "2026-08-12"},
            "summary": "夏季休暇（棚卸し）",
        }
    ]
    text = format_events(events, "8月")
    assert "・8/11(火) 終日 夏季休暇（棚卸し）" in text
    assert "〜" not in text


def test_format_events_timed_multi_day_shows_both_ends() -> None:
    events = [
        {
            "start": {"dateTime": "2026-12-04T13:30:00+09:00"},
            "end": {"dateTime": "2026-12-05T10:00:00+09:00"},
            "summary": "合宿",
        }
    ]
    text = format_events(events, "12月")
    assert "・12/4(金) 13:30〜12/5(土) 10:00 合宿" in text


def test_format_events_timed_same_day_unchanged() -> None:
    events = [
        {
            "start": {"dateTime": "2026-04-20T15:00:00+09:00"},
            "end": {"dateTime": "2026-04-20T16:00:00+09:00"},
            "summary": "打ち合わせ",
        }
    ]
    assert format_events(events, "本日") == "📅 本日の予定\n・4/20(月) 15:00 打ち合わせ"


def test_format_range_label_variants() -> None:
    assert (
        format_range_label("2026-12-04", "2026-12-05", True)
        == "12/4(金)〜12/5(土) 終日"
    )
    assert format_range_label("2026-12-04", "2026-12-04", True) == "12/4(金) 終日"
    assert format_range_label("2026-12-04", None, True) == "12/4(金) 終日"
    assert format_range_label("2026-12-04T13:30:00", None, False) == "12/4(金) 13:30"


# --- ネットワーク断の切り分け（週次の失敗が日次を巻き添えにしないこと） ---


def _no_wait(monkeypatch: pytest.MonkeyPatch) -> None:
    """リトライ待ちを潰してテストを即座に回す。"""
    monkeypatch.setattr(notifier.time, "sleep", lambda _sec: None)


def test_run_with_retry_gives_up_after_limit(monkeypatch: pytest.MonkeyPatch) -> None:
    _no_wait(monkeypatch)
    calls = []

    def always_dns_fail() -> None:
        calls.append(1)
        raise httplib2.ServerNotFoundError("Unable to find the server")

    assert notifier._run_with_retry(always_dns_fail, "weekly") is False
    assert len(calls) == notifier.NETWORK_RETRIES


def test_run_with_retry_recovers_when_network_returns(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _no_wait(monkeypatch)
    calls = []

    def fail_once_then_succeed() -> None:
        calls.append(1)
        if len(calls) == 1:
            raise ConnectionError("temporary")

    assert notifier._run_with_retry(fail_once_then_succeed, "daily") is True
    assert len(calls) == 2


def test_run_with_retry_does_not_retry_permanent_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """認証切れなど恒久的な失敗は1回で諦める（30秒×5回待たない）。"""
    _no_wait(monkeypatch)
    calls = []

    def permanent_fail() -> None:
        calls.append(1)
        raise ValueError("invalid_grant")

    assert notifier._run_with_retry(permanent_fail, "daily") is False
    assert len(calls) == 1


def test_weekly_failure_does_not_block_daily(monkeypatch: pytest.MonkeyPatch) -> None:
    """2026-08-17 の事故の再発防止: 月曜に週次が落ちても日次は送られる。"""
    _no_wait(monkeypatch)
    monkeypatch.setattr(notifier.db, "init_db", lambda: None)
    # 月曜に固定する
    monday = datetime(2026, 8, 17, 8, 0, tzinfo=JST)
    monkeypatch.setattr(notifier, "datetime", _FixedNow(monday))
    sent = []

    def weekly_dns_fail() -> None:
        raise httplib2.ServerNotFoundError("Unable to find the server")

    monkeypatch.setattr(notifier, "send_weekly_summary", weekly_dns_fail)
    monkeypatch.setattr(notifier, "send_daily_summary", lambda: sent.append("daily"))

    notifier.main()

    assert sent == ["daily"]


def test_auth_error_alerts_via_line_without_retrying(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """認証切れはリトライせず、代わりに LINE で理由を知らせる（黙って止まらない）。"""
    _no_wait(monkeypatch)
    monkeypatch.setattr(notifier.db, "already_notified", lambda *a: False)
    monkeypatch.setattr(notifier.db, "mark_notified", lambda *a: None)
    pushed = []
    monkeypatch.setattr(
        notifier.line_client, "push", lambda _uid, text: pushed.append(text)
    )
    calls = []

    def auth_expired() -> None:
        calls.append(1)
        raise notifier.calendar_client.AuthRequiredError("Google の再認証が必要です。")

    assert notifier._run_with_retry(auth_expired, "daily") is False
    assert len(calls) == 1  # リトライしない
    assert len(pushed) == 1
    assert "再認証" in pushed[0]


def test_auth_alert_sent_once_per_day(monkeypatch: pytest.MonkeyPatch) -> None:
    """同日2回目は送らない（週次と日次の両方で落ちても1通）。"""
    _no_wait(monkeypatch)
    monkeypatch.setattr(notifier.db, "already_notified", lambda *a: True)
    pushed = []
    monkeypatch.setattr(
        notifier.line_client, "push", lambda _uid, text: pushed.append(text)
    )
    notifier._notify_auth_required(RuntimeError("x"))
    assert pushed == []


class _FixedNow:
    """notifier.datetime.now() だけを固定するスタブ（曜日分岐の検証用）。"""

    def __init__(self, moment: datetime) -> None:
        self._moment = moment

    def now(self, tz: object = None) -> datetime:
        return self._moment
