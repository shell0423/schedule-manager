#!/bin/bash
# status.command の本体。上から順に診断する。
# 問い合わせを受けたら、まずこの画面を送ってもらう。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

title "AI秘書 状態チェック"
printf '  %s場所: %s%s\n' "$C_GRAY" "$ROOT" "$C_RESET"

PORT="$(env_get WEBHOOK_PORT)"; [ -n "$PORT" ] || PORT=5555
DOMAIN="$(env_get NGROK_DOMAIN)"

# ---------------------------------------------------------------- 1
step "1. 設定ファイル"
if [ -f "$ENV_FILE" ]; then
  for key in LINE_CHANNEL_ACCESS_TOKEN LINE_CHANNEL_SECRET GEMINI_API_KEY NGROK_DOMAIN LINE_USER_ID; do
    v="$(env_get "$key")"
    if [ -n "$v" ]; then
      if [ "$key" = "LINE_USER_ID" ]; then
        ok "$key ($(printf '%s' "$v" | /usr/bin/cut -c1-6)…) 本人以外からの操作は拒否されます"
      else
        ok "$key ($(printf '%s' "$v" | /usr/bin/cut -c1-6)…)"
      fi
    else
      if [ "$key" = "LINE_USER_ID" ]; then
        err "$key 未設定 → ./4_set_user_id.command"
        info "・朝の通知が届きません"
        info "・さらに、この状態では【誰でも】あなたのカレンダーを操作できます。"
        info "  公式アカウントのIDを知って友だち追加した人が予定を追加・変更・削除できます。"
        info "  設定すると本人以外からのメッセージは無視されます。"
      else err "$key 未設定 → 1_setup.command"; fi
    fi
  done
else
  err ".env がありません → 1_setup.command"
fi
if [ -f "$ROOT/credentials.json" ]; then ok "credentials.json"; else err "credentials.json が無い（ガイド STEP 2）"; fi
if [ -f "$ROOT/token.json" ]; then ok "Google 許可済み（token.json）"; else err "token.json が無い → 2_google_auth.command"; fi
if have_venv; then ok "実行環境（.venv）"; else err "実行環境が無い → 1_setup.command"; fi

# ---------------------------------------------------------------- 2
step "2. Gemini API キー（実際に問い合わせて確認）"
if reason="$(check_gemini_key)"; then
  ok "使えます"
else
  err "使えません: $reason"
  show_gemini_help
fi

# ---------------------------------------------------------------- 3
step "3. 常駐の登録と稼働"
for label in "$LABEL_WEBHOOK" "$LABEL_NGROK" "$LABEL_NOTIFIER"; do
  if [ -f "$AGENT_DIR/$label.plist" ]; then
    if agent_loaded "$label"; then ok "$label（登録済み・稼働中）"; else warn "$label（登録済みだが止まっている → 3_start.command）"; fi
  else
    err "$label が未登録 → 3_start.command"
  fi
done

# plist に書かれた場所と、今このフォルダがある場所がずれていないか。
# フォルダを移動/リネームすると launchd は古い場所を見に行き、黙って失敗する。
PL="$AGENT_DIR/$LABEL_WEBHOOK.plist"
if [ -f "$PL" ]; then
  RECORDED="$(/usr/bin/plutil -extract WorkingDirectory raw -o - "$PL" 2>/dev/null)"
  if [ -n "$RECORDED" ] && [ "$RECORDED" != "$ROOT" ]; then
    err "登録されている場所と今の場所が違います。"
    info "登録: $RECORDED"
    info "現在: $ROOT"
    info "→ 3_start.command を実行すると今の場所で登録し直します"
  fi
fi

# ---------------------------------------------------------------- 4
step "4. この Mac の中から繋がるか"
# 「ポートが応答する」だけでは足りない。別のプログラムが同じポートを
# 使っていても応答してしまい、動いていないのに OK に見えてしまう。
if webhook_alive "$PORT"; then
  if agent_loaded "$LABEL_WEBHOOK"; then
    ok "http://127.0.0.1:$PORT/healthz → ok"
  else
    err "ポート $PORT は応答しますが、AI秘書は動いていません。"
    info "別のプログラムが $PORT を使っています。.env の WEBHOOK_PORT を"
    info "5556 などに変えて 3_start.command を実行し直してください。"
  fi
else
  err "繋がりません → 3_start.command"
fi

# ---------------------------------------------------------------- 5
step "5. インターネットから繋がるか"
if [ -z "$DOMAIN" ]; then
  err "NGROK_DOMAIN が未設定 → 1_setup.command"
else
  code="$(/usr/bin/curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$DOMAIN/healthz" 2>/dev/null)"
  if [ "$code" = "200" ]; then ok "https://$DOMAIN/healthz → ok"; else
    err "繋がりません（HTTP ${code:-応答なし}）"
    info "logs/ngrok.log の末尾:"
    /usr/bin/tail -3 "$LOG_DIR/ngrok.log" 2>/dev/null | /usr/bin/sed 's/^/      /'
  fi
fi

# ---------------------------------------------------------------- 6
step "6. LINE 側の設定"
TOKEN="$(env_get LINE_CHANNEL_ACCESS_TOKEN)"
if [ -z "$TOKEN" ]; then
  err "アクセストークン未設定"
else
  RES="$(/usr/bin/curl -s -m 15 "https://api.line.me/v2/bot/channel/webhook/endpoint" -H "Authorization: Bearer $TOKEN" 2>/dev/null)"
  EP="$("$VENV_PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("endpoint",""))
except Exception: print("")' <<< "$RES" 2>/dev/null)"
  AC="$("$VENV_PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("active",""))
except Exception: print("")' <<< "$RES" 2>/dev/null)"
  if [ -n "$EP" ]; then
    ok "Webhook URL: $EP"
    if [ -n "$DOMAIN" ] && [ "$EP" != "https://$DOMAIN/webhook/line" ]; then
      warn "今のドメインと違います → 3_start.command で登録し直す"
    fi
  else
    err "Webhook URL を取得できません（トークンが違う可能性）"
  fi
  case "$AC" in
    True|true) ok "Webhookの利用: オン" ;;
    *) err "Webhookの利用: オフ → LINE Developers > Messaging API > Use webhook をオン" ;;
  esac
fi

# ---------------------------------------------------------------- 7
step "7. 毎朝8時の通知"
if [ -f "$AGENT_DIR/$LABEL_NOTIFIER.plist" ]; then
  H="$(/usr/bin/plutil -extract StartCalendarInterval.Hour raw -o - "$AGENT_DIR/$LABEL_NOTIFIER.plist" 2>/dev/null)"
  ok "登録済み（毎日 ${H:-8}:00）"
  if [ -z "$(env_get LINE_USER_ID)" ]; then warn "ただし宛先が未設定 → 4_set_user_id.command"; fi
else
  err "未登録 → 3_start.command"
fi

# ---------------------------------------------------------------- 8
step "8. 最近のログ（末尾10行）"
if [ -f "$LOG_DIR/webhook.err.log" ]; then
  /usr/bin/tail -10 "$LOG_DIR/webhook.err.log" | /usr/bin/sed 's/^/      /'
else
  info "まだログがありません"
fi

printf '\n'
printf '  %s困ったときは、この画面をそのまま送ってください。%s\n' "$C_GRAY" "$C_RESET"
pause_exit
