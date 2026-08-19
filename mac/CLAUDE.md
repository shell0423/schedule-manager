# AI秘書（スケジュール管理）— AI 向け運用メモ

このフォルダで Claude Code 等を動かすとき、**毎回最初に読む前提**の指示書。
利用者本人向けの手順書は `0_START_HERE.html`（ブラウザで開く）が正本。

---

## 相手は誰か（最重要）

**このフォルダの持ち主はプログラマーではない。** 以下を守ること。

- **説明は日本語の平易な言葉で。** 専門用語を使うときは一言添える。
- **操作は原則 `.command` ファイルを案内する。** ターミナルのコマンドを打たせるのは、
  `.command` で解決できないときだけ。打たせるなら1行ずつ、コピペできる形で出す。
- **勝手に直して終わりにしない。** 何が起きていて何を変えたのかを必ず伝える。
- 作者（配布元）は別の人。**このフォルダの中で完結しない話（LINE公式アカウントの
  作り直し等）は、持ち主に判断を委ねる。**

---

## これは何か

LINE に自由文を送ると Gemini が解析して Google カレンダーに登録・変更・削除し、
毎朝8時（月曜は今週分も）に予定を LINE へ通知する常駐アプリ。

```
LINE → ngrok(固定ドメイン) → 127.0.0.1:5555 Flask(src/main.py)
                                  ├ src/parser.py       Gemini で自由文解析
                                  ├ src/calendar_client.py  Google Calendar
                                  └ src/db.py           SQLite(通知の重複防止)
毎朝8:00 LaunchAgent → src/notifier.py → LINE Push
```

常駐は **LaunchAgent 3点**（`~/Library/LaunchAgents/`）:
`com.ai-hisho.webhook` / `com.ai-hisho.ngrok` / `com.ai-hisho.notifier`

---

## 困りごとが来たら、まずこの順で

1. **`status.command` を実行してもらい、その画面を見る。** 8項目を上から診断する。
   推測で触る前に必ずこれ。どこで切れているかがほぼ確定する。
2. **`logs/webhook.err.log` の末尾**を読む（Flask のログはこちら側に出る。`webhook.log` は
   ほぼ空）。通知の問題なら `logs/notifier.err.log`、外部疎通なら `logs/ngrok.log`。
3. 直したら **`3_start.command`** で反映（後述）。

---

## 触る前に知っておくべき落とし穴

ここに書いてあることは、**すべて実際に踏んで対処したもの**。「おかしいから直そう」と
手を入れると壊れる箇所が含まれる。

### 認証まわり

- `src/calendar_client.py` の `_service()` は **既定で対話認証に落ちない**。
  `AuthRequiredError` を投げて即座に失敗する。**これは仕様。**
  ブラウザの無い常駐プロセスで `run_local_server()` に入ると**無言でハングし続ける**ため。
  「認証が必要なら聞けばいいのに」と対話フローを足さないこと。
- 再認証は `2_google_auth.command`（中身は `python -m src.calendar_client`）**のみ**。
- `token.json` は1時間で期限切れになるが、`refresh_token` があるので自動更新される。
  **期限切れ表示だけを見て削除しないこと。**本当に壊れているのは `invalid_grant` のとき。

### 通知まわり

- `src/notifier.py` の `_run_with_retry()` は、週次と日次を**独立して**実行し、一時的な
  ネットワーク断を30秒×5回リトライする。**まとめて簡潔にしないこと。**
  以前これが無く、起床直後の DNS 断で週次が落ちた巻き添えで日次まで送られない事故があった。
- 認証切れのときは LINE に「⚠️ カレンダーに接続できません」を**1日1回**送る。
  黙って通知が止まるのを防ぐため。

### 日付の扱い

- **Google カレンダーの終日予定の `end` は exclusive（最終日の翌日）。**
  このコードは内部では常に「**含む最終日**」で扱い、API 境界
  （`calendar_client._apply_period` / `main._handle_update`）でだけ変換する。
  ここを触るときは `tests/test_calendar_client.py` を必ず通すこと。

### 環境まわり

- **ポート 5555 が応答する ≠ このアプリが動いている。** 別プログラムが使っていることがある。
  必ず LaunchAgent の稼働（`launchctl list | grep ai-hisho`）と併せて判断する。
  ポートを変えるなら `.env` の `WEBHOOK_PORT` を書き換えて `3_start.command`。
