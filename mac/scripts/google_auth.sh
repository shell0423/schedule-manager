#!/bin/bash
# 2_google_auth.command の本体。ブラウザで Google の許可を取り token.json を作る。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

title "Google カレンダーの許可（2/4）"
require_venv || { pause_exit; exit 1; }

if [ ! -f "$ROOT/credentials.json" ]; then
  err "credentials.json がありません。"
  info "ガイド STEP 2 でダウンロードし、次の場所に置いてください（名前も credentials.json に）:"
  info "  $ROOT/credentials.json"
  pause_exit; exit 1
fi

printf '\n  これからブラウザが開きます。次の順に進めてください:\n'
printf '    1. 自分の Google アカウントを選ぶ\n'
printf '    2.『このアプリは Google で確認されていません』と出たら\n'
printf '       → 左下【詳細】→【（アプリ名）に移動】をクリック\n'
printf '    3.『カレンダーの予定の表示と編集』にチェック →【続行】\n\n'
printf '  %s※ 自分で作ったアプリなので、この警告が出るのが正常です。%s\n\n' "$C_GRAY" "$C_RESET"
printf '  準備ができたら Enter: '
read -r _ || true

cd "$ROOT" || exit 1
"$VENV_PY" -m src.calendar_client
code=$?

printf '\n'
if [ "$code" -eq 0 ] && [ -f "$ROOT/token.json" ]; then
  /bin/chmod 600 "$ROOT/token.json" 2>/dev/null || true
  ok "許可が取れました（token.json を作成）"
  printf '\n  2/4 完了。次は %s3_start.command%s\n' "$C_GREEN" "$C_RESET"
else
  err "許可に失敗しました。"
  printf '    よくある原因:\n'
  printf '      ・Google Cloud で Calendar API を有効にしていない（ガイド STEP 2-2）\n'
  printf '      ・OAuth の公開ステータスが【テスト】のまま（ガイド STEP 2-3）\n'
  printf '      ・5分以内にブラウザで許可しなかった（もう一度実行してください）\n'
fi
pause_exit
