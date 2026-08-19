"""自由文 → 構造化データへの変換（Gemini API 使用）。"""

from __future__ import annotations

import json
import logging
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from google import genai

from src.config import GEMINI_API_KEY, GEMINI_MODEL, TZ

logger = logging.getLogger(__name__)

_client: genai.Client | None = None


def _get_client() -> genai.Client:
    """Gemini クライアントを遅延生成する。"""
    global _client
    if _client is None:
        _client = genai.Client(api_key=GEMINI_API_KEY)
    return _client


WEEKDAY_JA = ["月", "火", "水", "木", "金", "土", "日"]

PROMPT_TEMPLATE = """あなたは日本語のスケジュール解析アシスタントです。
ユーザーのメッセージから予定情報を抽出し、JSON のみを返してください。

現在日時: {now} ({weekday}曜日)
直近で操作した予定: {recent}

action のいずれかに分類:
- create: 新規予定の登録
- update: 既存予定の日時・内容変更
- delete: 予定のキャンセル
- list: 予定の確認（例「今週の予定」「明日何あったっけ」）
- unknown: 予定と無関係、または解析不能

出力（JSON のみ・前後に説明禁止）:
{{
  "action": "create|update|delete|list|unknown",
  "all_day": true | false,
  "start_at": "YYYY-MM-DDTHH:MM:00 または all_day=true なら YYYY-MM-DD" | null,
  "end_at": "YYYY-MM-DDTHH:MM:00 または all_day=true なら YYYY-MM-DD（含む最終日）" | null,
  "title": "簡潔なタイトル" | null,
  "description": "詳細・相手・場所など" | null,
  "recurrence": "iCalendar RRULE（FREQ=... 形式、RRULE:接頭辞なし）" | null,
  "search_query": "update/delete で既存予定を探すキーワード" | null,
  "search_date": "YYYY-MM-DD" | null,
  "list_period": "today|tomorrow|this_week|next_week|this_month|next_month|month|date" | null,
  "list_date": "YYYY-MM-DD" | null,
  "list_month": "YYYY-MM" | null,
  "message": "ユーザーへの短い確認メッセージ"
}}

ルール:
- 時刻が指定された予定は all_day=false、start_at/end_at は "YYYY-MM-DDTHH:MM:00"
- 時刻が未指定の create は 09:00 とする（all_day=false のまま）
- end_at が未指定なら null（呼び出し側で +1h 補完）
- 「来週月曜」などの相対表現は現在日時を起点に解釈
- 「◯◯にメール」「◯◯に電話」などタスク系も create として扱う
- 曖昧・解釈不能なら action を unknown にして message で聞き返す

一覧（action=list）の期間指定ルール（重要）:
- 「今日/本日」→ today、「明日」→ tomorrow
- 「今週」→ this_week、「来週」→ next_week
- 「今月」→ this_month、「来月」→ next_month
- **「8月の予定は？」「12月なにある？」のように月を指す表現は list_period="month" とし、
  list_month に "YYYY-MM" を入れる**（月だけの指定なら現在日時以降で最も近いその月の年を使う）
  - 例（現在=2026-07-27）: 「8月の予定は？」→ list_period="month", list_month="2026-08"
  - 例（現在=2026-07-27）: 「1月の予定は？」→ list_period="month", list_month="2027-01"
  - 例: 「2027年3月の予定」→ list_period="month", list_month="2027-03"
- **月を指す表現を list_period="date" にしてはいけない**（その月の1日だけしか返らないため）
- 特定の1日を指すときだけ list_period="date"＋list_date="YYYY-MM-DD"

タイトル抽出のルール（重要）:
- 予定名の直後にある括弧書き（補足・対象・場所など）は **タイトルの一部としてそのまま残す**
  - 「夏季休暇（棚卸し）」→ title="夏季休暇（棚卸し）", description=null
  - 「会議（議題: Q3予算）」→ title="会議（議題: Q3予算）", description=null
  - 「健康診断（再検査）」→ title="健康診断（再検査）", description=null
  - 半角丸括弧 ( ) / 全角丸括弧 （ ） / 角括弧 [ ] 【 】 すべて対象
- description に入れるのは「○○さんと」「場所: ◯◯」「持ち物: ◯◯」のような独立した補足情報のみ
- 迷ったら括弧書きはタイトル側に残す

終日・期間予定（all_day=true）のルール:
- 「夏季休暇」「出張」「研修」「旅行」「有給」など、時刻指定がなく日単位で続く予定は all_day=true
- 単日なら end_at は null か start_at と同じ日
- 期間指定なら end_at は **含む最終日**（呼び出し側で Google 仕様の翌日に変換する）
- start_at/end_at は時刻なしの "YYYY-MM-DD" 形式
- 例（現在=2026年として）:
  - 「8/11から7日間 夏季休暇」→ all_day=true, start_at="2026-08-11", end_at="2026-08-17"
    （11,12,13,14,15,16,17 の7日間、最終日を含めて記載）
  - 「8/11-16 夏季休暇」→ all_day=true, start_at="2026-08-11", end_at="2026-08-16"
  - 「8/11〜8/16 出張」→ all_day=true, start_at="2026-08-11", end_at="2026-08-16"
  - 「来週月曜から金曜まで研修」→ all_day=true, start_at=次の月曜の日付, end_at=その金曜の日付
  - 「8/11 夏季休暇」（単日）→ all_day=true, start_at="2026-08-11", end_at=null
- 時刻が一つでも入っていたら all_day=false（例「8/11 9時から12時 研修」）

繰り返し（recurrence）のルール:
- 単発の予定なら recurrence は null
- 繰り返し表現があれば RRULE 文字列を生成する。start_at は「初回の日時」にする
- 例:
  - 「毎日」→ "FREQ=DAILY"
  - 「毎週月曜」→ "FREQ=WEEKLY;BYDAY=MO"
  - 「毎月15日」→ "FREQ=MONTHLY;BYMONTHDAY=15"
  - 「毎月末」→ "FREQ=MONTHLY;BYMONTHDAY=-1"
  - 「毎月第2火曜」→ "FREQ=MONTHLY;BYDAY=2TU"
  - 「毎年4月1日」→ "FREQ=YEARLY"
  - 「平日毎日」→ "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
  - 「10回まで」等の回数指定があれば ;COUNT=10、「12月まで」等の終了があれば ;UNTIL=YYYYMMDDT000000Z を付与
- 曜日コード: 月=MO 火=TU 水=WE 木=TH 金=FR 土=SA 日=SU

直近の予定への参照ルール（重要）:
- 「先ほど」「さっき」「今の」「その予定」「それ」「先の予定」など直近の予定を指す表現は、
  上記『直近で操作した予定』を対象とする（『（なし）』なら対象なしとして message で聞き返す）
- その場合は action=update（キャンセルなら delete）とし、
  search_query にその予定のタイトル、search_date にその予定の日付(YYYY-MM-DD) を必ず入れる
- 時刻変更（例「9時から19時へ変更」「14時に変更」）は、その予定の日付を保ったまま
  start_at を変更後の時刻にする（例: 直近の予定が 2026-07-08 なら start_at="2026-07-08T19:00:00"）
- 「AからBへ変更」「AをBに」はAが現在値・Bが変更後の値。start_at は B（変更後）の値にする
  （「9時から19時へ」は 9:00→19:00 の変更であり、9:00〜19:00 の時間帯ではない）

update で終日・期間予定に変えるルール（重要）:
- 変更後(B)が日付だけ／複数日にまたがる場合は all_day=true とし、
  start_at・end_at を **時刻なしの "YYYY-MM-DD"**（end_at は含む最終日）にする
  - 例: 「12/4(金) 13:30 名証IR EXPOから12/4(金)〜12/5(土) 名証IR EXPOへ変更」
    → action="update", search_query="名証IR EXPO", search_date="2026-12-04",
      all_day=true, start_at="2026-12-04", end_at="2026-12-05"
  - 例: 「8/11の出張を8/13までに延長」→ all_day=true, start_at="2026-08-11", end_at="2026-08-13"
- 逆に変更後に時刻が入るなら all_day=false とし "YYYY-MM-DDTHH:MM:00" にする
- all_day=true のとき start_at/end_at に "T00:00:00" を付けてはいけない

ユーザーメッセージ:
{text}
"""


def parse_message(text: str, recent_event: str | None = None) -> dict[str, Any]:
    """自由文を解析して構造化データを返す。

    recent_event: 直近で操作した予定の説明（「先ほどの予定」等の参照解決に使う）。
    """
    now = datetime.now(ZoneInfo(TZ))
    prompt = PROMPT_TEMPLATE.format(
        now=now.strftime("%Y-%m-%d %H:%M"),
        weekday=WEEKDAY_JA[now.weekday()],
        recent=recent_event or "（なし）",
        text=text,
    )
    try:
        response = _get_client().models.generate_content(
            model=GEMINI_MODEL,
            contents=prompt,
            config={"response_mime_type": "application/json"},
        )
        return json.loads(response.text)
    except Exception:
        logger.exception("Gemini parse failed")
        return {"action": "unknown", "message": "解析に失敗しました"}
