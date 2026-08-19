"""LINE Webhook を受け、予定を登録・更新・削除・一覧表示する Flask アプリ。"""
from __future__ import annotations

import logging
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from flask import Flask, abort, request

from src import calendar_client, db, line_client
from src.config import TZ, VERIFY_SIGNATURE, WEBHOOK_HOST, WEBHOOK_PORT
from src.notifier import format_events, format_range_label, period_range
from src.parser import parse_message

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

app = Flask(__name__)
db.init_db()


@app.post("/webhook/line")
def webhook() -> tuple[str, int]:
    """LINE Messaging API からの Webhook エンドポイント。"""
    body = request.get_data()
    signature = request.headers.get("X-Line-Signature", "")
    if VERIFY_SIGNATURE and not line_client.verify_signature(body, signature):
        logger.warning("signature mismatch")
        abort(400, "invalid signature")
    payload = request.get_json(force=True, silent=True) or {}
    for event in payload.get("events", []):
        if event.get("type") != "message":
            continue
        if event.get("message", {}).get("type") != "text":
            continue
        try:
            _handle_text(event)
        except calendar_client.AuthRequiredError as exc:
            # ブラウザ認証が要る状態。汎用エラーだと原因が分からず放置されるので明示する。
            logger.error("auth required: %s", exc)
            _safe_reply(event, f"⚠️ カレンダーに接続できません\n{exc}")
        except Exception:
            logger.exception("handle event failed")
            _safe_reply(event, "エラーが発生しました")
    return "OK", 200


def _safe_reply(event: dict[str, Any], text: str) -> None:
    """返信を試みる。返信自体の失敗で Webhook を落とさない。"""
    try:
        line_client.reply(event["replyToken"], text)
    except Exception:
        logger.exception("reply failed")


@app.get("/healthz")
def healthz() -> tuple[str, int]:
    """死活監視用。"""
    return "ok", 200


def _handle_text(event: dict[str, Any]) -> None:
    text = event["message"]["text"]
    reply_token = event["replyToken"]
    # userId はログにしか出ない。初回セットアップで LINE_USER_ID を拾う唯一の手段。
    logger.info("received userId=%s: %s", event.get("source", {}).get("userId", "-"), text)
    recent = db.latest_event()
    parsed = parse_message(
        text, recent_event=_describe_event_row(recent) if recent else None
    )
    action = parsed.get("action", "unknown")
    handlers = {
        "create": _handle_create,
        "update": _handle_update,
        "delete": _handle_delete,
        "list": _handle_list,
    }
    handler = handlers.get(action)
    if handler:
        handler(reply_token, parsed)
    else:
        line_client.reply(
            reply_token,
            parsed.get("message")
            or "予定として認識できませんでした。\n例:「明日15時に田中さんと打ち合わせ」",
        )


def _describe_event_row(row: Any) -> str:
    """DB の予定行を「7/8(水) 09:00 タイトル」形式の文字列にする（解析の文脈用）。"""
    start_at = row["start_at"]
    label = format_range_label(start_at, row["end_at"], "T" not in start_at)
    return f"{label} {row['title']}"


_RRULE_DAY_JA = {
    "MO": "月",
    "TU": "火",
    "WE": "水",
    "TH": "木",
    "FR": "金",
    "SA": "土",
    "SU": "日",
}


def _recurrence_label(rrule: str) -> str:
    """RRULE を日本語の短い説明に変換する（確認メッセージ用）。"""
    parts = dict(
        p.split("=", 1) for p in rrule.replace("RRULE:", "").split(";") if "=" in p
    )
    freq = parts.get("FREQ", "")
    if freq == "DAILY":
        base = "毎日"
    elif freq == "WEEKLY":
        days = "".join(
            _RRULE_DAY_JA.get(d, d) for d in parts.get("BYDAY", "").split(",") if d
        )
        base = f"毎週{days}曜" if days else "毎週"
    elif freq == "MONTHLY":
        if parts.get("BYMONTHDAY") == "-1":
            base = "毎月末"
        elif "BYMONTHDAY" in parts:
            base = f"毎月{parts['BYMONTHDAY']}日"
        elif "BYDAY" in parts:
            base = f"毎月 {parts['BYDAY']}"
        else:
            base = "毎月"
    elif freq == "YEARLY":
        base = "毎年"
    else:
        base = "繰り返し"
    if parts.get("COUNT"):
        base += f"（{parts['COUNT']}回）"
    elif parts.get("UNTIL"):
        base += f"（{parts['UNTIL'][:8]}まで）"
    return base


