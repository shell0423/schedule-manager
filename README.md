# スケジュール管理

LINE 公式アカウント「AI秘書」に自由文を送ると、Gemini が解析して Google カレンダーに登録・変更・削除する。毎朝8時に当日の予定、月曜は今週分も LINE に通知する。

> **人に渡す**: Windows 用は `windows/` ＋ `build_windows_zip.py`、Mac 用は `mac/` ＋ `build_mac_zip.py`。
> 相手が Claude Code も Python も持っていない前提で、ZIP を展開して4つ叩けば動く。
> 詳細は `windows/README.md` / `mac/README.md`。
> Mac に自分で一から作り直す手順は `はじめて作る人へ.md`。

## 技術スタック
- Python 3.11（Flask）
- LINE Messaging API
- Google Calendar API
- Gemini API（`gemini-2.5-flash` / `google-genai` SDK）
- SQLite（通知状態管理）
- ngrok（Mac の外部公開・dev domain 固定）
- macOS LaunchAgent（常駐 + 定時実行）

## 構成（実稼働）

```
LINE「AI秘書」(@<公式アカウントID>)
  └─ Webhook URL: https://<ngrokの固定ドメイン>/webhook/line
       └─ ngrok（LaunchAgent 常駐, dev domain 固定）
            └─ Mac localhost:5555 Flask（LaunchAgent 常駐）
                 ├─ Gemini で自由文解析
                 ├─ Google Calendar API で登録/更新/削除
                 └─ SQLite に通知状態記録

毎朝 8:00 LaunchAgent → notifier.py
  └─ Calendar から当日/今週分を取得 → LINE Push
```

## LaunchAgent 3点

| ラベル | plist | 役割 | 起動 |
|---|---|---|---|
| `com.niki.schedule.webhook` | com.niki.schedule.webhook.plist | Flask（Webhook受信） | 常駐（KeepAlive） |
| `com.niki.schedule.ngrok` | com.niki.schedule.ngrok.plist | ngrok トンネル | 常駐（KeepAlive） |
| `com.niki.schedule.notifier` | com.niki.schedule.notifier.plist | 朝の通知バッチ | 毎日 08:00 |

## 設定済みの値（`.env`）
- `LINE_CHANNEL_ACCESS_TOKEN` / `LINE_CHANNEL_SECRET`：AI秘書チャネル
- `LINE_USER_ID`：通知先（シェル本人）
- `GEMINI_API_KEY` / `GEMINI_MODEL=gemini-2.5-flash`
- `GOOGLE_CALENDAR_ID=primary`（`credentials.json` + `token.json` で認証）

## 使い方

LINE「AI秘書」に自由文を送るだけ。

| 入力例 | 動作 |
|---|---|
| `今日14時から会議` | Calendar に作成 |
| `明日の10時に歯医者` | 作成 |
| `来週金曜18時に会食、場所は丸の内` | 作成（場所は description） |
| `4/25 Aさんにメール` | 作成（時刻なし→9:00） |
| `今週の予定は？` | 今週分を返信 |
| `明日の予定教えて` | 明日分を返信 |
| `8月の予定は？` | その月の全予定を返信（`月`／`今月`／`来月`に対応） |
| `4/24の打ち合わせを16時に変更` | 更新 |
| `12/4 13:30の展示会を12/4〜12/5に変更` | 時刻あり→終日・期間予定への変更（逆方向も可） |
| `金曜の会食キャンセル` | 削除 |

## 通知タイミング
- **月曜 08:00**：今週（月〜日）の全予定を Push
- **毎朝 08:00**：当日の予定を Push（予定ゼロなら送らない）

## 予定の表示形式

通知・一覧とも `format_range_label()`（`src/notifier.py`）で整形する。複数日にまたがる予定は両端を出す。

| 予定 | 表示 |
|---|---|
| 時刻あり・単日 | `8/10(月) 13:30 管理者会議` |
| 時刻あり・複数日 | `12/4(金) 13:30〜12/5(土) 10:00 合宿` |
| 終日・単日 | `8/11(火) 終日 夏季休暇` |
| 終日・期間 | `8/11(火)〜8/16(日) 終日 夏季休暇` |

> Google Calendar の終日予定の `end` は **exclusive**（最終日の翌日）。API とやり取りする境界（`calendar_client._apply_period` / `main._handle_update`）で「含む最終日」に変換しており、`format_range_label` は常に**含む最終日**を受け取る。

## コスト確認（Gemini API の利用額）

いくら使ったかは下記ページで確認できる：

- **Gemini API 利用額・支出上限**: https://ai.studio/spend
  - Project は `Gemini Project` を選択
  - 「1か月の費用の上限」で現在の使用額 / 上限（例: `¥3 / ¥1000`）が見られる
  - 上限は「費用の上限を編集」から変更可。毎月1日（太平洋標準時）にリセット
  - 利用額の反映には最長24時間かかることがある

> `gemini-2.5-flash` は 1回の解析 ≈ 0.03円。個人利用なら月数十円程度に収まる。

## 運用コマンド

```bash
cd ~/Claude/スケジュール管理

# 状態確認
launchctl list | grep niki.schedule
curl -s http://localhost:5555/healthz                              # Flask ローカル
curl -s https://<ngrokの固定ドメイン>/healthz     # 外部経由

# ログ
tail -f logs/webhook.log
tail -f logs/ngrok.log
tail -f logs/notifier.log

# 再起動（コード変更後など）
launchctl unload ~/Library/LaunchAgents/com.niki.schedule.webhook.plist
launchctl load   ~/Library/LaunchAgents/com.niki.schedule.webhook.plist

# 通知を今すぐ手動実行（動作確認）
.venv/bin/python -m src.notifier

# テスト・静的解析
.venv/bin/pytest
.venv/bin/ruff check src tests
.venv/bin/mypy src
```

