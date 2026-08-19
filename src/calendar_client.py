"""Google Calendar API の薄いラッパー。"""

from __future__ import annotations

import sys
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from google.auth.exceptions import RefreshError
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build

from src.config import (
    GOOGLE_CALENDAR_ID,
    GOOGLE_CREDENTIALS_PATH,
    GOOGLE_TOKEN_PATH,
    TZ,
)

SCOPES = ["https://www.googleapis.com/auth/calendar"]

# 対話認証（ブラウザ）を待つ上限。人が席を外しても永久には待たない。
AUTH_TIMEOUT_SEC = 300

# src/ は Windows 配布版と共有するので、両方の再認証手順を出す。
REAUTH_HINT = (
    "Google の再認証が必要です。\n"
    "  Mac: cd ~/Claude/スケジュール管理 && .venv/bin/python -m src.calendar_client\n"
    "  Win: 2_google_auth.bat をダブルクリック"
)


class AuthRequiredError(RuntimeError):
    """人がブラウザで認証し直さないと復旧できない状態。

    LaunchAgent 配下（notifier / webhook）にはブラウザが無く、対話フローに入ると
    無言でハングし続けるため、常駐側では対話に落ちずにこれを送出して即座に失敗させる。
    """


def _load_creds() -> Credentials | None:
    """token.json があれば読む。無ければ None。"""
    if not GOOGLE_TOKEN_PATH.exists():
        return None
    creds: Credentials = Credentials.from_authorized_user_file(  # type: ignore[no-untyped-call]
        str(GOOGLE_TOKEN_PATH), SCOPES
    )
    return creds


def _save_creds(creds: Credentials) -> None:
    """token.json を書き出す。"""
    GOOGLE_TOKEN_PATH.write_text(creds.to_json(), encoding="utf-8")  # type: ignore[no-untyped-call]


def authorize() -> Credentials:
    """ブラウザで対話認証し、token.json を作り直す。

    **人が操作している端末からのみ呼ぶこと**（`python -m src.calendar_client`）。
    常駐プロセスから呼んではいけない。

    Returns:
        取得した認証情報。

    Raises:
        AuthRequiredError: credentials.json が無い、または時間内に許可されなかった場合。
    """
    if not GOOGLE_CREDENTIALS_PATH.exists():
        raise AuthRequiredError(
            f"credentials.json が見つかりません: {GOOGLE_CREDENTIALS_PATH}"
        )
    flow = InstalledAppFlow.from_client_secrets_file(
        str(GOOGLE_CREDENTIALS_PATH), SCOPES
    )
    try:
        creds: Credentials = flow.run_local_server(
            port=0, timeout_seconds=AUTH_TIMEOUT_SEC
        )
    except Exception as exc:  # タイムアウト・ブラウザ未起動など
        raise AuthRequiredError(f"対話認証に失敗しました: {exc}") from exc
    _save_creds(creds)
    return creds


def _service(allow_interactive: bool = False) -> Any:
    """認証済み Calendar API サービスを返す。

    既定では**対話認証に落ちない**。token.json が無い/失効してリフレッシュもできない場合は
    `AuthRequiredError` を送出する（常駐プロセスがブラウザ待ちでハングするのを防ぐため）。

    Args:
        allow_interactive: True のときだけブラウザ認証を許す。人が操作する再認証コマンド専用。

    Raises:
        AuthRequiredError: 再認証が必要だが対話が許されていない場合。
    """
    creds = _load_creds()
    if creds and creds.valid:
        return build("calendar", "v3", credentials=creds, cache_discovery=False)

    if creds and creds.expired and creds.refresh_token:
        try:
            creds.refresh(Request())  # type: ignore[no-untyped-call]
        except RefreshError as exc:
            # 失効・取り消し済み（invalid_grant）。リフレッシュでは復旧できない。
            if not allow_interactive:
                raise AuthRequiredError(f"{REAUTH_HINT}\n  （原因: {exc}）") from exc
            creds = authorize()
        else:
            _save_creds(creds)
    elif allow_interactive:
        creds = authorize()
    else:
        if not creds:
            reason = "token.json がありません"
        elif not creds.refresh_token:
            reason = "リフレッシュトークンがありません"
        else:
            # valid=False かつ expired=False ＝ token が空など token.json が壊れている
            reason = "token.json が不正です"
        raise AuthRequiredError(f"{REAUTH_HINT}\n  （原因: {reason}）")

    return build("calendar", "v3", credentials=creds, cache_discovery=False)


