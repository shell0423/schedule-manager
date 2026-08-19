"""朝の通知バッチ（LaunchAgent から毎朝 08:00 に実行）。"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

import httplib2
from google.auth.exceptions import TransportError

from src import calendar_client, db, line_client
from src.config import LINE_USER_ID, TZ

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

JST = ZoneInfo(TZ)
WEEKDAY_JA = ["月", "火", "水", "木", "金", "土", "日"]

# スリープ復帰直後は DNS がまだ引けないことがある（LaunchAgent は起床後すぐ走る）。
# 認証切れのような恒久的な失敗と区別して、これだけ待ち直す。
NETWORK_RETRIES = 5
NETWORK_RETRY_WAIT_SEC = 30

# トークン更新は requests、Calendar API 呼び出しは httplib2 を通る。
# 名前解決・接続失敗・タイムアウトは requests / socket 由来を含めすべて OSError 系だが、
# httplib2.ServerNotFoundError だけは OSError 系でないため個別に挙げる必要がある。
# （OSError には token.json 書き込み失敗なども入るが、待って諦めるだけなので害はない）
_TRANSIENT_ERRORS: tuple[type[Exception], ...] = (
    TransportError,
    httplib2.ServerNotFoundError,
    OSError,
)


def _month_start(year: int, month: int) -> datetime:
    """指定年月の1日 00:00 (JST) を返す。"""
    return datetime(year, month, 1, tzinfo=JST)


def _next_month_start(d: datetime) -> datetime:
    """指定日の属する月の「翌月1日 00:00」を返す。"""
    return _month_start(d.year + (d.month == 12), d.month % 12 + 1)


def period_range(
    period: str,
    specific_date: datetime | None = None,
    specific_month: str | None = None,
) -> tuple[datetime, datetime, str]:
    """期間キーワード → (start, end, 表示ラベル)。

    specific_month は period="month" のときの "YYYY-MM"。
    """
    now = datetime.now(JST)
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if period == "today":
        return today, today + timedelta(days=1), "本日"
    if period == "tomorrow":
        start = today + timedelta(days=1)
        return start, start + timedelta(days=1), "明日"
    if period == "this_week":
        start = today - timedelta(days=today.weekday())
        return start, start + timedelta(days=7), "今週"
    if period == "next_week":
        start = today - timedelta(days=today.weekday()) + timedelta(days=7)
        return start, start + timedelta(days=7), "来週"
    if period == "this_month":
        start = _month_start(today.year, today.month)
        return start, _next_month_start(start), "今月"
    if period == "next_month":
        start = _next_month_start(today)
        return start, _next_month_start(start), "来月"
    if period == "month" and specific_month:
        try:
            year, month = (int(x) for x in specific_month.split("-")[:2])
            start = _month_start(year, month)
        except (ValueError, TypeError):
            start = _month_start(today.year, today.month)
        label = (
            f"{start.month}月"
            if start.year == today.year
            else f"{start.year}年{start.month}月"
        )
        return start, _next_month_start(start), label
    if period == "date" and specific_date:
        start = specific_date.replace(hour=0, minute=0, second=0, microsecond=0)
        # strftime の %-m/%-d は Windows で ValueError になるため自前で組み立てる
        label = f"{start.month}/{start.day}"
        return start, start + timedelta(days=1), label
    return today, today + timedelta(days=1), "本日"


def format_date(iso: str) -> str:
    """ "2026-12-04..." → "12/4(金)"。"""
    d = date.fromisoformat(iso[:10])
    return f"{d.month}/{d.day}({WEEKDAY_JA[d.weekday()]})"


def format_stamp(iso: str) -> str:
    """ "2026-12-04T13:30:00" → "12/4(金) 13:30"。"""
    dt = datetime.fromisoformat(iso)
    return f"{format_date(iso)} {dt.strftime('%H:%M')}"


def format_range_label(start_at: str, end_at: str | None, all_day: bool) -> str:
    """期間ラベルを生成する。

    end_at は終日予定なら **含む最終日**（Google の exclusive な end ではない）。
    複数日にまたがるときだけ「〜」で終了側も表示する。
    """
    if end_at is None or end_at[:10] == start_at[:10]:
        return f"{format_date(start_at)} 終日" if all_day else format_stamp(start_at)
    if all_day:
        return f"{format_date(start_at)}〜{format_date(end_at)} 終日"
    return f"{format_stamp(start_at)}〜{format_stamp(end_at)}"


def _event_period(e: dict[str, Any]) -> tuple[str, str | None, bool]:
    """Calendar イベント → (start_at, end_at(含む最終日), all_day)。"""
    all_day = "date" in e.get("start", {})
    start_at = e["start"].get("dateTime") or e["start"]["date"]
    end_raw = e.get("end", {})
    end_at = end_raw.get("dateTime") or end_raw.get("date")
    if all_day and end_at:
        # Google の終日 end は exclusive なので「含む最終日」に戻す
        end_at = (date.fromisoformat(end_at[:10]) - timedelta(days=1)).isoformat()
    return start_at, end_at, all_day


def format_events(events: list[dict[str, Any]], label: str) -> str:
    """LINE 送信用のテキストに整形する。"""
    if not events:
        return f"📅 {label}の予定はありません"
    lines = [f"📅 {label}の予定"]
    for e in events:
        start_at, end_at, all_day = _event_period(e)
        try:
            stamp = format_range_label(start_at, end_at, all_day)
        except ValueError:
            stamp = start_at
        lines.append(f"・{stamp} {e.get('summary', '(無題)')}")
    return "\n".join(lines)


def send_weekly_summary() -> None:
    """今週の予定を LINE に Push する。"""
    today = datetime.now(JST).date().isoformat()
    if db.already_notified("weekly", today):
        logger.info("weekly already sent for %s", today)
        return
    start, end, label = period_range("this_week")
    events = calendar_client.list_events(start, end)
    line_client.push(LINE_USER_ID, format_events(events, label))
    db.mark_notified("weekly", today)
    logger.info("weekly summary sent: %d events", len(events))


def send_daily_summary() -> None:
    """本日の予定を LINE に Push する（予定ゼロなら送らない）。"""
    today = datetime.now(JST).date().isoformat()
    if db.already_notified("daily", today):
        logger.info("daily already sent for %s", today)
        return
    start, end, label = period_range("today")
    events = calendar_client.list_events(start, end)
    if events:
        line_client.push(LINE_USER_ID, format_events(events, label))
    db.mark_notified("daily", today)
    logger.info("daily summary sent: %d events", len(events))


def _run_with_retry(func: Callable[[], None], label: str) -> bool:
    """通知1件を実行する。一時的なネットワーク断はリトライし、失敗しても例外を上げない。

    週次が落ちても日次を巻き添えにしないため、例外はここで止める。

    Args:
        func: 実行する送信関数。
        label: ログ用のラベル（"weekly" / "daily"）。

    Returns:
        送信できたら True。
    """
    for attempt in range(1, NETWORK_RETRIES + 1):
        try:
            func()
            return True
        except _TRANSIENT_ERRORS as exc:
            if attempt == NETWORK_RETRIES:
                logger.error("%s failed after %d attempts: %s", label, attempt, exc)
                return False
            logger.warning(
                "%s: network unavailable (%d/%d), retry in %ds",
                label,
                attempt,
                NETWORK_RETRIES,
                NETWORK_RETRY_WAIT_SEC,
            )
            time.sleep(NETWORK_RETRY_WAIT_SEC)
        except calendar_client.AuthRequiredError as exc:
            # 黙って通知が止まると原因に気づけないので LINE で知らせる。
            # Push は Google 認証を使わないのでこの状況でも届く。
            logger.error("%s: auth required: %s", label, exc)
            _notify_auth_required(exc)
            return False
        except Exception:
            logger.exception("%s failed", label)
            return False
    return False


def _notify_auth_required(exc: Exception) -> None:
    """再認証が必要なことを LINE に伝える（1日1回まで）。"""
    today = datetime.now(JST).date().isoformat()
    if db.already_notified("auth_alert", today):
        return
    try:
        line_client.push(LINE_USER_ID, f"⚠️ カレンダーに接続できません\n{exc}")
        db.mark_notified("auth_alert", today)
    except Exception:
        logger.exception("auth alert push failed")


def main() -> None:
    """月曜朝に週次・毎朝に当日分の通知を行う。"""
    db.init_db()
    now = datetime.now(JST)
    if now.weekday() == 0:  # 月曜
        _run_with_retry(send_weekly_summary, "weekly")
    _run_with_retry(send_daily_summary, "daily")


if __name__ == "__main__":
    main()
