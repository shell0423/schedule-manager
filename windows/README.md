# windows/ — 友人に渡す Windows 配布物の素材

Mac 用の LaunchAgent 構成（プロジェクト直下の `com.niki.schedule.*.plist`）とは別に、
**Claude Code も Python も入っていない Windows ユーザー**が ZIP 一式だけで動かせるようにするための素材置き場。
`src/` は Mac 版と共有し、ここには Windows 固有のものだけを置く。

このフォルダ自体は配布しない。`build_windows_zip.py` が `src/` と混ぜて `dist/ai-hisho.zip` を作る。

## ビルド

```bash
cd ~/Claude/スケジュール管理
.venv/bin/python build_windows_zip.py     # → dist/ai-hisho.zip
```

ビルド時に機械的に保証していること:

- `.bat` / `.vbs` は **CRLF・ASCII のみ**（cmd.exe は非ASCIIの .bat を文字化けさせる。非ASCIIが混ざったらビルドが止まる）
- `.ps1` は **CRLF・UTF-8 BOM付き**（Windows PowerShell 5.1 は BOM が無いと日本語を ANSI として読む）
- `.env` / `credentials.json` / `token.json` / `schedule.db` は名前でも中身でも混入不可
  （`.env` の実値を全ファイルに対して grep し、1つでも当たったら中止）
- ZIP のルート直下にファイルを置く（「`C:\ai-hisho` に展開」でそのまま正しい形になる）

## 友人側の流れ

`0_START_HERE.html`（ブラウザで開く前提のガイド）が正本。要約すると:

| 順 | ファイル | 役割 |
|---|---|---|
| 1 | `1_setup.bat` | Python 検出/導入 → venv → 依存 → ngrok 自動DL → `.env` を対話で作成 |
| 2 | `2_google_auth.bat` | OAuth 同意 → `token.json` 生成 |
| 3 | `3_start.bat` | 起動 + スタートアップ登録 + 8:00 タスク登録 + **LINE の Webhook URL を API で自動設定** |
| 4 | `4_set_user_id.bat` | `webhook.log` から `userId` を拾って `.env` に書き、python を落として再読込 |
| — | `status.bat` | 設定/プロセス/疎通/LINE側設定/タスクを上から順に診断。**問い合わせ時はこれの画面を送ってもらう** |
| — | `test_notify.bat` / `stop.bat` / `uninstall.bat` | 通知の即時テスト / 停止 / 自動起動の解除 |

## Mac 版との違い

| | Mac | Windows |
|---|---|---|
| 常駐 | LaunchAgent（KeepAlive） | スタートアップのショートカット → `hidden.vbs` → `run_*.bat` の再起動ループ |
| 定時実行 | LaunchAgent `StartCalendarInterval` | タスクスケジューラ `AI-Hisho-DailyNotify`（`-StartWhenAvailable` で取りこぼしを追いかける） |
| ngrok ドメイン | plist に直書き | `.env` の `NGROK_DOMAIN` を `run_ngrok.bat` が `findstr` で読む |
| `WEBHOOK_HOST` | `0.0.0.0` | `127.0.0.1`（同一PCの ngrok からしか繋がないので十分。ファイアウォールの警告も出ない） |
| コンソール窓 | なし | `hidden.vbs` で隠す |

## `src/` 側に入れた Windows 対応（Mac でも同じ挙動）

- `notifier.py` の日付ラベル: `strftime("%-m/%-d")` は Windows で `ValueError`。自前組み立てに変更
- `requirements.txt`: `tzdata; sys_platform == "win32"` を追加。
  Windows には IANA タイムゾーンDBが無く、これが無いと `ZoneInfo("Asia/Tokyo")` が
  **import 時点で**落ちる（`notifier.py` はモジュール直下で `ZoneInfo` を呼ぶ）
- `calendar_client.py`: `token.json` の書き出しに `encoding="utf-8"` を明示
- `main.py`: 受信ログに `userId=` を出力。`4_set_user_id.bat` がこれを拾う
- `notifier.py`: 一時的なネットワーク断を 30秒×最大5回リトライし、**週次と日次を独立実行**する。
  Windows のタスクスケジューラも `-StartWhenAvailable` で**起床直後に走る**ため、Mac の LaunchAgent と
  同じ「まだ DNS が引けない」条件を踏む（2026-08-17 に Mac 側で通知が丸ごと落ちた事故と同じ原因）
- `calendar_client.py`: `_service()` は**既定で対話認証に落ちない**。ブラウザの無い常駐プロセス
  （スタートアップ常駐の webhook・タスクスケジューラの notifier）で `run_local_server()` に入ると
  **無言でハングし続ける**ため、`AuthRequiredError` を送出して即座に失敗させる。
  対話認証は `python -m src.calendar_client`（＝`2_google_auth.bat`）からのみ。300秒でタイムアウトする

## 更新版を渡すとき

相手はすでに `C:\ai-hisho` に前の版を入れてある。**入れ直し（STEP 1〜9のやり直し）は不要**で、
`0_START_HERE.html` 冒頭の「すでに使っている人へ（更新のしかた）」に書いた3手順で入れ替わる。

1. `stop.bat`（常駐を止める。動いたままだと `src/` を上書きしても古いコードが動き続ける）
2. ZIP を展開して `C:\ai-hisho` に上書きコピー
3. `3_start.bat`

**上書きで壊れないことの根拠**: ZIP には `.env` / `token.json` / `schedule.db` / `.venv/` / `bin/ngrok.exe` が
含まれない（`build_windows_zip.py` の `FORBIDDEN` と秘密値 grep で機械的に保証）。つまり相手の設定・許可・
記録・入れた依存はそのまま残る。`1_setup.bat` / `2_google_auth.bat` のやり直しも不要。

`requirements.txt` に `httplib2` を明示追加したが、これは `google-api-python-client` の推移的依存として
**すでに入っている**ので、依存の入れ直しも要らない。

## 「使えないケース」の扱い

Windows 版の相手は Markdown を開く習慣が無い前提なので、独立ファイルにせず
`0_START_HERE.html` の節（`id="limits"`）として入れてある。内容の正本は
プロジェクト直下の `使えないケース.md`。**あちらを直したらこの節も直すこと**
（Mac 版は `mac/使えないケース.md` として同梱している）。

Windows 固有に読み替えている点: 常駐はサインイン時のスタートアップ（LaunchAgent ではない）、
スリープに加えて休止状態も該当する。

## 保守メモ

- `.bat` に日本語を書かないこと。ビルドが弾く。ユーザー向け文言は必ず `.ps1` 側に置く
- PowerShell は **5.1 互換**で書く（`??`・三項演算子・`Get-CimInstance` 以外の 7.x 専用構文は使わない）
- 実機 Windows での通し確認は未実施。初回は友人と画面共有しながら進めるのが安全
