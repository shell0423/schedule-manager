#!/bin/bash
# uninstall.command の本体。自動起動をやめる。
# フォルダの中身（.env・token.json・ログ）は消さない。3_start.command でいつでも戻せる。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

title "自動起動の解除"

printf '  ログイン時の自動起動と、毎朝8時の通知をやめます。\n'
printf '  %s設定ファイル(.env)・Google の許可(token.json)・ログは残します。%s\n' "$C_GRAY" "$C_RESET"
printf '  %sフォルダごと消したいときは、この作業のあとフォルダをゴミ箱へ入れてください。%s\n\n' "$C_GRAY" "$C_RESET"
printf '  続けますか？ [y/N]: '
read -r ans || ans=""
case "$ans" in
  y|Y) ;;
  *) printf '\n  やめました。\n'; pause_exit; exit 0 ;;
esac

for label in "$LABEL_WEBHOOK" "$LABEL_NGROK" "$LABEL_NOTIFIER"; do
  agent_unload "$label"
  if [ -f "$AGENT_DIR/$label.plist" ]; then
    /bin/rm -f "$AGENT_DIR/$label.plist"
    ok "$label を解除しました"
  else
    info "$label は登録されていません"
  fi
done

printf '\n'
title "解除しました"
printf '  また使いたくなったら %s3_start.command%s を実行してください。\n' "$C_GREEN" "$C_RESET"
pause_exit
