#!/bin/bash
# 共通ヘルパー。各 *.sh から source で読み込む。
#
# macOS 標準の bash は 3.2（2007年）なので、それに合わせて書くこと。
#   - 連想配列（declare -A）は使えない
#   - ${var^^} などの新しい展開も使えない
# zsh ではなく #!/bin/bash を明示する（zsh 依存の書き方を混ぜないため）。

set -uo pipefail

# scripts/ の親 = プロジェクトルート。展開先がどこでも動くよう自分の位置から求める。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VENV_PY="$ROOT/.venv/bin/python"
ENV_FILE="$ROOT/.env"
LOG_DIR="$ROOT/logs"

# LaunchAgent のラベル。作者本人の com.niki.schedule.* とぶつからない名前にする
# （同じ Mac で両方動かしても衝突しないように）。
LABEL_WEBHOOK="com.ai-hisho.webhook"
LABEL_NGROK="com.ai-hisho.ngrok"
LABEL_NOTIFIER="com.ai-hisho.notifier"
AGENT_DIR="$HOME/Library/LaunchAgents"

# ---------------------------------------------------------------- 画面出力
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_GRAY=$'\033[90m'
else
  C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""
fi

step() { printf '\n%s== %s%s\n' "$C_CYAN" "$1" "$C_RESET"; }
ok()   { printf '  %sOK%s   %s\n' "$C_GREEN" "$C_RESET" "$1"; }
info() { printf '       %s%s%s\n' "$C_GRAY" "$1" "$C_RESET"; }
warn() { printf '  %s注意%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
err()  { printf '  %s失敗%s %s\n' "$C_RED" "$C_RESET" "$1"; }

title() {
  printf '\n%s==================================================%s\n' "$C_CYAN" "$C_RESET"
  printf '%s  %s%s\n' "$C_CYAN" "$1" "$C_RESET"
  printf '%s==================================================%s\n' "$C_CYAN" "$C_RESET"
}

# 終了時に「ウィンドウが即閉じて何も読めない」を防ぐ。.command から呼ばれる前提。
pause_exit() {
  printf '\n%sこのウィンドウは閉じて構いません。%s\n' "$C_GRAY" "$C_RESET"
  printf 'Enter で閉じます: '
  read -r _ || true
}

# ---------------------------------------------------------------- .env
# 値に = が含まれても壊れないよう、最初の = だけで分割する。
env_get() {
  [ -f "$ENV_FILE" ] || { printf ''; return 0; }
  /usr/bin/awk -v key="$1" '
    /^[[:space:]]*#/ { next }
    {
      i = index($0, "=")
      if (i < 2) next
      k = substr($0, 1, i - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == key) {
        v = substr($0, i + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        print v
        exit
      }
    }' "$ENV_FILE"
}

# キーがあれば置換、無ければ追記。値に / や & が入っても壊れないよう awk で組む。
env_set() {
  local key="$1" value="$2" tmp
  tmp="$(/usr/bin/mktemp)"
  if [ -f "$ENV_FILE" ]; then
    /usr/bin/awk -v key="$key" -v value="$value" '
      BEGIN { done = 0 }
      {
        i = index($0, "=")
        if (i > 1 && $0 !~ /^[[:space:]]*#/) {
          k = substr($0, 1, i - 1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
          if (k == key) { print key "=" value; done = 1; next }
        }
        print
      }
      END { if (!done) print key "=" value }' "$ENV_FILE" > "$tmp"
  else
    printf '# AI秘書 設定ファイル。他人に見せないこと。\n%s=%s\n' "$key" "$value" > "$tmp"
  fi
  /bin/mv "$tmp" "$ENV_FILE"
  /bin/chmod 600 "$ENV_FILE"
}

# ---------------------------------------------------------------- 実行環境
have_venv() { [ -x "$VENV_PY" ]; }

require_venv() {
  if ! have_venv; then
    err "実行環境がありません。先に 1_setup.command を実行してください。"
    return 1
  fi
  return 0
}

# 同梱 bin/ を優先し、無ければ PATH（Homebrew 等）を探す
ngrok_bin() {
  if [ -x "$ROOT/bin/ngrok" ]; then
    printf '%s' "$ROOT/bin/ngrok"
    return 0
  fi
  local p
  p="$(command -v ngrok 2>/dev/null)"
  if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
  return 1
}

webhook_alive() {
  local port="${1:-5555}"
  /usr/bin/curl -s -m 5 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${port}/healthz" 2>/dev/null | /usr/bin/grep -q '^200$'
}

# LaunchAgent が読み込まれているか（launchctl list にラベルがあるか）
agent_loaded() { /bin/launchctl list 2>/dev/null | /usr/bin/grep -q "[[:space:]]$1\$"; }

# 読み込まれていれば外す。plist が無い場合も静かに成功させる。
agent_unload() {
  local label="$1" plist="$AGENT_DIR/$1.plist"
  if agent_loaded "$label"; then
    /bin/launchctl unload "$plist" 2>/dev/null || true
  fi
}

# Gemini キーが実際に使えるか。0=OK、1=NG（理由を標準出力に出す）
check_gemini_key() {
  local key model out
  key="$(env_get GEMINI_API_KEY)"
  model="$(env_get GEMINI_MODEL)"
  [ -n "$model" ] || model="gemini-2.5-flash"
  if [ -z "$key" ]; then printf '鍵が未設定です'; return 1; fi
  have_venv || { printf '実行環境がありません（先に 1_setup.command）'; return 1; }
  # 鍵は引数ではなく環境変数で渡す（ps でプロセス一覧に出さないため）
  out="$(GEMINI_API_KEY="$key" GEMINI_MODEL="$model" \
        "$VENV_PY" "$ROOT/scripts/check_gemini.py" 2>&1)"
  case "$out" in
    *GEMINI_OK*) return 0 ;;
    *) printf '%s' "$(printf '%s' "$out" | /usr/bin/sed 's/^GEMINI_NG[[:space:]]*//' | /usr/bin/tail -1)"; return 1 ;;
  esac
}

show_gemini_help() {
  printf '    考えられる原因と対処:\n'
  printf '      ・キーの貼り付けミス（途中で切れている）→ 1_setup.command で入れ直す\n'
  printf '      ・キーが AQ. で始まる新形式で、まだ対応していない環境がある\n'
  printf '        → 従来形式(AIza...)の鍵を作り直すと通ることが多い:\n'
  printf '           1. https://console.cloud.google.com/ を開く\n'
  printf '           2. APIとサービス > ライブラリ > Generative Language API を有効にする\n'
  printf '           3. APIとサービス > 認証情報 > + 認証情報を作成 > APIキー\n'
  printf '           4. 出てきた AIza... を 1_setup.command で入れ直す\n'
  printf '      ・無料枠を使い切っている（429 / RESOURCE_EXHAUSTED）→ 時間をおく\n'
}
