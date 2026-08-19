#!/bin/bash
# 4_set_user_id.command の本体。受信ログから自分の userId を拾って .env に書く。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

title "朝の通知の宛先を設定（4/4）"

LOG="$LOG_DIR/webhook.err.log"
# 受信ログは Flask のログ出力（標準エラー）側に出る。念のため両方見る。
UID_FOUND=""
for f in "$LOG" "$LOG_DIR/webhook.log"; do
  [ -f "$f" ] || continue
  UID_FOUND="$(/usr/bin/grep -o 'userId=U[0-9a-f]\{32\}' "$f" 2>/dev/null | /usr/bin/tail -1 | /usr/bin/sed 's/^userId=//')"
  [ -n "$UID_FOUND" ] && break
done

if [ -z "$UID_FOUND" ]; then
  err "あなたの userId をログから見つけられませんでした。"
  printf '    先に LINE で AI秘書 に何か1通送ってから、もう一度実行してください。\n'
  printf '    （送っても見つからないときは status.command で状態を確認）\n'
  pause_exit; exit 1
fi

env_set LINE_USER_ID "$UID_FOUND"
ok "宛先を設定しました（$(printf '%s' "$UID_FOUND" | /usr/bin/cut -c1-8)…）"

step "設定を読み直しています"
agent_unload "$LABEL_WEBHOOK"
sleep 1
if /bin/launchctl load "$AGENT_DIR/$LABEL_WEBHOOK.plist" 2>/dev/null; then
  sleep 2
  if webhook_alive "$(env_get WEBHOOK_PORT)"; then ok "動いています"; else warn "起動を確認できませんでした → status.command"; fi
else
  warn "読み直せませんでした → 3_start.command を実行してください"
fi

printf '\n'
title "4/4 完了"
printf '  毎朝8時に、その日の予定が LINE に届きます。\n'
printf '  今すぐ試すなら %stest_notify.command%s\n' "$C_GREEN" "$C_RESET"
pause_exit