- **plist には絶対パスが焼かれている。** フォルダを移動・リネームすると launchd が
  古い場所を見に行き、**黙って失敗する**。`3_start.command` を実行すれば今の場所で作り直される。
  **plist を手で編集しないこと**（`scripts/make_plists.py` が生成する）。
- **`ngrok config add-authtoken` はこの Mac のユーザー共通設定を書き換える。**
  検証目的で偽のトークンを入れないこと。
- ngrok 無料枠は**同時1セッション**。`ERR_NGROK_108` は多重起動が原因。
- Homebrew の **Python 3.14 系は `ensurepip` が無く venv を作れない**ことがある。
  `1_setup.command` は 3.11〜3.13 を優先し、失敗したら次の候補に落ちる作りになっている。
  macOS 標準の 3.9.6 でも動作確認済み（Google 製ライブラリが「3.9 は非対応」と警告を出すが無害）。

---

## やってはいけないこと

- **`.env` / `token.json` / `credentials.json` の中身を、要約であっても外に出さない。**
  チャットへの貼り付け、コミット、ログへの出力すべて禁止。鍵そのものが入っている。
  値を確認する必要があるときは「先頭6文字だけ」に留める（`status.command` がそうしている）。
  `.claude/settings.json` でこの3つの Read を拒否してあるが、**それは補助**であって、
  `cat` 等のシェル経由までは塞げていない。**読まない判断はこちら側の責任。**
  設定が本当に必要なら、`status.command` の出力（鍵は先頭6文字に伏せられる）を使う。
- **`python -m src.main` を手で起動しない。** LaunchAgent が同じポートで動いており衝突する。
  起動・再起動は `3_start.command`、停止は `stop.command`。
- **`schedule.db` を安易に消さない。** 通知済みフラグが入っており、消すと同じ通知が
  再送される（消してよいのは「通知テストをもう一度やりたい」と本人が言ったときだけ）。
- **`launchctl` を直接叩いて自作の plist を入れない。** 生成物との二重管理になる。

---

## コードを直すとき

```bash
# テストを動かす（初回だけ開発用パッケージを追加）
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python -m pytest -q          # 53件
.venv/bin/python -m ruff check src tests
.venv/bin/python -m mypy src

# 直したら反映（LaunchAgent を読み直す）
./3_start.command
```

- `src/` は配布元の Mac 版・Windows 版と**共有しているコード**。ここを変えると
  配布元の更新と衝突する可能性がある。持ち主に「作者に伝えるか」を確認するのが望ましい。
- 変更したら該当するテストを必ず足す。特に日付・終日・繰り返しの分岐は
  `tests/test_calendar_client.py` と `tests/test_notifier.py` が守っている。

---

## ファイルの役割

| ファイル | 役割 |
|---|---|
| `1_setup.command` | 実行環境の用意と鍵の入力（最初に1回） |
| `2_google_auth.command` | Google カレンダーの許可（＝再認証もこれ） |
| `3_start.command` | 起動＋自動起動の登録＋LINE 側 URL 設定。**設定を変えたらこれ** |
| `4_set_user_id.command` | 朝の通知の宛先を設定（1通送ったあとに1回） |
| `status.command` | 8項目の診断。**困ったらまずこれ** |
| `stop.command` / `uninstall.command` | 一時停止 / 自動起動の解除 |
| `test_notify.command` | 朝の通知を今すぐ試す |
| `.env` | 鍵の保存先（600）。**外に出さない** |
| `logs/` | `webhook.err.log` が本体のログ |
| `scripts/make_plists.py` | LaunchAgent の plist を設置場所に合わせて生成 |

---

## 仕様として正しい（バグではない）挙動

- **今日の予定が0件の日は、朝の通知を送らない。**
- **朝の通知は1日1回まで。** `test_notify.command` を2回叩いても2通は来ない。
- Mac がスリープ・電源オフの間に来た LINE は**受け取れず、再送もされない**（LINE 側の仕様）。
  朝8時の通知だけは、復帰時に launchd がまとめて実行するので比較的取りこぼしにくい。
- 「このアプリは Google で確認されていません」の警告は、自作アプリなので**出るのが正常**。