def _handle_create(reply_token: str, parsed: dict[str, Any]) -> None:
    start_at = parsed.get("start_at")
    title = parsed.get("title") or "(無題)"
    recurrence = parsed.get("recurrence")
    all_day = bool(parsed.get("all_day"))
    end_at = parsed.get("end_at")
    if not start_at:
        line_client.reply(reply_token, "日時を特定できませんでした")
        return
    event = calendar_client.create_event(
        title=title,
        start_at=start_at,
        end_at=end_at,
        description=parsed.get("description"),
        recurrence=recurrence,
        all_day=all_day,
    )
    db.upsert_event(
        google_event_id=event["id"],
        title=title,
        start_at=start_at,
        end_at=end_at,
        description=parsed.get("description"),
    )
    rec_label = f"\n🔁 {_recurrence_label(recurrence)}" if recurrence else ""
    line_client.reply(
        reply_token,
        f"✅ 登録しました\n{format_range_label(start_at, end_at, all_day)} {title}{rec_label}",
    )


def _handle_update(reply_token: str, parsed: dict[str, Any]) -> None:
    query = parsed.get("search_query") or parsed.get("title")
    if query:
        search_date = _parse_date(parsed.get("search_date"))
        event = calendar_client.search_event(query, around_date=search_date)
        if not event:
            line_client.reply(reply_token, f"「{query}」に該当する予定が見つかりません")
            return
    else:
        # キーワードが無い（「先ほどの予定を変更」等）→ 直近で操作した予定を対象にする
        recent = db.latest_event()
        if not recent:
            line_client.reply(reply_token, "変更対象の予定を特定できませんでした")
            return
        event = {"id": recent["google_event_id"], "summary": recent["title"]}
    fields: dict[str, Any] = {
        k: parsed[k]
        for k in ("title", "start_at", "end_at", "description")
        if parsed.get(k)
    }
    if fields.get("start_at") or fields.get("end_at"):
        fields["all_day"] = bool(parsed.get("all_day"))
    updated = calendar_client.update_event(event["id"], **fields)
    start_at = updated["start"].get("dateTime") or updated["start"]["date"]
    all_day = "date" in updated["start"]
    # Google の終日 end は exclusive なので、表示・保存用に「含む最終日」へ戻す
    if all_day:
        end_at = (
            date.fromisoformat(updated["end"]["date"]) - timedelta(days=1)
        ).isoformat()
    else:
        end_at = updated["end"].get("dateTime")
    db.upsert_event(
        google_event_id=updated["id"],
        title=updated.get("summary", ""),
        start_at=start_at,
        end_at=end_at,
        description=updated.get("description"),
    )
    line_client.reply(
        reply_token,
        f"✏️ 変更しました\n{format_range_label(start_at, end_at, all_day)} {updated.get('summary', '')}",
    )


def _handle_delete(reply_token: str, parsed: dict[str, Any]) -> None:
    query = parsed.get("search_query") or parsed.get("title")
    if not query:
        line_client.reply(reply_token, "削除対象の予定を特定できませんでした")
        return
    search_date = _parse_date(parsed.get("search_date"))
    event = calendar_client.search_event(query, around_date=search_date)
    if not event:
        line_client.reply(reply_token, f"「{query}」に該当する予定が見つかりません")
        return
    calendar_client.delete_event(event["id"])
    db.delete_event(event["id"])
    line_client.reply(reply_token, f"🗑 削除しました\n{event.get('summary', '')}")


def _handle_list(reply_token: str, parsed: dict[str, Any]) -> None:
    period = parsed.get("list_period") or "today"
    list_date = _parse_date(parsed.get("list_date"))
    start, end, label = period_range(period, list_date, parsed.get("list_month"))
    events = calendar_client.list_events(start, end)
    line_client.reply(reply_token, format_events(events, label))


def _parse_date(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s).replace(tzinfo=ZoneInfo(TZ))
    except ValueError:
        return None


if __name__ == "__main__":
    app.run(host=WEBHOOK_HOST, port=WEBHOOK_PORT)