## 既知の制約・注意

> **「使えないケース」の一覧は `使えないケース.md` が正本**（届かない条件／入らない条件／
> 仕様上できないこと）。「LINEに送ったのに入っていない」ときはまずそちらを見る。
> 以下はこのファイル固有の運用メモ。


- **Mac がスリープ/電源オフの間は Webhook を受けられない**。LINE は失敗した Webhook を再送しないため、その間に送ったメッセージは取りこぼす。常用するなら以下でスリープ抑止：
  ```bash
  sudo pmset -a sleep 0          # システムスリープ無効（電源接続時）
  # または一時的に: caffeinate -s
  ```
  通知（毎朝8時）は、スリープ中に時刻を過ぎても**復帰時に launchd がまとめて実行**するため比較的取りこぼしにくい。
  ただし復帰直後はまだ DNS が引けないことがあるため、`notifier.py` は一時的なネットワーク断を
  **30秒間隔で最大5回リトライ**する（`NETWORK_RETRIES` / `NETWORK_RETRY_WAIT_SEC`）。
  週次と日次は独立して実行し、**片方が失敗してももう片方は送る**（2026-08-17 に週次の DNS 失敗が
  日次まで巻き添えにして通知ゼロになった事故の対策）。認証切れなど恒久的な失敗はリトライせず即座に諦める。
- **ngrok dev domain `<ngrokの固定ドメイン>`** は ngrok アカウント `<ngrokアカウントのメール>` のもの。authtoken はこのアカウントで Mac に設定済み。別アカウント（<別アカウント>）の domain は使えない。
- 無料 dev domain は再起動しても変わらないので、LINE 側 Webhook URL の再設定は不要。
- `credentials.json` / `token.json` / `.env` / `schedule.db` はコミット禁止（`.gitignore` 済み）。
- `token.json` が失効したら `.venv/bin/python -m src.calendar_client` で再認証（ブラウザが開く）。
  常駐プロセス（webhook / notifier）は**対話認証に落ちない**設計で、再認証が要る状態では
  `AuthRequiredError` で即座に失敗し、LINE に「⚠️ カレンダーに接続できません」を1日1回送る。
  （以前は `_service()` が `run_local_server()` に落ち、ブラウザの無い LaunchAgent 配下で無言のまま
  ハングし続けていた）
- LINE の Webhook URL を変更したいときは Messaging API で：
  ```bash
  .venv/bin/python -c "import requests; from src.config import LINE_CHANNEL_ACCESS_TOKEN as T; print(requests.put('https://api.line.me/v2/bot/channel/webhook/endpoint', headers={'Authorization':f'Bearer {T}'}, json={'endpoint':'https://<新URL>/webhook/line'}).status_code)"
  ```

## 配布（人に渡す）

```bash
.venv/bin/python build_windows_zip.py     # → dist/ai-hisho.zip（Windows の友人へ）
.venv/bin/python build_mac_zip.py         # → dist/ai-hisho-mac.zip（Mac の友人へ）
```

`src/` と `tests/`・`requirements*`・`shared/check_gemini.py` は3者（自分の Mac / Windows 配布 / Mac 配布）で
共有し、OS 固有のものだけを `windows/` と `mac/` に置く。設計意図と実機確認の状況は各フォルダの
`README.md` が正本。

| | Windows 版 | Mac 版 |
|---|---|---|
| 素材 | `windows/` | `mac/` |
| 入口 | `.bat`（ASCII・CRLF） | `.command`（LF・**実行権**） |
| 実処理 | PowerShell 5.1 互換 `.ps1` | bash 3.2 互換 `.sh` |
| 常駐 | スタートアップ + 再起動ループ | LaunchAgent（KeepAlive） |
| 設置場所 | `C:\ai-hisho` 固定 | どこでもよい（plist を設置時に生成） |
| 実機確認 | **未実施**（Mac 上では静的検証のみ） | **実施済み**（開発機が macOS のため） |

ビルド時に、改行コード・BOM／実行権・秘密ファイルの混入を機械的にチェックし、1つでも外れたら中止する。

## ファイル構成
```
スケジュール管理/
├── src/
│   ├── main.py            # Flask Webhook（create/update/delete/list ルーティング）
│   ├── parser.py          # Gemini 自由文解析
│   ├── calendar_client.py # Google Calendar API
│   ├── line_client.py     # LINE 署名検証・reply・push
│   ├── notifier.py        # 朝の通知バッチ
│   ├── db.py              # SQLite
│   └── config.py
├── tests/
├── 使えないケース.md      # 届かない/入らない条件と仕様上の制約（正本）
├── windows/               # Windows 配布物の素材（bat / ps1 / 0_START_HERE.html）
├── mac/                   # Mac 配布物の素材（command / sh / 0_START_HERE.html）
├── shared/                # OS 非依存で両配布に入れる補助（check_gemini.py）
├── build_windows_zip.py   # → dist/ai-hisho.zip
├── build_mac_zip.py       # → dist/ai-hisho-mac.zip
├── com.niki.schedule.webhook.plist
├── com.niki.schedule.ngrok.plist
├── com.niki.schedule.notifier.plist
├── credentials.json       # Google OAuth（gitignore）
├── token.json             # Google トークン（gitignore）
├── .env                   # 各種キー（gitignore）
└── schedule.db            # 通知状態（gitignore）
```
