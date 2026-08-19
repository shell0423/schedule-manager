#!/bin/bash
# test_notify.command の本体。朝の通知を今すぐ1回試す。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

title "通知テスト"
require_venv || { pause_exit; exit 1; }

if [ -z "$(env_get LINE_USER_ID)" ]; then
  err "宛先（LINE_USER_ID）が未設定です。"
  printf '    LINE で AI秘書 に1通送ってから 4_set_user_id.command を実行してください。\n'
  pause_exit; exit 1
fi

info "送信しています..."
cd "$ROOT" || exit 1
"$VENV_PY" -m src.notifier
code=$?

printf '\n'
if [ "$code" -eq 0 ]; then
  ok "実行しました。LINE を確認してください。"
  printf '\n  %s※ 今日の予定が1件も無い日は、あえて何も送りません（仕様）。%s\n' "$C_GRAY" "$C_RESET"
  printf '  %s※ 1日1回までしか送りません。もう一度試したいときは、%s\n' "$C_GRAY" "$C_RESET"
  printf '  %s   カレンダーに予定を入れてから明日試すか、schedule.db を消してください。%s\n' "$C_GRAY" "$C_RESET"
else
  err "失敗しました（コード $code）。上のメッセージを確認してください。"
fi
pause_exit