def create_event(
    title: str,
    start_at: str,
    end_at: str | None = None,
    description: str | None = None,
    recurrence: str | None = None,
    all_day: bool = False,
) -> dict[str, Any]:
    """予定を作成する。

    通常予定: end_at 未指定なら開始 +1h。
    終日/期間予定 (all_day=True): start_at/end_at は "YYYY-MM-DD"。
      end_at は **含む最終日**として受け取り、Google 仕様（end は exclusive）に合わせて +1日して送る。
      end_at 未指定なら単日（start_at の翌日を end に）。
    recurrence は RRULE 本体（例: "FREQ=MONTHLY;BYMONTHDAY=15"）。
    """
    body: dict[str, Any] = {
        "summary": title,
        "description": description or "",
    }
    if all_day:
        start_date = date.fromisoformat(start_at[:10])
        if end_at:
            end_inclusive = date.fromisoformat(end_at[:10])
        else:
            end_inclusive = start_date
        end_exclusive = end_inclusive + timedelta(days=1)
        body["start"] = {"date": start_date.isoformat()}
        body["end"] = {"date": end_exclusive.isoformat()}
    else:
        if not end_at:
            start = datetime.fromisoformat(start_at)
            end_at = (start + timedelta(hours=1)).isoformat()
        body["start"] = {"dateTime": start_at, "timeZone": TZ}
        body["end"] = {"dateTime": end_at, "timeZone": TZ}
    if recurrence:
        rule = recurrence if recurrence.startswith("RRULE:") else f"RRULE:{recurrence}"
        body["recurrence"] = [rule]
    created: dict[str, Any] = (
        _service().events().insert(calendarId=GOOGLE_CALENDAR_ID, body=body).execute()
    )
    return created


def _apply_period(
    event: dict[str, Any],
    start_at: str | None,
    end_at: str | None,
    all_day: bool | None,
) -> None:
    """update 用に event の start/end を書き換える（時刻付き⇔終日の相互変換に対応）。

    start_at/end_at のどちらか一方だけの指定でも、既存イベントを補完して整合を取る。
    all_day が未指定でも、値が "YYYY-MM-DD" 形式なら終日と判定する。
    end_at は **含む最終日**として受け取り、終日予定なら Google 仕様（exclusive）に +1日する。
    """
    if not start_at and not end_at:
        return
    # 値の形式（"T" の有無）を優先して判定する。日付のみの値を dateTime として送ると 400 になる。
    sample = start_at or end_at or ""
    all_day = bool(all_day) or "T" not in sample
    if all_day:
        start_date = (
            date.fromisoformat(start_at[:10])
            if start_at
            else date.fromisoformat(
                (event["start"].get("date") or event["start"]["dateTime"])[:10]
            )
        )
        end_inclusive = date.fromisoformat(end_at[:10]) if end_at else start_date
        if end_inclusive < start_date:
            end_inclusive = start_date
        # dict ごと差し替え（dateTime と date の混在は 400 になる）
        event["start"] = {"date": start_date.isoformat()}
        event["end"] = {"date": (end_inclusive + timedelta(days=1)).isoformat()}
        return
    if not start_at:
        # 終了時刻だけの変更
        event["end"] = {"dateTime": end_at, "timeZone": TZ}
        return
    if not end_at or "T" not in end_at:
        end_at = (datetime.fromisoformat(start_at) + timedelta(hours=1)).isoformat()
    event["start"] = {"dateTime": start_at, "timeZone": TZ}
    event["end"] = {"dateTime": end_at, "timeZone": TZ}


def update_event(event_id: str, **fields: Any) -> dict[str, Any]:
    """既存予定を部分更新する。

    all_day=True（または start_at が "YYYY-MM-DD" 形式）なら終日/期間予定に変換する。
    時刻付き→終日、終日→時刻付き のどちらの方向にも対応する。
    """
    svc = _service()
    event = svc.events().get(calendarId=GOOGLE_CALENDAR_ID, eventId=event_id).execute()
    if fields.get("title"):
        event["summary"] = fields["title"]
    _apply_period(
        event, fields.get("start_at"), fields.get("end_at"), fields.get("all_day")
    )
    if fields.get("description"):
        event["description"] = fields["description"]
    updated: dict[str, Any] = (
        svc.events()
        .update(calendarId=GOOGLE_CALENDAR_ID, eventId=event_id, body=event)
        .execute()
    )
    return updated


def delete_event(event_id: str) -> None:
    """予定を削除する。"""
    _service().events().delete(
        calendarId=GOOGLE_CALENDAR_ID, eventId=event_id
    ).execute()


def list_events(
    time_min: datetime,
    time_max: datetime,
    query: str | None = None,
) -> list[dict[str, Any]]:
    """指定期間の予定を取得する。"""
    params: dict[str, Any] = {
        "calendarId": GOOGLE_CALENDAR_ID,
        "timeMin": time_min.astimezone(ZoneInfo(TZ)).isoformat(),
        "timeMax": time_max.astimezone(ZoneInfo(TZ)).isoformat(),
        "singleEvents": True,
        "orderBy": "startTime",
    }
    if query:
        params["q"] = query
    items: list[dict[str, Any]] = (
        _service().events().list(**params).execute().get("items", [])
    )
    return items


def search_event(
    query: str, around_date: datetime | None = None
) -> dict[str, Any] | None:
    """キーワードと日付近傍で予定を1件特定する。"""
    if around_date:
        time_min = around_date - timedelta(days=1)
        time_max = around_date + timedelta(days=2)
    else:
        time_min = datetime.now(ZoneInfo(TZ))
        time_max = time_min + timedelta(days=60)
    events = list_events(time_min, time_max, query=query)
    return events[0] if events else None


if __name__ == "__main__":
    # 再認証用エントリポイント: .venv/bin/python -m src.calendar_client
    # （Windows では 2_google_auth.bat がこれを呼ぶ。失敗時は exit 1 を返す）
    try:
        authorize()
    except AuthRequiredError as exc:
        print(f"認証できませんでした: {exc}", file=sys.stderr)
        sys.exit(1)
    print("認証しました（token.json を更新）")
