#!/bin/bash
# 1_setup.command の本体。実行環境と設定を用意する。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

title "AI秘書 セットアップ（1/4）"

# ---------------------------------------------------------------- 自己修復
# ネットから落とした ZIP は Gatekeeper の隔離属性が付き、実行権も落ちることがある。
# 最初の1本さえ起動できれば、残りはここで直せる。
step "ファイルの実行準備をしています"
/usr/bin/xattr -dr com.apple.quarantine "$ROOT" 2>/dev/null || true
/bin/chmod +x "$ROOT"/*.command "$ROOT"/scripts/*.sh 2>/dev/null || true
ok "実行できるようにしました"

# ---------------------------------------------------------------- Python
step "Python を探しています"

# バージョン選びは「新しい順」ではない。実績のある 3.11〜3.13 を最優先し、
# 出たばかりの 3.14 系や、macOS 標準の 3.9 はその後に回す。
# （3.14 系は Homebrew 版で ensurepip を持たず venv を作れないことがあり、
#   Google のライブラリもホイールが揃っていないことがある。実際に踏んだ）
py_score() {
  "$1" -c 'import sys
a, b = sys.version_info[:2]
if a != 3: print(0)
elif 11 <= b <= 13: print(300 + b)   # 本命
elif b == 10:       print(200)
elif b >= 14:       print(100 + b)   # 新しすぎる
elif b == 9:        print(50)        # macOS 標準。動くが警告が出る
else:               print(0)' 2>/dev/null
}
py_version_str() { "$1" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null; }

# 候補を「得点 実体パス」の行にして、得点の高い順に並べる
CAND_FILE="$(/usr/bin/mktemp)"
for cand in \
  /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 \
  /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3 \
  /usr/local/bin/python3.13 /usr/local/bin/python3.12 /usr/local/bin/python3.11 /usr/local/bin/python3 \
  /Library/Frameworks/Python.framework/Versions/Current/bin/python3 \
  "$(command -v python3 2>/dev/null)" /usr/bin/python3
do
  [ -n "$cand" ] || continue
  [ -x "$cand" ] || continue
  sc="$(py_score "$cand")"
  [ -n "$sc" ] || continue
  [ "$sc" -gt 0 ] 2>/dev/null || continue
  # 同じ実体を二重に試さない
  real="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"
  printf '%s %s\n' "$sc" "$real" >> "$CAND_FILE"
done

if [ ! -s "$CAND_FILE" ]; then
  /bin/rm -f "$CAND_FILE"
  err "使える Python（3.9 以上）が見つかりませんでした。"
  printf '    次のどちらかで用意してください:\n'
  printf '      A) ターミナルで  xcode-select --install  を実行（Apple 純正・画面の指示に従うだけ）\n'
  printf '      B) https://www.python.org/downloads/macos/ から最新版をダウンロードして実行\n'
  printf '    入れ終わったら、もう一度 1_setup.command を実行してください。\n'
  pause_exit; exit 1
fi

# ---------------------------------------------------------------- 仮想環境
step "専用の実行環境（.venv）を作っています"
if have_venv && "$VENV_PY" -m pip --version >/dev/null 2>&1; then
  ok "すでにあります（$("$VENV_PY" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)）"
else
  # 候補を上から試し、venv が作れて pip が動くものを採用する。
  # 「見つかった＝使える」ではないので、必ず実際に作って確かめる。
  /bin/rm -rf "$ROOT/.venv"
  PYTHON=""
  while read -r sc path; do
    [ -n "$path" ] || continue
    info "試しています: $path ($(py_version_str "$path"))"
    if "$path" -m venv "$ROOT/.venv" >/dev/null 2>&1 && "$VENV_PY" -m pip --version >/dev/null 2>&1; then
      PYTHON="$path"
      break
    fi
    warn "この Python では実行環境を作れませんでした。次を試します。"
    /bin/rm -rf "$ROOT/.venv"
  done < <(/usr/bin/sort -rn "$CAND_FILE" | /usr/bin/awk '!seen[$2]++')
  /bin/rm -f "$CAND_FILE"

  if [ -z "$PYTHON" ]; then
    err "どの Python でも実行環境を作れませんでした。"
    printf '    https://www.python.org/downloads/macos/ から最新版を入れて、\n'
    printf '    もう一度 1_setup.command を実行してください。\n'
    pause_exit; exit 1
  fi
  ok "Python $(py_version_str "$PYTHON") ($PYTHON)"
  case "$("$VENV_PY" -c 'import sys;print(sys.version_info[1])' 2>/dev/null)" in
    9) info "macOS 標準の Python です。動作しますが、Google のライブラリが警告を出すことがあります（無視して構いません）" ;;
  esac
fi
/bin/rm -f "$CAND_FILE" 2>/dev/null || true

step "必要なパッケージを入れています（初回は数分かかります）"
"$VENV_PY" -m pip install --quiet --disable-pip-version-check --upgrade pip 2>/dev/null || true
if "$VENV_PY" -m pip install --quiet --disable-pip-version-check -r "$ROOT/requirements.txt"; then
  ok "入りました"
else
  err "パッケージを入れられませんでした。ネット接続を確認してもう一度実行してください。"
  pause_exit; exit 1
fi

# ---------------------------------------------------------------- ngrok
step "ngrok（外からこの Mac に繋ぐ道具）を用意しています"
NGROK="$(ngrok_bin || true)"
if [ -z "$NGROK" ]; then
  case "$(/usr/bin/uname -m)" in
    arm64) NG_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-arm64.zip" ;;
    *)     NG_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-amd64.zip" ;;
  esac
  info "ダウンロード中: $NG_URL"
  TMPZIP="$(/usr/bin/mktemp -t ngrok-ai-hisho).zip"
  if /usr/bin/curl -fsSL -m 180 -o "$TMPZIP" "$NG_URL"; then
    /bin/mkdir -p "$ROOT/bin"
    /usr/bin/unzip -o -q "$TMPZIP" -d "$ROOT/bin" && /bin/chmod +x "$ROOT/bin/ngrok" 2>/dev/null
    /usr/bin/xattr -dr com.apple.quarantine "$ROOT/bin" 2>/dev/null || true
    /bin/rm -f "$TMPZIP"
    NGROK="$(ngrok_bin || true)"
  else
    warn "自動ダウンロードに失敗しました。"
  fi
fi
if [ -z "$NGROK" ]; then
  err "ngrok を用意できませんでした。"
  printf '    https://ngrok.com/download から macOS 版を落とし、中の ngrok を\n'
  printf '      %s/bin/ngrok\n' "$ROOT"
  printf '    に置いてから、もう一度実行してください。\n'
  pause_exit; exit 1
fi
ok "ngrok: $NGROK"

# ---------------------------------------------------------------- 設定値
step "鍵と設定を入力します"
info "ガイド（0_START_HERE.html）の STEP 1〜4 で控えた値を貼り付けてください。"
info "すでに入っている値は、そのまま Enter を押せば変わりません。"

# 既定値（未設定のときだけ入れる）
for pair in \
  "GEMINI_MODEL=gemini-2.5-flash" \
  "GOOGLE_CALENDAR_ID=primary" \
  "GOOGLE_CREDENTIALS_PATH=credentials.json" \
  "GOOGLE_TOKEN_PATH=token.json" \
  "WEBHOOK_HOST=127.0.0.1" \
  "WEBHOOK_PORT=5555" \
  "VERIFY_SIGNATURE=true"
do
  k="${pair%%=*}"; v="${pair#*=}"
  [ -n "$(env_get "$k")" ] || env_set "$k" "$v"
done

# 対話入力。$3 は補足説明。
read_setting() {
  local key="$1" label="$2" hint="$3" cur shown input
  cur="$(env_get "$key")"
  printf '\n  %s%s%s\n' "$C_CYAN" "$label" "$C_RESET"
  [ -n "$hint" ] && printf '    %s%s%s\n' "$C_GRAY" "$hint" "$C_RESET"
  if [ -n "$cur" ]; then
    # 鍵をそのまま出さない。先頭6文字だけ見せて本人が判別できるようにする。
    shown="$(printf '%s' "$cur" | /usr/bin/cut -c1-6)"
    printf '    今の値: %s… （Enter でこのまま）\n' "$shown"
  fi
  printf '    入力: '
  read -r input || input=""
  if [ -n "$input" ]; then
    # 前後の空白と、貼り付け時に混ざりがちな引用符を落とす
    input="$(printf '%s' "$input" | /usr/bin/sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')"
    env_set "$key" "$input"
  fi
}

read_setting LINE_CHANNEL_ACCESS_TOKEN "LINE のチャネルアクセストークン" \
  "LINE Developers > Messaging API タブ > 一番下（とても長い文字列）"
read_setting LINE_CHANNEL_SECRET "LINE のチャネルシークレット" \
  "LINE Developers > チャネル基本設定タブ"
read_setting GEMINI_API_KEY "Gemini API キー" \
  "Google AI Studio (https://aistudio.google.com/apikey) で取得"
read_setting NGROK_DOMAIN "ngrok の固定ドメイン" \
  "例: happy-cat-1234.ngrok-free.dev（https:// や / は付けない）"
read_setting NGROK_AUTHTOKEN "ngrok の Authtoken" \
  "ngrok ダッシュボード > Your Authtoken"

# ドメインに https:// を付けて貼られがちなので直す
dom="$(env_get NGROK_DOMAIN)"
clean="$(printf '%s' "$dom" | /usr/bin/sed 's#^https\{0,1\}://##; s#/.*$##')"
if [ "$dom" != "$clean" ]; then
  env_set NGROK_DOMAIN "$clean"
  info "ドメインを $clean に直しました"
fi

# ---------------------------------------------------------------- Gemini 疎通
if [ -z "$(env_get GEMINI_API_KEY)" ]; then
  step "Gemini API キーの確認はとばします（未入力）"
else
  step "Gemini API キーが本当に使えるか試しています"
  if reason="$(check_gemini_key)"; then
    ok "使えます"
  else
    err "このキーでは応答がありませんでした: $reason"
    show_gemini_help
    warn "先に進めますが、直すまで LINE に送っても解析できません。"
  fi
fi

# ---------------------------------------------------------------- ngrok 認証
step "ngrok にログインします"
NG_TOKEN="$(env_get NGROK_AUTHTOKEN)"
if [ -z "$NG_TOKEN" ]; then
  warn "Authtoken が未入力です。3_start.command の前に入れ直してください。"
else
  if "$NGROK" config add-authtoken "$NG_TOKEN" >/dev/null 2>&1; then
    ok "ログインしました"
  else
    warn "ログインできませんでした。Authtoken を確認してください。"
  fi
fi

# ---------------------------------------------------------------- 仕上げ
step "残りの確認"
if [ -f "$ROOT/credentials.json" ]; then
  ok "credentials.json があります"
else
  warn "credentials.json がまだありません。"
  info "ガイド STEP 2 でダウンロードし、次の場所に置いてください（名前も credentials.json に）:"
  info "  $ROOT/credentials.json"
fi
/bin/mkdir -p "$LOG_DIR"

printf '\n'
title "1/4 完了"
printf '  次は %s2_google_auth.command%s をダブルクリックしてください。\n' "$C_GREEN" "$C_RESET"
pause_exit
