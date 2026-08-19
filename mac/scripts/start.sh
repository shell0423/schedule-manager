#!/bin/bash
# 3_start.command の本体。常駐登録して起動し、LINE 側の Webhook URL まで設定する。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

title "AI秘書 起動（3/4）"

# ---------------------------------------------------------------- 事前チェック
step "準備ができているか確認しています"
require_venv || { pause_exit; exit 1; }

NG=0
for key in LINE_CHANNEL_ACCESS_TOKEN LINE_CHANNEL_SECRET GEMINI_API_KEY NGROK_DOMAIN; do
  if [ -z "$(env_get "$key")" ]; then err "$key が未設定です → 1_setup.command"; NG=1; fi
done
if [ ! -f "$ROOT/token.json" ]; then
  err "Google の許可がまだです → 先に 2_google_auth.command"
  NG=1
fi
NGROK="$(ngrok_bin || true)"
if [ -z "$NGROK" ]; then err "ngrok がありません → 1_setup.command"; NG=1; fi
[ "$NG" -eq 0 ] || { pause_exit; exit 1; }
ok "そろっています"

PORT="$(env_get WEBHOOK_PORT)"; [ -n "$PORT" ] || PORT=5555
DOMAIN="$(env_get NGROK_DOMAIN)"

# 起動前にポートの取り合いを見ておく。ここで気づかないと、launchd が
# 「起動→即終了」を繰り返し、ログを見ないと原因が分からない状態になる。
if webhook_alive "$PORT" && ! agent_loaded "$LABEL_WEBHOOK"; then
  err "ポート $PORT を別のプログラムが使っています。"
  info ".env の WEBHOOK_PORT を 5556 などに変えてから、もう一度実行してください。"
  info "（このファイルを開くには status.command と同じフォルダの .env をテキストエディタで）"
  pause_exit; exit 1
fi

# ---------------------------------------------------------------- 既存を停止
step "動いているものをいったん止めます"
for label in "$LABEL_WEBHOOK" "$LABEL_NGROK" "$LABEL_NOTIFIER"; do agent_unload "$label"; done
sleep 1
ok "止めました"

# ---------------------------------------------------------------- 常駐登録
step "ログイン時に自動で立ち上がるよう登録しています"
# plist は展開場所に合わせて毎回作り直す（フォルダを移動しても 3_start で直る）
if ! AIH_ROOT="$ROOT" AIH_NGROK="$NGROK" AIH_PORT="$PORT" AIH_DOMAIN="$DOMAIN" \
     "$VENV_PY" "$ROOT/scripts/make_plists.py" >/dev/null; then
  err "登録ファイル（plist）を作れませんでした。"
  pause_exit; exit 1
fi
ok "登録ファイルを作りました（$AGENT_DIR）"

step "起動しています"
LOAD_NG=0
for label in "$LABEL_WEBHOOK" "$LABEL_NGROK" "$LABEL_NOTIFIER"; do
  if /bin/launchctl load "$AGENT_DIR/$label.plist" 2>/dev/null; then
    ok "$label"
  else
    err "$label を起動できませんでした"
    LOAD_NG=1
  fi
done

# ---------------------------------------------------------------- 疎通確認
step "この Mac の中から繋がるか確認しています"
ALIVE=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  if webhook_alive "$PORT"; then ALIVE=1; break; fi
  sleep 1
done
if [ "$ALIVE" -eq 1 ]; then
  ok "動いています（ポート $PORT）"
else
  err "起動を確認できませんでした。"
  info "logs/webhook.err.log の末尾を見てください:"
  /usr/bin/tail -5 "$LOG_DIR/webhook.err.log" 2>/dev/null | /usr/bin/sed 's/^/      /'
  pause_exit; exit 1
fi

step "インターネットから繋がるか確認しています"
EXT=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  code="$(/usr/bin/curl -s -m 8 -o /dev/null -w '%{http_code}' "https://$DOMAIN/healthz" 2>/dev/null)"
  if [ "$code" = "200" ]; then EXT=1; break; fi
  sleep 2
done
if [ "$EXT" -eq 1 ]; then
  ok "外から繋がります（https://$DOMAIN）"
else
  warn "外から繋がりません。logs/ngrok.log の末尾を確認してください:"
  /usr/bin/tail -5 "$LOG_DIR/ngrok.log" 2>/dev/null | /usr/bin/sed 's/^/      /'
fi

# ---------------------------------------------------------------- LINE 側の設定
step "LINE に「ここに送って」と伝えています"
ENDPOINT="https://$DOMAIN/webhook/line"
TOKEN="$(env_get LINE_CHANNEL_ACCESS_TOKEN)"

line_api() {
  # $1=method $2=path [$3=body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    /usr/bin/curl -s -m 20 -X "$method" "https://api.line.me/v2/bot/$path" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$body"
  else
    /usr/bin/curl -s -m 20 -X "$method" "https://api.line.me/v2/bot/$path" \
      -H "Authorization: Bearer $TOKEN"
  fi
}

# JSON の取り出しは python に任せる（jq は macOS に無いことがある）
json_get() { "$VENV_PY" -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1], ""))
except Exception: print("")' "$1" 2>/dev/null; }

# URL をシェルで JSON に埋めると引用符の扱いを間違えやすいので python に組ませる
export AIH_ENDPOINT="$ENDPOINT"
BODY="$("$VENV_PY" -c 'import json,os;print(json.dumps({"endpoint":os.environ["AIH_ENDPOINT"]}))')"

if line_api PUT "channel/webhook/endpoint" "$BODY" >/dev/null 2>&1; then
  ok "Webhook URL を登録しました: $ENDPOINT"
  ACTIVE="$(line_api GET "channel/webhook/endpoint" | json_get active)"
  if [ "$ACTIVE" = "True" ] || [ "$ACTIVE" = "true" ]; then
    ok "LINE 側の Webhook はオンです"
  else
    warn "LINE 側の『Webhookの利用』がオフです。ここだけ手作業が要ります:"
    printf '      LINE Developers > チャネル > Messaging API タブ\n'
    printf '      > Webhook settings > 【Use webhook】をオンにする\n'
  fi
  TEST="$(line_api POST "channel/webhook/test" "$BODY")"
  if [ "$(printf '%s' "$TEST" | json_get success)" = "True" ]; then
    ok "LINE からの疎通テスト成功"
  else
    warn "疎通テスト: $(printf '%s' "$TEST" | json_get reason)"
  fi
else
  warn "自動登録できませんでした。"
  printf '      LINE Developers の Messaging API タブで、Webhook URL に\n'
  printf '      %s\n' "$ENDPOINT"
  printf '      を手で貼り付け、【Use webhook】をオンにしてください。\n'
fi

# ---------------------------------------------------------------- 仕上げ
printf '\n'
if [ "$LOAD_NG" -eq 0 ]; then title "起動しました"; else title "一部だけ起動しました"; fi
printf '  LINE で AI秘書 に「明日10時にテスト」と送ってみてください。\n\n'
if [ -z "$(env_get LINE_USER_ID)" ]; then
  printf '  1通送ったあと %s4_set_user_id.command%s を実行すると、\n' "$C_GREEN" "$C_RESET"
  printf '  毎朝8時の通知も届くようになります。\n\n'
fi
printf '  %s状態を見る : status.command%s\n' "$C_GRAY" "$C_RESET"
printf '  %s止める     : stop.command%s\n' "$C_GRAY" "$C_RESET"
pause_exit
