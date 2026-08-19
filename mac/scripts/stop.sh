#!/bin/bash
# stop.command の本体。常駐を止める（登録は残すので 3_start でまた動く）。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

title "AI秘書 停止"

# launchd が管理しているので、Windows 版のような再起動ループ対策は要らない。
# unload すれば KeepAlive ごと止まる。
n=0
for label in "$LABEL_WEBHOOK" "$LABEL_NGROK" "$LABEL_NOTIFIER"; do
  if agent_loaded "$label"; then
    agent_unload "$label"
    ok "$label を止めました"
    n=$((n + 1))
  else
    info "$label は動いていません"
  fi
done

sleep 1
left=0
for label in "$LABEL_WEBHOOK" "$LABEL_NGROK" "$LABEL_NOTIFIER"; do
  agent_loaded "$label" && left=$((left + 1))
done

printf '\n'
if [ "$left" -eq 0 ]; then
  ok "止めました（$n 個）"
else
  warn "$left 個が残っています。もう一度 stop.command を実行してください。"
fi
printf '\n  %sもう一度動かす : 3_start.command%s\n' "$C_GRAY" "$C_RESET"
printf '  %s完全にやめる   : uninstall.command%s\n' "$C_GRAY" "$C_RESET"
pause_exit
